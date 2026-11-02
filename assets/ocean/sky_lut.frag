#version 300 es
// sky_lut.frag -- the sky-view LUT: 192x108, the observer at sea level. u = sqrt of the
// azimuth cosine to the sun, v = sqrt(elevation/90deg); integrated once whenever the sun
// or the air changes, then every per-pixel sky lookup is one texture fetch.
uniform float uSunMu;
uniform float uSunIllum;
in vec2 vUV;
out vec4 fragColor;
void main() {
  vec2 uv = fromSub(vec2(vUV.x, 1.0 - vUV.y), SKY_RES);
  float cosPhi = 1.0 - 2.0 * uv.x * uv.x, elev = 0.5 * PI * uv.y * uv.y;
  float mu = sin(elev), cosE = cos(elev);
  vec3 v = vec3(cosE * cosPhi, mu, cosE * sqrt(max(1.0 - cosPhi * cosPhi, 0.0)));
  vec3 s = vec3(sqrt(max(1.0 - uSunMu * uSunMu, 0.0)), uSunMu, 0.0);
  vec3 fms;
  fragColor = vec4(integrate(OBS_H, mu, uSunMu, dot(v, s), 32, fms) * uSunIllum, 1.0);
}