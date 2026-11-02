#version 300 es
// sim_fft.frag -- one Stockham radix-2 inverse FFT stage (e^{+i}), verified against a
// naive DFT. Reads two packed spectra and writes two, so the whole 4-field transform is
// 16 draws (8 stages x horizontal/vertical) for all four cascades at once.
uniform highp sampler2D uIn0;
uniform highp sampler2D uIn1;
uniform int uSub;       // sub-transform size, 2..N
uniform int uVertical;  // 0 = rows, 1 = columns (inside each cascade block)
layout(location = 0) out vec4 out0;
layout(location = 1) out vec4 out1;

void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  int i = uVertical == 1 ? p.y : p.x;
  int hs = uSub >> 1;
  int e = (i / uSub) * hs + (i & (hs - 1));
  ivec2 pe, po;
  if (uVertical == 1) {
    pe = ivec2(p.x, e);
    po = ivec2(p.x, e + N / 2);
  } else {
    pe = ivec2(e, p.y);
    po = ivec2(e + N / 2, p.y);
  }
  float a = 2.0 * PI * float(i & (uSub - 1)) / float(uSub);
  vec2 tw = vec2(cos(a), sin(a));
  vec4 e0 = texelFetch(uIn0, pe, 0), o0 = texelFetch(uIn0, po, 0);
  vec4 e1 = texelFetch(uIn1, pe, 0), o1 = texelFetch(uIn1, po, 0);
  out0 = vec4(e0.xy + cmul(tw, o0.xy), e0.zw + cmul(tw, o0.zw));
  out1 = vec4(e1.xy + cmul(tw, o1.xy), e1.zw + cmul(tw, o1.zw));
}