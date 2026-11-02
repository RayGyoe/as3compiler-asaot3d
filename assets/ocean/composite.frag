#version 300 es
// composite.frag -- assemble the frame, in LINEAR HDR. The grade (exposure, tone map,
// bloom, contrast, saturation, sRGB) is grade.frag's job now, because bloom and
// auto-exposure both need values before the tone map -- see that file.
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
in vec2 vUV;
out vec4 fragColor;

void main() {
  // NO FLIP HERE ANY MORE, and none anywhere else: measured, not reasoned. This pass used
  // to carry one because it wrote the drawable, and a frame read back through
  // `drawToBitmapData` is the same as the window -- so the flip was real, not a caption
  // for a readback artefact. Now that this pass writes `_hdr` and grade.frag writes the
  // drawable, the chain is row-preserving end to end: this pass samples its sources at
  // `vUV` and the grade samples `uHdr` at `vUV`, and the result matches the pre-refactor
  // frame to a mean |diff| of 0.01/255 across the whole frame (the half-float round trip).
  // Keeping the old flip in the composite, or moving it to the grade, both came out
  // upside down -- one flip too many.
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

  // Linear HDR out: grade.frag applies exposure, the tone map and the transfer function.
  // The alpha is unused downstream (the tag was consumed above), but it is written as 1
  // so a dump of this target is not mistaken for the water pass's tag convention.
  fragColor = vec4(col, 1.0);
}