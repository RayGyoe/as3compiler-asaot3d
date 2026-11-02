// atmo_ms.glsl -- the multiple-scattering LUT (Hillaire eq. 10, stored as Psi_ms).
uniform sampler2D uMsLut;

vec3 multiScatter(float h, float muS) {
  vec2 uv = clamp(vec2(muS * 0.5 + 0.5, h / (RT - RB)), 0.0, 1.0);
  return textureLod(uMsLut, toSub(uv, vec2(32.0)), 0.0).rgb;
}