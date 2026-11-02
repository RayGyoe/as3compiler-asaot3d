#version 300 es
// sky.frag -- background sky: baked sky-view LUT + analytic sun disc + one cloud deck.
// Ported from Ultra-Water src/scene/sky.js (CUBE_FRAG / BG_FRAG). The sun disc stays out
// of the LUT so it can be as tight as it needs to be; alpha 1 means "sky covered this
// pixel" for the passes that composite over it.
uniform vec3 uSunDir;
uniform vec3 uSunColor;
uniform float uSunIllum;
uniform float uCloudCoverage;
uniform float uAlpha;   // opaque pass: 1e4 (far depth); reflection pass: 0 (no coverage)
in vec3 vDir;
out vec4 fragColor;

const float CLOUD_H = 2.5;                      // cloud deck altitude (km)
const vec3 WATER = vec3(0.02, 0.035, 0.045);    // deep-water body reflectance

// value noise (three's Sky.js gradient/hash), static in time
vec2 gradient(vec2 i) {
  vec3 p = fract(i.xyx * vec3(0.1031, 0.1030, 0.0973));
  p += dot(p, p.yzx + 33.33);
  return fract((p.xx + p.yz) * p.zy) * 2.0 - 1.0;
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  float a = dot(gradient(i), f);
  float b = dot(gradient(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
  float c = dot(gradient(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
  float d = dot(gradient(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.6;
}
float fbm(vec2 p) {
  float s = 0.0, a = 1.0;
  for (int i = 0; i < 4; i++) { s += a * noise(p); a *= 0.5; p *= 2.0; }
  return s;
}

void main() {
  vec3 d = normalize(vDir);
  vec3 up = skyView(vec3(0.0, 1.0, 0.0), uSunDir);

  if (d.y < 0.0) {
    // below the horizon: the sea. Fresnel between the mirrored sky and a dark body, so
    // the bottom of the frame never shows a bright band past the last ocean ring.
    float F = 0.02 + 0.98 * pow(1.0 + d.y, 5.0);
    vec3 body = WATER * (uSunColor * max(uSunDir.y, 0.0) + up);
    fragColor = vec4(mix(body, skyView(vec3(d.x, -d.y, d.z), uSunDir), F), uAlpha);
    return;
  }

  vec3 col = skyView(d, uSunDir);
  float vis = 1.0;
  if (d.y > 1e-3 && uCloudCoverage > 0.0) {
    vec2 p = d.xz / d.y * 0.396;
    float n = clamp(fbm(p) * 0.7 + 0.5, 0.0, 1.0);
    float th = 1.0 - clamp(uCloudCoverage + noise(p * 0.3) * 0.222, 0.0, 1.0);
    float fade = smoothstep(0.0, 0.063, d.y);
    float mask = smoothstep(th, th + 0.3, n) * fade;
    float depth = max(0.0, n - th);
    float beer = exp(-4.0 * depth);
    float shade = mix(0.45, 1.0, clamp(beer * (1.0 - beer * beer) * 2.6, 0.0, 1.0));
    float c = dot(d, uSunDir);
    float silver = clamp(0.51 / pow(1.49 - c * 1.4, 1.5), 0.0, 3.0);
    float edge = mask * (1.0 - mask) * 4.0;
    float alpha = (1.0 - exp(-depth * 6.6)) * fade;

    float r0 = RB + OBS_H, rc = RB + CLOUD_H;
    float t = -r0 * d.y + sqrt(r0 * r0 * d.y * d.y + (rc - r0) * (rc + r0));
    float muV = (r0 * d.y + t) / rc;
    float muS = clamp((r0 * uSunDir.y + t * c) / rc, -1.0, 1.0);
    vec3 sun = uSunIllum * transmittance(CLOUD_H, muS) * sunVisible(CLOUD_H, rc, muS) * 0.22;
    vec3 cloud = up + sun * (shade + silver * edge * 0.6);
    vec3 tv = clamp(transmittance(OBS_H, d.y) / max(transmittance(CLOUD_H, muV), vec3(1e-4)), 0.0, 1.0);
    col = mix(col, mix(col, cloud, tv), alpha);
    vis = 1.0 - alpha;
  }

  // 0.27 deg disc with limb darkening plus a tight glow, hidden behind clouds
  float c = dot(d, uSunDir);
  float disc = smoothstep(0.999985, 0.999992, c) * (0.6 + 0.4 * smoothstep(0.999985, 1.0, c));
  col += uSunColor * (disc * 900.0 + pow(max(c, 0.0), 2200.0) * 1.5) * vis;
  // .a is the opaque pass's linear view depth (see terrain.frag). The sky has none,
  // and 1e4 m is far past any geometric depth, so it neither occludes the water nor
  // absorbs anything under it.
  fragColor = vec4(col, uAlpha);
}