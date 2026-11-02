#version 300 es
// present.frag -- final copy from the composite's target to the back buffer. Both the
// composite and this pass write through the same fullscreen quad, so the row order
// already agrees end to end and no pass flips v.
uniform sampler2D uSrc;
in vec2 vUV;
out vec4 fragColor;
void main() {
  fragColor = vec4(textureLod(uSrc, vUV, 0.0).rgb, 1.0);
}
