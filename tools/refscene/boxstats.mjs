// boxstats.mjs -- luma distribution of one fractional box in a screenshot PNG.
//
// Same box convention as the in-browser __stats() of ../refscene/walk-m26.html,
// so a capture and the live reference are directly comparable:
//
//   * the box is fractional over the CONTENT area (below the titlebar);
//   * `top` is the titlebar height in CSS px: ~32 for an AOT window capture,
//     0 for an AIR/`adl` capture (the stage starts at y=0 there);
//   * pixel sampling steps by 2 because captures are 2x (retina) and the
//     reference canvas is 1x -- both then cover the same spatial grid.
//
// usage: node tools/refscene/boxstats.mjs <png> <topPx> <fx0,fy0,fx1,fy1>
import { readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';

function load(p) {
  const buf = readFileSync(p);
  let off = 8, w = 0, h = 0, bd = 0, ct = 0;
  const idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const t = buf.toString('ascii', off + 4, off + 8);
    const d = buf.subarray(off + 8, off + 8 + len);
    if (t === 'IHDR') { w = d.readUInt32BE(0); h = d.readUInt32BE(4); bd = d[8]; ct = d[9]; }
    else if (t === 'IDAT') idat.push(d);
    else if (t === 'IEND') break;
    off += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const ch = ct === 6 ? 4 : (ct === 2 ? 3 : 1);
  const bpp = ch * (bd / 8);
  const stride = w * bpp;
  const out = Buffer.alloc(h * stride);
  let pos = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[pos++];
    const line = raw.subarray(pos, pos + stride);
    pos += stride;
    const cur = out.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? out.subarray((y - 1) * stride, y * stride) : Buffer.alloc(stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? cur[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      let v = line[i];
      switch (f) {
        case 0: break;
        case 1: v += a; break;
        case 2: v += b; break;
        case 3: v += (a + b) >> 1; break;
        case 4: {
          const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
          v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          break;
        }
      }
      cur[i] = v & 255;
    }
  }
  return { w, h, bpp, stride, px: out };
}

const [file, topArg, boxArg] = process.argv.slice(2);
const top = Number(topArg || 0) * 2;
const f = (boxArg || '0.44,0.44,0.56,0.62').split(',').map(Number);
const I = load(file);
const x0 = Math.round(f[0] * I.w), x1 = Math.round(f[2] * I.w);
const y0 = Math.round(top + f[1] * (I.h - top)), y1 = Math.round(top + f[3] * (I.h - top));
const l = [];
let sr = 0, sg = 0, sb = 0;
for (let y = y0; y < y1; y += 2) {
  for (let x = x0; x < x1; x += 2) {
    const i = y * I.stride + x * I.bpp;
    const r = I.px[i], g = I.px[i + 1], b = I.px[i + 2];
    sr += r; sg += g; sb += b;
    l.push(0.2126 * r + 0.7152 * g + 0.0722 * b);
  }
}
l.sort((a, b) => a - b);
const q = (x) => l[Math.min(l.length - 1, Math.floor(x * l.length))];
const n = l.length;
console.log(JSON.stringify({
  n,
  meanRGB: [+(sr / n).toFixed(2), +(sg / n).toFixed(2), +(sb / n).toFixed(2)],
  meanLuma: +(l.reduce((a, b) => a + b, 0) / n).toFixed(2),
  p50: +q(0.5).toFixed(1), p90: +q(0.9).toFixed(1),
  p99: +q(0.99).toFixed(1), max: +l[n - 1].toFixed(1),
}));