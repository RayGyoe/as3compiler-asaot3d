#version 300 es
// adapt.frag -- auto-exposure step 2/2: the 32x32 log-luminance grid down to one value,
// with temporal adaptation, ported from Ultra-Water PostFX.js (`ADAPT_FRAG`).
//
// The mean is taken in LOG space (the geometric mean of the luminance), because that is
// what "the scene's typical brightness" means to an eye: an arithmetic mean is dominated
// by the sun and the sea's glitter. The result is blended towards the previous frame's
// value at a rate that depends on the direction -- brightening adapts at ~0.4 s, darkening
// at ~1 s, like a real pupil -- and ping-pongs through a 1x1 target so the state lives on
// the GPU and no readback is needed anywhere in the frame.
uniform sampler2D uSrc;    // metering target, linear filtered
uniform sampler2D uPrev;   // previous 1x1 state
uniform vec2 uK;           // blend factor when the scene brightens (x) / darkens (y); 1 = snap
uniform vec2 uRange;       // allowed log2 luminance range (from min/max exposure)
in vec2 vUV;
out vec4 fragColor;

void main() {
  float sum = 0.0;
  for (int j = 0; j < 16; j++) {
    for (int i = 0; i < 16; i++) {
      sum += texture(uSrc, (vec2(float(i), float(j)) + 0.5) * (1.0 / 16.0)).r;
    }
  }
  float t = clamp(sum * (1.0 / 256.0), uRange.x, uRange.y);
  float prev = texelFetch(uPrev, ivec2(0), 0).r;
  float k = t > prev ? uK.x : uK.y;
  float s = k >= 1.0 ? t : prev + (t - prev) * k;
  if (isnan(s)) s = t;
  fragColor = vec4(s, 0.0, 0.0, 1.0);
}