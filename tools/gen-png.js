// gen-png.js -- zero-dependency PNG writer for asaot3d test assets.
// Produces 8-bit RGB/RGBA PNGs via node's built-in zlib (no npm deps).
// Usage: node tools/gen-png.js
'use strict';
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

// pixels: Buffer of width*height*channels, channels 3 (RGB) or 4 (RGBA).
function encodePNG(width, height, pixels, channels) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = channels === 4 ? 6 : 2; // color type: RGBA / RGB
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const stride = width * channels;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const outDir = path.join(__dirname, '..', 'assets', 'textures');

// 1) checkerboard 256x256 RGB -- the classic test texture.
{
  const w = 256, h = 256, cell = 32;
  const px = Buffer.alloc(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const on = (Math.floor(x / cell) + Math.floor(y / cell)) % 2 === 0;
      const v = on ? 255 : 16;
      const i = (y * w + x) * 3;
      px[i] = v; px[i + 1] = v; px[i + 2] = v;
    }
  }
  fs.writeFileSync(path.join(outDir, 'checker.png'), encodePNG(w, h, px, 3));
  console.log('checker.png written');
}

// 2) uv-grid style gradient 256x256 RGB -- red->green across x, blue ramp across y
//    (helps verify UV orientation end to end).
{
  const w = 256, h = 256;
  const px = Buffer.alloc(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 3;
      px[i] = x;            // R ramps left->right
      px[i + 1] = 255 - x;  // G ramps right->left
      px[i + 2] = y;        // B ramps top->bottom
    }
  }
  fs.writeFileSync(path.join(outDir, 'uvgrid.png'), encodePNG(w, h, px, 3));
  console.log('uvgrid.png written');
}

// 3) bead normal map 256x256 RGBA -- dome bumps, z = sqrt(1-r^2), encoded
//    normal = (x*0.5+0.5, y*0.5+0.5, z*0.5+0.5)*255 (tangent-space, alpha 255).
{
  const w = 256, h = 256;
  const px = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const cell = 64;
      const cx = (x % cell) - cell / 2, cy = (y % cell) - cell / 2;
      const r = Math.sqrt(cx * cx + cy * cy) / (cell / 2);
      let nx = 0, ny = 0, nz = 1;
      if (r < 1) {
        const z = Math.sqrt(1 - r * r);
        const s = r / (z + 1e-6);
        nx = (cx / (cell / 2)) * s;
        ny = (cy / (cell / 2)) * s;
        nz = z;
        const inv = 1 / Math.sqrt(nx * nx + ny * ny + nz * nz);
        nx *= inv; ny *= inv; nz *= inv;
      }
      const i = (y * w + x) * 4;
      px[i] = Math.round((nx * 0.5 + 0.5) * 255);
      px[i + 1] = Math.round((ny * 0.5 + 0.5) * 255);
      px[i + 2] = Math.round((nz * 0.5 + 0.5) * 255);
      px[i + 3] = 255;
    }
  }
  fs.writeFileSync(path.join(outDir, 'bead-normal.png'), encodePNG(w, h, px, 4));
  console.log('bead-normal.png written');
}
