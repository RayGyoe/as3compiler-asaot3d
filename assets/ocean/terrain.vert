#version 300 es
// terrain.vert -- seabed and island meshes. Everything is in world space, so the model
// matrix is identity and the shader only needs the view matrix.
//
// The alpha channel this pass writes is NOT opacity: the opaque pass stores its linear
// view depth there, because the water and composite passes have to know what is behind
// them and a depth attachment cannot be sampled through this channel.
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
uniform mat4 projectionMatrix;
uniform mat4 viewMatrix;
out vec3 vWorld;
out vec3 vNormal;
out float vViewZ;

void main() {
  vWorld = position;
  vNormal = normal;
  vec4 vp = viewMatrix * vec4(position, 1.0);
  vViewZ = -vp.z;
  gl_Position = projectionMatrix * vp;
}