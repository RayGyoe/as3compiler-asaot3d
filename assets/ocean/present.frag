#version 300 es
// present.frag -- final copy from the composite's target to the back buffer. Both the
// composite and this pass write through the same fullscreen quad, so the row order
// already agrees end to end and no pass flips v.
//
// This is also where linear light becomes display-referred. The back buffer is a plain
// BGRA8Unorm drawable, not an _sRGB view, so Metal does NOT encode on write: handing it
// linear values and letting the display interpret them as sRGB crushes every midtone
// (a 0.3 linear sea reads as 0.3 instead of 0.58). The composite works in linear light
// all the way through, so the transfer function belongs here, once.
uniform sampler2D uSrc;
in vec2 vUV;
out vec4 fragColor;

vec3 toSrgb(vec3 c) {
  vec3 lo = c * 12.92;
  vec3 hi = 1.055 * pow(max(c, vec3(1e-5)), vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), c));
}

void main() {
  fragColor = vec4(toSrgb(textureLod(uSrc, vUV, 0.0).rgb), 1.0);
}