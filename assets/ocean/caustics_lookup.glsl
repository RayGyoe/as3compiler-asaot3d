#version 300 es
// caustics_lookup.glsl -- the consumer side: waveCaustic(entryXZ, depth, lod) is a
// direct-sun multiplier with mean ~1. Textures are mipmapped and repeat, tiling every
// 12 m. entryXZ is where the flat-water refracted sun ray through the shaded point
// crosses the surface: P.xz + rs.xz / rs.y * depth, rs = refract(-sun, up, 1/1.33).
uniform sampler2D uCaustics;      // 512^2, depth 1.5 m, in .r
uniform sampler2D uCausticsDeep;  // 256^2, depths 4 m and 10 m, in .r and .g
const float CAUSTIC_TEXELS_PER_M = 42.6666667;   // 512 / 12

float waveCaustic(vec2 entryXZ, float depth, float lod) {
  vec2 uv = entryXZ * 0.0833333;   // 1 / 12 m
  float v = textureLod(uCaustics, uv, lod).r;
  if (depth > 1.5) {
    // deep texels are half the near ones; past the deepest slice keep it, one mip blurrier
    // per doubling of depth
    vec2 d = textureLod(uCausticsDeep, uv, max(lod - 1.0, 0.0) + log2(max(depth / 10.0, 1.0))).rg;
    v = depth < 4.0 ? mix(v, d.r, (depth - 1.5) / 2.5)
                    : mix(d.r, d.g, clamp((depth - 4.0) / 6.0, 0.0, 1.0));
  }
  return mix(1.0, v, clamp(depth / 1.5, 0.0, 1.0));   // no caustic at zero depth
}