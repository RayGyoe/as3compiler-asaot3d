// atmo_sky.glsl -- the baked sky-view LUT lookup. The observer sits at sea level, so
// only the upper hemisphere is stored; v = sqrt(elevation/90deg) crowds texels at the
// horizon, u = sqrt of the azimuth cosine to the sun does the same around the sun.
uniform sampler2D uSkyView;

// lod = 0 is the baked radiance; higher levels are the prefiltered version a rough
// surface reflects. Both the LUT's axes are warped (v = sqrt(elevation), u = sqrt of
// the azimuth cosine), so a mip level is a blur in that warped space rather than a
// true angular blur -- close enough at the low levels a rough sea actually asks for,
// and far better than sampling level 0 on a facet tilted 30 degrees.
vec3 skyViewLod(vec3 d, vec3 sunDir, float lod) {
  float v = sqrt(asin(clamp(d.y, 0.0, 1.0)) / (0.5 * PI));
  float cosPhi = dot(d.xz, sunDir.xz) *
      inversesqrt(max(dot(d.xz, d.xz) * dot(sunDir.xz, sunDir.xz), 1e-12));
  float u = sqrt(clamp(0.5 - 0.5 * cosPhi, 0.0, 1.0));
  return textureLod(uSkyView, toSub(vec2(u, v), SKY_RES), lod).rgb;
}

vec3 skyView(vec3 d, vec3 sunDir) {
  float v = sqrt(asin(clamp(d.y, 0.0, 1.0)) / (0.5 * PI));
  float cosPhi = dot(d.xz, sunDir.xz) *
      inversesqrt(max(dot(d.xz, d.xz) * dot(sunDir.xz, sunDir.xz), 1e-12));
  float u = sqrt(clamp(0.5 - 0.5 * cosPhi, 0.0, 1.0));
  return textureLod(uSkyView, toSub(vec2(u, v), SKY_RES), 0.0).rgb;
}