#version 300 es
// terrain.frag -- sand/rock shading for the seabed and the islands, with wave caustics
// where the surface is overhead and Beer-Lambert absorption when the camera is below the
// waterline. Ported from the terrain half of Ultra-Water's surface pass: the caustic
// entry point is registered to the surface, so looking straight down and looking along
// the sun do not give the same pattern.
uniform vec3 uSunDir;
uniform vec3 uSunColor;
uniform vec3 uSkyAmbient;
uniform vec3 uAbsorption;
uniform vec3 uScatterColor;
uniform vec3 uSand;
uniform vec3 uRock;
uniform float uCausticStrength;  // 0 for anything that is always above water
uniform float uReflPass;         // 1 inside the planar-reflection pass
in vec3 vWorld;
in vec3 vNormal;
in float vViewZ;
out vec4 fragColor;

void main() {
  // The reflection is the world seen in a mirror at y=0, so only what is ABOVE the
  // water can appear in it. Discarding here is the exact equivalent of the reference's
  // oblique near plane, and it costs one compare instead of a projection matrix rebuild.
  if (uReflPass > 0.5 && vWorld.y < 0.0) discard;
  vec3 N = normalize(vNormal);
  float depth = max(-vWorld.y, 0.0);
  // slope decides sand vs rock: the dunes are shallow, the island cliffs are not
  float flat_ = smoothstep(0.55, 0.95, N.y);
  vec3 albedo = mix(uRock, uSand, flat_);

  float NoL = max(dot(N, uSunDir), 0.0);
  vec3 col = albedo * (uSkyAmbient + uSunColor * NoL);

  if (uCausticStrength > 0.0 && depth > 0.0) {
    // where the flat-water refracted sun ray through this point crosses the surface
    vec3 rs = refract(-uSunDir, vec3(0.0, 1.0, 0.0), 0.75188);
    vec2 entry = vWorld.xz + rs.xz / max(rs.y, 0.05) * depth;
    // one caustic texel is 2.3 cm; blur it once it is smaller than a pixel
    float lod = max(0.0, log2(max(fwidth(entry.x), fwidth(entry.y)) * 42.6667));
    float c = waveCaustic(entry, depth, lod);
    // mip 1: an RTT target has no MSAA in this backend, so a single sub-texel sliver is
    // point-sampled as one bead instead of a line. Half a mip of blur costs nothing at
    // this scale and keeps the caustic lines continuous (see three-api-design.md §39).
    c = mix(c, waveCaustic(entry, depth, lod + 1.0), 0.45);
    col += albedo * uSunColor * NoL * (c - 1.0) * uCausticStrength;
  }

  // Absorption of the water column is applied in the composite, not here: the camera
  // can straddle the surface, so "how much water is between me and this pixel" is a
  // per-pixel question that only the composite's lens map can answer.
  fragColor = vec4(col, vViewZ);
}