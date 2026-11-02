#version 300 es
// bloom_up.frag -- 9-tap tent upsample, ported from Ultra-Water PostFX.js (`UP`).
//
// Drawn with one/one blending ONTO the next finer level, so the pyramid accumulates
// downwards: the wide, dim tail of the glow comes from the small levels, the tight
// highlight from the first one. Replacing the destination instead of adding to it would
// make the bloom a single-scale blur, which reads as a grey veil rather than a glow.
uniform sampler2D uSrc;
uniform vec2 uTexel;   // SOURCE (coarser) texel size
in vec2 vUV;
out vec4 fragColor;

void main() {
  vec4 d = uTexel.xyxy * vec4(1.0, 1.0, -1.0, 0.0);
  vec3 s = texture(uSrc, vUV - d.xy).rgb + texture(uSrc, vUV - d.wy).rgb * 2.0 + texture(uSrc, vUV - d.zy).rgb
         + texture(uSrc, vUV + d.zw).rgb * 2.0 + texture(uSrc, vUV).rgb * 4.0 + texture(uSrc, vUV + d.xw).rgb * 2.0
         + texture(uSrc, vUV + d.zy).rgb + texture(uSrc, vUV + d.wy).rgb * 2.0 + texture(uSrc, vUV + d.xy).rgb;
  fragColor = vec4(s * (1.0 / 16.0), 1.0);
}