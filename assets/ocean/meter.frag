#version 300 es
// meter.frag -- auto-exposure step 1/2: the HDR frame down to a 32x32 grid of
// log2(luminance), ported from Ultra-Water PostFX.js (`METER_FRAG`).
//
// Each texel averages 4x4 bilinear taps across its own footprint (the frame is 32x larger
// than this grid, so a single tap would sample one pixel in a thousand and the metering
// would flicker with the glints). The grid is jittered per frame on an R2 sequence; the
// temporal filter in adapt.frag averages that away.
//
// Luminance is clamped to [1e-4, 64] BEFORE the log so the sun disc and the glitter road
// cannot pump the exposure: metering is about the scene, not about the brightest pixel.
uniform sampler2D uSrc;
uniform vec2 uJitter;   // [0,1)^2
in vec2 vUV;
out vec4 fragColor;

void main() {
  float s = 0.0;
  for (int j = 0; j < 4; j++) {
    for (int i = 0; i < 4; i++) {
      vec2 o = (vec2(float(i), float(j)) + uJitter) * 0.25 - 0.5;
      vec3 c = max(texture(uSrc, vUV + o * 0.03125).rgb, 0.0);   // 1/32: one meter texel
      s += log2(clamp(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-4, 64.0));
    }
  }
  fragColor = vec4(s * (1.0 / 16.0), 0.0, 0.0, 1.0);
}