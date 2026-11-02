#version 300 es
// water.vert -- the ocean surface. Camera-centred polar grid (built on the CPU, position
// in metres relative to the camera in xz), displaced by three cascade atlases.
//
// The per-vertex LOD is the whole trick: `cell` is the world size of this vertex's grid
// cell, converted into cascade texels, so a vertex 2 km away samples a coarse mip instead
// of aliasing the 2.1 m cascade into noise. +1 LOD bias because box-filtered mips still
// leak a little past Nyquist.
layout(location = 0) in vec3 aPos;
uniform vec3 cameraPosition;   // auto-uploaded by the renderer
uniform mat4 projectionMatrix;
uniform mat4 viewMatrix;
uniform vec4 uLength;
uniform sampler2D uDisp0;
uniform sampler2D uDisp1;
uniform sampler2D uDisp2;
uniform sampler2D uSlope0;
uniform sampler2D uSlope1;
uniform sampler2D uSlope2;
uniform sampler2D uSlope3;
uniform float uCellStep;   // radians per sector: cell = r * uCellStep
uniform float uWind;
out vec3 vWorld;
out vec2 vXZ;
out float vUnresolved;
// Screen uv and the surface's own view depth are produced HERE, not recovered from
// gl_FragCoord in the fragment stage. Two reasons: a fragment's [[position]].z is only
// meaningful when the pass has a depth attachment (the water pass has none, and reading
// it gave 0), and reconstructing metres from a normalised depth at near=0.5/far=12000
// throws away the precision that "is the seabed behind this pixel" needs. Interpolated
// view-space z is exact and free.
out vec2 vScreenUv;
out float vViewZ;

vec3 cascadeDisp(vec2 xz, vec3 lod) {
  return textureLod(uDisp0, xz / uLength.x, max(lod.x, 0.0)).xyz
       + textureLod(uDisp1, xz / uLength.y, max(lod.y, 0.0)).xyz
       + textureLod(uDisp2, xz / uLength.z, max(lod.z, 0.0)).xyz;
}

void main() {
  vec2 local = aPos.xz;
  vec2 xz = cameraPosition.xz + local;
  float cell = max(length(local), 1.0) * uCellStep;

  vec3 d = cascadeDisp(xz, log2(cell * 256.0 / uLength.xyz) + 1.0);

  // Cox-Munk mean square slope minus what the cascades actually carry (each cascade's
  // 1x1 mip IS its mean square slope): the remainder is sub-texel roughness, and it is
  // what keeps the horizon from turning into a mirror.
  vec4 m0 = textureLod(uSlope0, vec2(0.5), 8.0), m1 = textureLod(uSlope1, vec2(0.5), 8.0);
  vec4 m2 = textureLod(uSlope2, vec2(0.5), 8.0), m3 = textureLod(uSlope3, vec2(0.5), 8.0);
  vUnresolved = max(0.003 + 0.00512 * uWind - (m0.z + m0.w + m1.z + m1.w + m2.z + m2.w + m3.z + m3.w), 0.0);

  vXZ = xz;
  vWorld = vec3(xz.x + d.x, d.y, xz.y + d.z);
  vec4 vp = viewMatrix * vec4(vWorld, 1.0);
  vViewZ = -vp.z;
  vec4 clip = projectionMatrix * vp;
  // row 0 of every render target is the TOP of the frame, so clip +y maps to uv.y 0
  vScreenUv = vec2(clip.x, -clip.y) * (0.5 / clip.w) + 0.5;
  gl_Position = clip;
}