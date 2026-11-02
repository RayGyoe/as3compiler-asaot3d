#version 300 es
// trans.frag -- transmittance LUT: 256x64, x = distance along the ray (Bruneton
// parameterisation), y = sqrt(r^2 - RB^2) i.e. altitude.
in vec2 vUV;
out vec4 fragColor;
void main() {
  // row 0 of a render target is the TOP of the frame, but a fullscreen quad's v runs 0 at
  // the bottom; every LUT bake therefore parameterises on a flipped v so that v = 0 in the
  // stored texture really is the v = 0 end of the parameterisation its samplers assume.
  vec2 uv = vec2(vUV.x, 1.0 - vUV.y);
  float rho = H_TOP * uv.y;
  float r = sqrt(rho * rho + RB * RB), h = rho * rho / (r + RB);
  float dMin = RT - r, d = mix(dMin, rho + H_TOP, uv.x);
  float mu = d <= 0.0 ? 1.0 : clamp((H_TOP * H_TOP - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0);
  vec3 od = vec3(0.0);
  for (int i = 0; i < 40; i++) {
    float fi = float(i), rr;
    od += medium(altAt(h, mu, d * (fi + 0.5) * (fi + 0.5) / 1600.0, rr)).ext * (2.0 * fi + 1.0);
  }
  fragColor = vec4(exp(-od * (d / 1600.0)), 1.0);
}