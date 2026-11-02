#version 300 es
// ms.frag -- multiple-scattering LUT: 32x32, x = sun zenith cosine, y = altitude.
// 64 directions x 20 quadratic samples each, summed as the geometric series
// L2 / (1 - f_ms) (Hillaire eq. 10).
in vec2 vUV;
out vec4 fragColor;
void main() {
  vec2 uv = fromSub(vec2(vUV.x, 1.0 - vUV.y), vec2(32.0));
  float muS = uv.x * 2.0 - 1.0, h = max(uv.y * (RT - RB), OBS_H);
  float sinS = sqrt(max(1.0 - muS * muS, 0.0));
  vec3 L = vec3(0.0), F = vec3(0.0), fms;
  for (int j = 0; j < 8; j++) {
    float mu = 1.0 - 2.0 * (float(j) + 0.5) / 8.0, sinV = sqrt(1.0 - mu * mu);
    for (int i = 0; i < 8; i++) {
      float nu = cos(2.0 * PI * (float(i) + 0.5) / 8.0) * sinV * sinS + mu * muS;
      L += integrateMs(h, mu, muS, nu, 20, fms);
      F += fms;
    }
  }
  fragColor = vec4((L / 64.0) / max(1.0 - F / 64.0, vec3(1e-3)), 1.0);
}