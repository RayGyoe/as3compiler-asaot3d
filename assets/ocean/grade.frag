#version 300 es
// grade.frag -- the last pass: exposure (auto or fixed), bloom, filmic tone map, the
// author's grade, and the sRGB encode, straight into the back buffer.
//
// WHY THIS IS NOT PART OF composite.frag ANY MORE. Bloom and auto-exposure both need the
// frame BEFORE the tone map: a threshold on display-referred values (max 1.0) finds
// nothing, and metering a tonemapped frame measures the curve rather than the scene.
// composite.frag therefore stops at linear HDR in `_hdr`, and this pass is the only place
// where linear light becomes display-referred -- which is also why it is the only pass
// that encodes sRGB.
//
// THE FLIP IS NOT HERE. composite.frag already flipped its own sampling when it wrote
// `_hdr` (the flip that makes the frame upright in the drawable), so this pass samples
// `_hdr` straight through and writes straight out: exactly one vertical flip exists in the
// chain, and it stayed where it was measured correct.
uniform sampler2D uHdr;     // linear HDR, pre-grade
uniform sampler2D uBloom;   // level 0 of the bloom pyramid
uniform sampler2D uExpo;    // 1x1: adapted log2 average luminance
uniform float uExposure;    // exposure compensation (auto) or absolute exposure
uniform float uAuto;        // 1 = auto exposure
uniform vec3 uExpoRange;    // keyValue, minExposure, maxExposure
uniform float uBloomStrength;
uniform float uContrast;
uniform float uSaturation;
uniform float uVignette;
uniform vec2 uDstTexel;     // 1 / drawable size, for the supersample box
uniform float uSuper;       // 1 = the HDR target is larger than the drawable
in vec2 vUV;
out vec4 fragColor;

const mat3 ACES_IN = mat3(0.59719, 0.07600, 0.02840,
                          0.35458, 0.90834, 0.13383,
                          0.04823, 0.01566, 0.83777);
const mat3 ACES_OUT = mat3(1.60475, -0.10208, -0.00327,
                           -0.53108, 1.10813, -0.07276,
                           -0.07367, -0.00605, 1.07602);

vec3 aces(vec3 c) {
  vec3 v = ACES_IN * c;
  vec3 a = v * (v + 0.0245786) - 0.000090537;
  vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
  return clamp(ACES_OUT * (a / b), 0.0, 1.0);
}

vec3 toSrgb(vec3 c) {
  vec3 lo = c * 12.92;
  vec3 hi = 1.055 * pow(max(c, vec3(1e-5)), vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), c));
}

void main() {
  // No flip: see the note in composite.frag. The composite's old flip went away when the
  // grade took over the drawable write, and the frame was verified upright against the
  // pre-refactor pipeline rather than against a screenshot.
  vec2 uv = vUV;
  vec3 hdr = texture(uHdr, uv).rgb;
  if (uSuper > 0.5) {
    // The HDR target is bigger than the window (quality: render scale > 1), so this is
    // the resize filter, and a single bilinear tap is a 2x2 average only on the diagonal.
    // Four taps at half a DESTINATION texel put a 2x2 block's worth of source texels in
    // each quadrant: the same job MSAA does at the geometry stage, done at the last pass.
    vec2 o = uDstTexel * 0.5;
    hdr = (texture(uHdr, uv + vec2(-o.x, -o.y)).rgb + texture(uHdr, uv + vec2(o.x, -o.y)).rgb
         + texture(uHdr, uv + vec2(-o.x, o.y)).rgb + texture(uHdr, uv + vec2(o.x, o.y)).rgb) * 0.25;
  }
  // Only sampled when it is actually used: a bloom strength of 0 skips the pyramid
  // pass entirely, and an unwritten half-float target holds whatever the driver left
  // there -- a single NaN texel is enough to turn the whole frame black through
  // `NaN * 0.0`. Guarding the sample is cheaper and truer than clearing a target the
  // pipeline never writes (Context3D.clear is deferred to the next draw anyway, see
  // Context3D_clear).
  vec3 bloom = uBloomStrength > 0.0 ? texture(uBloom, uv).rgb : vec3(0.0);

  float ex = uExposure;
  if (uAuto > 0.5) {
    // metered exposure = key / geometric-mean luminance, clamped to the panel's range
    ex *= clamp(uExpoRange.x * exp2(-texelFetch(uExpo, ivec2(0), 0).r), uExpoRange.y, uExpoRange.z);
  }

  vec3 col = (hdr + bloom * uBloomStrength) * ex;
  col = aces(col);

  // the author's grade, in display-referred light: contrast is a gamma on the tonemapped
  // value (the reference's AgX look does the same), saturation a pull towards luma
  col = pow(max(col, vec3(0.0)), vec3(uContrast));
  float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = max(l + uSaturation * (col - l), vec3(0.0));

  vec2 q = vUV - 0.5;
  col *= 1.0 - uVignette * dot(q, q);
  fragColor = vec4(toSrgb(col), 1.0);
}