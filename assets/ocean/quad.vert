#version 300 es
// quad.vert -- fullscreen triangle-pair. aPos is in [-1,1]; vUV is top-left origin in
// the same orientation as a render-target texel (row 0 of a target is vUV.y = 0).
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUv;
out vec2 vUV;
void main() {
  vUV = aUv;
  gl_Position = vec4(aPos.xy, 0.0, 1.0);
}