#version 300 es
// composite.frag -- assemble the frame and grade it.
//
// The water pass tags what it covered instead of blending, because the surface needs to
// know what is BEHIND it (refraction) before it can be shaded: alpha 2 = top side, 0 =
// underside, 1 = no water (the clear value). Edge pixels average between tags, hence the
// step() tests rather than an equality.
uniform sampler2D uColor;      // opaque scene + sky, .a = linear view depth
uniform sampler2D uWater;      // water surface, .a = tag
uniform sampler2D uSpray;      // additive spray
uniform sampler2D uShafts;     // quarter-res in-scattered sun, .a = ray length
uniform sampler2D uLens;       // near-plane depth below the surface
uniform vec3 uAbsorption;
uniform vec3 uScatterColor;
uniform vec3 uSunColor;
uniform vec4 uUnder;           // scattering (1/m), shaft strength, -, -
uniform float uFull;           // 1: the whole near plane is submerged
uniform float uActive;         // 1: the lens map is valid this frame
uniform float uExposure;
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

// Linear light becomes display-referred exactly once, here -- see the note in main().
vec3 toSrgb(vec3 c) {
  vec3 lo = c * 12.92;
  vec3 hi = 1.055 * pow(max(c, vec3(1e-5)), vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), c));
}

void main() {
  // Two things here are about where this pass WRITES, not about the shading model, and
  // they are why this file is not byte-identical to the port it came from:
  //
  // 1. THE FLIP. This pass draws into the DRAWABLE (the intermediate `_final` + present
  //    copy was dropped), and that is the one place in the chain where the row convention
  //    differs: every render target here has row 0 at the TOP, while a fullscreen quad's
  //    vUV.y is 0 at the BOTTOM. Without it the whole scene is upside down on screen --
  //    and identically upside down in drawToBitmapData, which is how it was missed.
  // 2. THE sRGB ENCODE at the end. The drawable is a plain BGRA8Unorm surface, not an
  //    _sRGB view, so Metal does NOT encode on write: handing it linear values crushes
  //    every midtone (a 0.30 linear sea displays at 0.30 instead of 0.58). The chain is
  //    linear end to end, so the OETF belongs at this one point.
  vec2 uv = vec2(vUV.x, 1.0 - vUV.y);
  vec4 o = textureLod(uColor, uv, 0.0);
  vec4 w = textureLod(uWater, uv, 0.0);

  float under = uFull > 0.5 ? 1.0 : (uActive > 0.5 ? step(0.5, texture(uLens, uv).r) : 0.0);
  // Tag 1 means "no water here" (the clear value), 0 is the underside and 2 the top
  // side, so the surface is present when the tag is NOT near 1. Testing `> 0.5` read
  // the open tag as water and painted the sky with the empty water target's black.
  bool isWater = abs(w.a - 1.0) > 0.5;

  vec3 col = isWater ? w.rgb : o.rgb;

  // underwater absorption of what is behind the camera-facing surface. The water pass
  // already absorbed along its own refracted ray; this is the column from the camera to
  // the seabed, island or water surface itself.
  if (under > 0.5 && !isWater) {
    vec3 T = exp(-uAbsorption * o.a);
    col = col * T + uScatterColor * (1.0 - T) * 0.55;
    vec4 sh = texture(uShafts, uv);
    float guard = exp(-abs(sh.a - o.a) * 0.5);
    col += uSunColor * sh.rgb * uUnder.y * guard;
  }

  col += texture(uSpray, uv).rgb;

  // exposure, filmic, slight vignette -- the reference leaves this to three's tone map
  col = aces(col * uExposure);
  vec2 q = uv - 0.5;
  col *= 1.0 - 0.22 * dot(q, q);
  fragColor = vec4(toSrgb(col), 1.0);
}