#version 300 es
// water_at.glsl -- the exact surface at a world xz: the choppy displacement moves points
// horizontally, so the height at q is the height at the point that LANDS on q, which is
// four fixed-point iterations away (the horizontal displacement is a contraction at the
// choppiness the spectrum uses).
uniform sampler2D uDisp0;
uniform sampler2D uDisp1;
uniform sampler2D uDisp2;
uniform vec4 uLength;

vec3 waterDisp(vec2 xz, vec3 lod) {
  return textureLod(uDisp0, xz / uLength.x, max(lod.x, 0.0)).xyz
       + textureLod(uDisp1, xz / uLength.y, max(lod.y, 0.0)).xyz
       + textureLod(uDisp2, xz / uLength.z, max(lod.z, 0.0)).xyz;
}

vec3 waterAt(vec2 q, vec3 lod) {
  vec2 p = q;
  vec3 d = vec3(0.0);
  for (int i = 0; i < 4; i++) { d = waterDisp(p, lod); p = q - d.xz; }
  return waterDisp(p, lod);
}