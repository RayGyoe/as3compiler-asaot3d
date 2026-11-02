// atmo_phases.glsl -- Rayleigh and Cornette-Shanks/HG aerosol phase functions.
float rayleighPhase(float c) { return 0.0596831 * (1.0 + c * c); }

float miePhase(float c) {
  float k = 1.0 + MIE_G * MIE_G - 2.0 * MIE_G * c;
  return (1.0 - MIE_G * MIE_G) / (4.0 * PI * k * sqrt(k));
}