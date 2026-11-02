#version 300 es
// sky.vert -- the background pass. The world ray for each corner is built from three
// vectors the host uploads (forward, and the half-extents of the frustum at unit depth),
// so no matrix has to be inverted per vertex. gl_Position.z = w pins the quad to the far
// plane, so the sky only shades the pixels no geometry wrote.
layout(location = 0) in vec3 aPos;
uniform vec3 uRayFwd;
uniform vec3 uRayRight;
uniform vec3 uRayUp;
out vec3 vDir;
void main() {
  vDir = uRayFwd + uRayRight * aPos.x + uRayUp * aPos.y;
  gl_Position = vec4(aPos.xy, 1.0, 1.0);
}
