#version 300 es
// shafts.frag -- single-scattered sun along the view ray, at quarter resolution. Light
// entering the water carries the same wave caustics that light the seabed, so marching
// them gives the god rays for free: rays that sweep across the pattern average to haze,
// rays that run along the light keep their shafts.
uniform mat4 uInvProj;
uniform mat4 uCamWorld;
uniform sampler2D uColor;      // the opaque pass; .a is its linear view depth
uniform vec3 uSunDir;
uniform vec3 uAbsorption;
uniform vec4 uUnder;           // scattering coefficient (1/m), strength, shaft range (m), -
const float PI = 3.14159265359;
uniform float uFrame;          // frame index mod 64: rotates the march jitter
in vec2 vUV;
out vec4 fragColor;

void main() {
  vec4 o = texture(uColor, vUV);
  vec4 vv = uInvProj * vec4(vUV * 2.0 - 1.0, 1.0, 1.0);
  float dist = min(o.a, uUnder.z);
  vec3 dir = normalize(mat3(uCamWorld) * (vv.xyz / vv.w));
  vec3 camPos = uCamWorld[3].xyz;
  vec3 sigT = uAbsorption + uUnder.x;
  vec3 rs = refract(-uSunDir, vec3(0.0, 1.0, 0.0), 0.75188);
  vec3 acc = vec3(0.0);
  if (rs.y < -0.05) {
    const int STEPS = 16;
    float stepL = dist / float(STEPS);
    // interleaved gradient noise, advanced by the golden ratio each frame
    float jit = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))) + uFrame * 0.618034);
    float mu = dot(dir, -rs);
    const float g = 0.7;
    float phase = (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5)) + 0.04;
    // prefilter along the ray: one step covers this much of the 12 m pattern
    vec2 dbase = dir.xz - rs.xz / rs.y * dir.y;
    float lod = max(log2(max(length(dbase) * stepL * CAUSTIC_TEXELS_PER_M, 1.0)), 1.0);
    for (int i = 0; i < STEPS; i++) {
      float s = (float(i) + jit) * stepL;
      vec3 p = camPos + dir * s;
      float pd = -p.y;
      if (pd <= 0.0) continue;
      vec2 entry = p.xz + rs.xz / max(rs.y, -0.05) * pd;
      acc += waveCaustic(entry, pd, lod) * exp(-sigT * (s + pd / -rs.y)) * smoothstep(0.0, 0.6, pd);
    }
    acc *= phase * stepL;
  }
  fragColor = vec4(acc, dist);
}