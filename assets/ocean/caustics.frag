#version 300 es
// caustics.frag -- the landed area is one texel per pixel (the raster space IS the landed
// space), so the ratio is the undisturbed area in texels per pixel. Additive blending,
// one channel per slice depth; the clamp is the firefly limit.
uniform vec3 uMask;
in vec2 vOld;
out vec4 outColor;
void main() {
  vec2 a = dFdx(vOld), b = dFdy(vOld);
  outColor = vec4(uMask * min(abs(a.x * b.y - a.y * b.x), 16.0), 0.0);
}