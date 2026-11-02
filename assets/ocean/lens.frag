#version 300 es
// lens.frag -- how far the near plane is BELOW the rendered surface, on a 64x36 grid.
// A wave washing over the camera therefore splits the screen at the exact waterline
// instead of switching the whole post effect on when camera.y crosses zero.
uniform mat4 uInvProj;
uniform mat4 uCamWorld;
in vec2 vUV;
out vec4 fragColor;

void main() {
  vec4 v = uInvProj * vec4(vUV * 2.0 - 1.0, -1.0, 1.0);
  vec3 nearW = (uCamWorld * vec4(v.xyz / v.w, 1.0)).xyz;
  fragColor = vec4(waterAt(nearW.xz, vec3(0.0)).y - nearW.y, 0.0, 0.0, 1.0);
}