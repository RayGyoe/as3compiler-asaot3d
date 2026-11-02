#version 300 es
// caustics.vert -- area-ratio splatting (Evan Wallace's WebGL water, as used by
// Ultra-Water src/water/Caustics.js). A grid over the 12 m cascade's period is refracted
// through its slopes onto a plane at uDepth; the fragment then adds
// (undisturbed area / landed area) to that depth's channel. Output is intensity relative
// to flat water, mean 1 by construction, so it multiplies direct sun.
//
// The landing offset of FLAT water is subtracted so the pattern registers to the surface
// entry point: look it up at uv = entryXZ / 12.
layout(location = 0) in vec3 aPos;   // cell coords, centred on the tile
uniform sampler2D uSlope;            // cascade 2 (sx, sz, ...) tiling every 12 m
uniform vec3 uSun;                   // towards the sun
uniform float uDepth;
uniform float uCells;
uniform float uLod;
uniform float uMargin;               // margins as a fraction of the tile
uniform float uRes;
out vec2 vOld;

// cubic B-spline from 4 bilinear taps (GPU Gems 2 ch. 20). The landed intensity goes with
// the slope's derivative, which bilinear makes piecewise constant: every slope texel
// would land as its own bead along the caustic lines.
vec2 slopeBSpline(vec2 uv, float lod) {
  vec2 size = vec2(textureSize(uSlope, int(lod)));
  vec2 st = uv * size - 0.5, i = floor(st), f = st - i;
  vec2 f2 = f * f, f3 = f2 * f;
  vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0, w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
  vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0, w3 = f3 / 6.0;
  vec2 g0 = w0 + w1, g1 = w2 + w3;
  vec2 h0 = (i - 0.5 + w1 / g0) / size, h1 = (i + 1.5 + w3 / g1) / size;
  return g0.y * (g0.x * textureLod(uSlope, h0, lod).xy + g1.x * textureLod(uSlope, vec2(h1.x, h0.y), lod).xy)
       + g1.y * (g0.x * textureLod(uSlope, vec2(h0.x, h1.y), lod).xy + g1.x * textureLod(uSlope, h1, lod).xy);
}

void main() {
  vec2 t = (aPos.xy + 0.5 * uCells + 0.5) / uCells;   // tile uv, at a texel centre of mip uLod
  vec2 s = slopeBSpline(t, uLod);
  vec3 r = refract(-uSun, normalize(vec3(-s.x, 1.0, -s.y)), 0.75188);
  vec3 rf = refract(-uSun, vec3(0.0, 1.0, 0.0), 0.75188);
  vec2 d = (r.xz / max(-r.y, 0.05) - rf.xz / -rf.y) * (uDepth / 12.0);
  // offsets past the margin (steep facets at low sun) are clamped; the margin covers it
  d = clamp(d, -uMargin, uMargin);
  vOld = t * uRes;
  gl_Position = vec4((t + d) * 2.0 - 1.0, 0.0, 1.0);
}