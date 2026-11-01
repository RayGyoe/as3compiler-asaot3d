#!/usr/bin/env node
// tools/gen-hdr.js -- write a synthetic Radiance .hdr panorama for the M25 demo.
//
// There is no downloadable-free HDR we want to vendor into the repo, and a
// hand-made one has a property a photo does not: every bright source is an
// analytically known solid angle, so "the sphere shows the softbox exactly
// there" is checkable by eye against the generator below.
//
// Output: assets/textures/hdr/studio.hdr
//   - 512x256, "-Y 512 +X 256" (top row first), new-style RLE
//   - upper hemisphere: blue sky gradient + two rectangular softboxes
//     (key: warm 60.0 at az~+20 deg / el~+33 deg, rim: cool 25.0 behind-left)
//   - lower hemisphere: dark grey floor with a horizon bounce
//
// Usage: node tools/gen-hdr.js [outPath]
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const W = 512;
const H = 256;

const norm = (x, y, z) => {
  const l = Math.hypot(x, y, z) || 1;
  return [x / l, y / l, z / l];
};

// The two softboxes: a direction, an angular radius and a radiance. A sphere
// reflecting one shows a bright disc; a rough one smears it into the highlight.
const KEY = { dir: norm(0.42, 0.58, -0.70), radius: 0.20, rgb: [60.0, 52.0, 42.0] };
const RIM = { dir: norm(-0.80, 0.22, 0.56), radius: 0.13, rgb: [20.0, 26.0, 40.0] };

function softbox(box, dx, dy, dz) {
  const dot = dx * box.dir[0] + dy * box.dir[1] + dz * box.dir[2];
  const ang = Math.acos(Math.max(-1, Math.min(1, dot)));
  if (ang > box.radius) return 0;
  // Soft edge over the outer 35% so a mirror sphere shows a soft-edged panel
  // instead of a hard pixel disc (and the bake does not alias).
  const t = Math.min(1, (box.radius - ang) / (box.radius * 0.35));
  return t * t * (3 - 2 * t);
}

export function radiance(u, v) {
  const lon = (u - 0.5) * 2 * Math.PI;
  const lat = (0.5 - v) * Math.PI;
  const cl = Math.cos(lat);
  const dx = cl * Math.cos(lon);
  const dy = Math.sin(lat);
  const dz = cl * Math.sin(lon);

  let r, g, b;
  if (dy >= 0) {
    // Sky: warm near the horizon, deeper blue at the zenith.
    const t = Math.pow(dy, 0.55);
    r = 0.62 * (1 - t) + 0.16 * t;
    g = 0.68 * (1 - t) + 0.28 * t;
    b = 0.80 * (1 - t) + 0.58 * t;
  } else {
    // Floor: near-black, with a warm bounce that dies off within ~10 degrees.
    const t = Math.exp(dy * 9);
    r = 0.07 + 0.20 * t;
    g = 0.07 + 0.17 * t;
    b = 0.075 + 0.14 * t;
  }

  const k = softbox(KEY, dx, dy, dz);
  if (k > 0) {
    r += KEY.rgb[0] * k;
    g += KEY.rgb[1] * k;
    b += KEY.rgb[2] * k;
  }
  const m = softbox(RIM, dx, dy, dz);
  if (m > 0) {
    r += RIM.rgb[0] * m;
    g += RIM.rgb[1] * m;
    b += RIM.rgb[2] * m;
  }
  return [r, g, b];
}

// float -> RGBE (Radiance's shared exponent, mantissa 0..255).
function toRgbe(r, g, b) {
  const m = Math.max(r, g, b);
  if (m < 1e-32) return [0, 0, 0, 0];
  const e = Math.ceil(Math.log2(m));
  const s = Math.pow(2, e) / 256; // 255/256 of the top bin, as Radiance does
  return [
    Math.min(255, Math.floor(r / s)),
    Math.min(255, Math.floor(g / s)),
    Math.min(255, Math.floor(b / s)),
    e + 128,
  ];
}

// New-style RLE: one run list per channel. Literal runs (<=128) then a repeat
// run (128+n, value) when the next n+1 values are identical -- the softboxes
// make long repeats along a scanline.
function encodeChannel(values) {
  const out = [];
  let i = 0;
  while (i < values.length) {
    let run = 1;
    while (i + run < values.length && values[i + run] === values[i] && run < 127) run++;
    if (run >= 4) {
      out.push(128 + run, values[i]);
      i += run;
      continue;
    }
    // Collect literals until a run of >= 4 starts.
    let n = 0;
    const start = i;
    while (i < values.length && n < 128) {
      let r2 = 1;
      while (i + r2 < values.length && values[i + r2] === values[i] && r2 < 127) r2++;
      if (r2 >= 4) break;
      i++;
      n++;
    }
    out.push(n);
    for (let k = 0; k < n; k++) out.push(values[start + k]);
  }
  return out;
}

// Only write the file when run directly: gen-exr.js imports `radiance` from here
// to produce the SAME panorama as an .exr, so a mismatch between the two files
// would be a decoder bug rather than a fixture difference.
function main() {
const bytes = [];
const header = Buffer.from(
  '#?RADIANCE\n' +
    '# synthetic studio panorama -- tools/gen-hdr.js\n' +
    'FORMAT=32-bit_rle_rgbe\n' +
    'EXPOSURE=1.0\n' +
    '\n' +
    `-Y ${H} +X ${W}\n`,
  'ascii',
);
for (const b of header) bytes.push(b);

for (let y = 0; y < H; y++) {
  const ch = [[], [], [], []];
  for (let x = 0; x < W; x++) {
    const [r, g, b] = radiance((x + 0.5) / W, (y + 0.5) / H);
    const e = toRgbe(r, g, b);
    for (let c = 0; c < 4; c++) ch[c].push(e[c]);
  }
  bytes.push(2, 2, (W >> 8) & 0xff, W & 0xff);
  for (let c = 0; c < 4; c++) for (const v of encodeChannel(ch[c])) bytes.push(v);
}

const out = resolve(process.argv[2] || new URL('../assets/textures/hdr/studio.hdr', import.meta.url).pathname);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, Buffer.from(bytes));
console.log(`wrote ${out} (${bytes.length} bytes, ${W}x${H})`);
}

if (process.argv[1] && resolve(process.argv[1]) === new URL(import.meta.url).pathname) main();