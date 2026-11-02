#version 300 es
// bloom_down.frag -- one level of the bloom chain: 13-tap dual-filter downsample
// (Call of Duty: Advanced Warfare), ported from Ultra-Water src/engine/PostFX.js (`DOWN`).
//
// With the PREFILTER define this is the FIRST level, which also thresholds: the soft-knee
// curve keeps a little of what is just under the threshold so the glow does not pop, and
// the Karis groups (weighted by 1/(1+luma)) stop one sun glint from dominating the bloom.
// Every later level is the plain filter, which is what makes the chain a pyramid rather
// than six independent blurs.
//
// `uTexel` is the SOURCE texel size: the taps are in texels of the level ABOVE, so the
// footprint is 2x2 source texels per tap group no matter how small this level is.
uniform sampler2D uSrc;
uniform vec2 uTexel;
#ifdef PREFILTER
uniform vec4 uCurve;   // threshold - knee, 2*knee, 0.25/knee, threshold
uniform float uClamp;
#endif
in vec2 vUV;
out vec4 fragColor;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 tap(vec2 o) {
  vec3 c = texture(uSrc, vUV + o * uTexel).rgb;
#ifdef PREFILTER
  c = max(c, 0.0);                      // negatives (and NaN on most GPUs) -> 0
  float l = max(luma(c), 1e-4);
  c *= min(1.0, uClamp / l);
  l = min(l, uClamp);
  float q = clamp(l - uCurve.x, 0.0, uCurve.y);
  c *= max(uCurve.z * q * q, l - uCurve.w) / l;
#endif
  return c;
}

void main() {
  vec3 a = tap(vec2(-2.0, 2.0)), b = tap(vec2(0.0, 2.0)), c = tap(vec2(2.0, 2.0));
  vec3 d = tap(vec2(-2.0, 0.0)), e = tap(vec2(0.0, 0.0)), f = tap(vec2(2.0, 0.0));
  vec3 g = tap(vec2(-2.0, -2.0)), h = tap(vec2(0.0, -2.0)), i = tap(vec2(2.0, -2.0));
  vec3 j = tap(vec2(-1.0, 1.0)), k = tap(vec2(1.0, 1.0)), l = tap(vec2(-1.0, -1.0)), m = tap(vec2(1.0, -1.0));
  vec3 g0 = (a + b + d + e) * 0.25, g1 = (b + c + e + f) * 0.25;
  vec3 g2 = (d + e + g + h) * 0.25, g3 = (e + f + h + i) * 0.25;
  vec3 g4 = (j + k + l + m) * 0.25;
#ifdef PREFILTER
  float w0 = 0.125 / (1.0 + luma(g0)), w1 = 0.125 / (1.0 + luma(g1));
  float w2 = 0.125 / (1.0 + luma(g2)), w3 = 0.125 / (1.0 + luma(g3));
  float w4 = 0.5 / (1.0 + luma(g4));
  vec3 r = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
#else
  vec3 r = g4 * 0.5 + (g0 + g1 + g2 + g3) * 0.125;
#endif
  fragColor = vec4(r, 1.0);
}