#version 300 es
// sim_evolve.frag -- advance the spectrum in time and turn it into the four real fields
// the IFFT will carry. Two complex numbers per texel are packed into the two RGBA
// attachments (out0 = (A.x, A.y, B.x, B.y)), so the 16 butterflies below transform four
// real fields with one draw per stage instead of two.
uniform highp sampler2D uH0;
uniform vec4 uLength;
uniform float uTime;
uniform int uCascade;
layout(location = 0) out vec4 out0;
layout(location = 1) out vec4 out1;

// IFFT(A + iB) = a + ib for two real fields packed as one complex spectrum
vec2 pack2(vec2 a, vec2 b) { return vec2(a.x - b.y, a.y + b.x); }

void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  vec2 k = vec2(p - N / 2) * (2.0 * PI / uLength[uCascade]);
  float kl = length(k);
  float ik = kl > 1e-6 ? 1.0 / kl : 0.0;
  // omega is quantised to multiples of 2*PI/LOOP and time wraps at LOOP, so the sea
  // loops seamlessly and an fp32 phase never drifts
  const float W0 = 2.0 * PI / 300.0;
  float ph = 2.0 * PI * fract(floor(omega(kl) / W0) * (uTime / 300.0));
  vec2 e = vec2(cos(ph), sin(ph));
  vec4 h0 = texelFetch(uH0, p, 0);
  vec2 h = cmul(h0.xy, e) + cmul(h0.zw, vec2(e.x, -e.y));
  vec2 ih = vec2(-h.y, h.x);

  // gradients come out of k-space: d/dx is i*kx, so the whole choppy displacement and its
  // second moments cost one pass here and none at assemble time
  vec2 dx = ih * k.x * ik, dz = ih * k.y * ik;
  vec2 dxdx = -h * k.x * k.x * ik, dzdz = -h * k.y * k.y * ik, dxdz = -h * k.x * k.y * ik;
  vec2 dydx = ih * k.x, dydz = ih * k.y;

  out0 = vec4(pack2(dx, dz), pack2(h, dxdz));
  out1 = vec4(pack2(dydx, dydz), pack2(dxdx, dzdz));
}