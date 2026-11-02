// atmo_math.glsl -- atmospheric medium and the geometry that walks it.
uniform vec3 uRayleigh;   // Rayleigh scattering at sea level (1/km)
uniform vec2 uMie;        // aerosol scattering, extinction at sea level (1/km)
uniform vec3 uOzone;      // ozone absorption at the layer peak (1/km)

// Altitude after travelling t along a ray that leaves altitude h with zenith cosine
// mu. q = r^2 - RB^2 is evaluated directly so that shallow rays do not cancel.
float altAt(float h, float mu, float t, out float r) {
  float q = h * (2.0 * RB + h) + t * (2.0 * (RB + h) * mu + t);
  r = sqrt(RB * RB + q);
  return q / (r + RB);
}

struct Medium { vec3 ray; float mie; vec3 scat; vec3 ext; };

Medium medium(float h) {
  h = max(h, 0.0);
  float dM = exp(-h / 1.2);
  Medium m;
  m.ray = uRayleigh * exp(-h / 8.0);
  m.mie = uMie.x * dM;
  m.scat = m.ray + m.mie;
  // ozone: a tent between 10 and 40 km
  m.ext = m.ray + uMie.y * dM + uOzone * max(0.0, 1.0 - abs(h - 25.0) / 15.0);
  return m;
}

float distTop(float r, float mu) {
  return max(-r * mu + sqrt(max(r * r * (mu * mu - 1.0) + RT * RT, 0.0)), 0.0);
}