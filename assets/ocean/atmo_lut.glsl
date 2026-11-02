// atmo_lut.glsl -- the transmittance LUT and its Bruneton parameterisation.
uniform sampler2D uTransLut;

vec2 transUv(float h, float mu) {
  float r = RB + h, rho = sqrt(max(h, 0.0) * (2.0 * RB + h));
  float dMin = RT - r, dMax = rho + H_TOP;
  return vec2((distTop(r, mu) - dMin) / (dMax - dMin), rho / H_TOP);
}

vec3 transmittance(float h, float mu) {
  return textureLod(uTransLut, transUv(h, mu), 0.0).rgb;
}

// 0 where the planet hides the sun from altitude h along radius r.
float sunVisible(float h, float r, float muS) {
  return step(-sqrt(max(h, 0.0) * (2.0 * RB + h)) / r, muS);
}