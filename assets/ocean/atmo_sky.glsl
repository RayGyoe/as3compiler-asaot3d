// atmo_sky.glsl -- the baked sky-view LUT lookup. The observer sits at sea level, so
// only the upper hemisphere is stored; v = sqrt(elevation/90deg) crowds texels at the
// horizon, u = sqrt of the azimuth cosine to the sun does the same around the sun.
uniform sampler2D uSkyView;

vec3 skyView(vec3 d, vec3 sunDir) {
  float v = sqrt(asin(clamp(d.y, 0.0, 1.0)) / (0.5 * PI));
  float cosPhi = dot(d.xz, sunDir.xz) *
      inversesqrt(max(dot(d.xz, d.xz) * dot(sunDir.xz, sunDir.xz), 1e-12));
  float u = sqrt(clamp(0.5 - 0.5 * cosPhi, 0.0, 1.0));
  return textureLod(uSkyView, toSub(vec2(u, v), SKY_RES), 0.0).rgb;
}