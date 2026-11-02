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
uniform float uDebug;            // mirrors water.frag's channel selector for diagnosis
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

void main() {
  // No flip here: every target in this pass chain (opaque, water, spray, lens, shafts and
  // this composite's own output) is written and sampled through the same fullscreen quad,
  // so their rows already agree. The one flip in the chain lives in present.frag, which is
  // the only pass that crosses from a render-target texture to the drawable.
  vec2 uv = vUV;
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

  if (uDebug > 0.5) { fragColor = vec4(isWater ? w.rgb : o.rgb, 1.0); return; }

  // White balance and a little saturation before the tone map. At a 3.5 degree sun the
  // reference's frame carries R > G > B everywhere (its water averages a red/blue of
  // about 2.0); this chain lands at about 1.0 without a grade, because the atmosphere
  // bake is physically neutral rather than camera-neutral. The post section of the
  // reference has the same job one step earlier.
  col *= vec3(1.10, 1.0, 0.86);
  col = mix(vec3(dot(col, vec3(0.2126, 0.7152, 0.0722))), col, 1.12);

  // exposure, filmic, slight vignette -- the reference leaves this to three's tone map
  col = aces(col * uExposure);
  vec2 q = uv - 0.5;
  col *= 1.0 - 0.22 * dot(q, q);
  fragColor = vec4(col, 1.0);
}