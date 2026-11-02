#version 300 es
// spray.frag -- additive billboard; the sun's colour comes in pre-multiplied, so the
// blend is simply one/one.
uniform vec3 uSprayColor;
in vec2 vCorner;
in float vFade;
out vec4 fragColor;

void main() {
  if (vFade <= 0.001) discard;
  float r = length(vCorner);
  float a = smoothstep(1.0, 0.15, r) * vFade;
  fragColor = vec4(uSprayColor * a, a);
}