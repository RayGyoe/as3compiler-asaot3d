#version 300 es
// water.frag -- the ocean surface, shaded from the cascade slopes.
//
// MODELLED ON Ultra-Water src/water/OceanSurface.js (FRAG), minus the parts this stage
// has no input for yet (shore map, shore waves, impacts, cascaded shadows, the foam
// texture): what is kept is what decides whether the water reads as water -- slope sum
// with per-cascade variance, geometric specular AA from dFdx/dFdy, screen-space
// refraction through the opaque depth with Beer-Lambert absorption, Fresnel between the
// sky and the mirrored scene, aerial perspective into the horizon, and the sun's GGX
// lobe with the facet-count glint that breaks it into sparkles.
//
// The pass is DEFERRED-ish: it draws with no depth attachment and rejects itself where
// the opaque pass made a nearer fragment (uOpaque.a is that pass's linear view depth).
// That is what lets it sample uOpaque for refraction without reading a texture it is
// writing, which is the whole reason the opaque scene has its own target.
uniform vec3 cameraPosition;   // auto-uploaded by the renderer
uniform mat4 viewMatrix;       // ditto (view-space depth + reflection distortion)
uniform sampler2D uDisp0;
uniform sampler2D uDisp1;
uniform sampler2D uDisp2;
uniform sampler2D uSlope0;
uniform sampler2D uSlope1;
uniform sampler2D uSlope2;
uniform sampler2D uSlope3;
uniform sampler2D uOpaque;      // rgb = opaque scene, a = its linear view depth
uniform sampler2D uReflection;  // mirrored scene, rgb premultiplied, a = coverage

uniform vec4 uLength;
uniform vec4 uOptics;     // base roughness, refraction, reflection distortion, fog (1/m)
uniform vec4 uFoam;       // bias, scale, -, brightness
uniform vec4 uSSS;        // crest peak, view term, NoL term, -
uniform vec3 uSunDir;
uniform vec3 uSunColor;
uniform vec3 uAbsorption;
uniform vec3 uScatterColor;
uniform vec3 uSkyAmbient;
uniform vec3 uCamForward;
uniform float uGlint;
uniform float uCamSide;   // -1 above the surface, +1 below
uniform float uTime;
uniform float uDebug;     // 0 = shaded; see the tail of main() for the channels

in vec3 vWorld;
in vec2 vXZ;
in float vUnresolved;
in vec2 vScreenUv;
in float vViewZ;
out vec4 fragColor;

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Poisson count with mean lam from one uniform number: inverse CDF, normal (logistic)
// approximation for large means.
float poisson(float lam, float u) {
  if (lam > 6.0) return max(0.0, lam + sqrt(lam) * log(u / (1.0 - u)) / 1.702);
  float p = exp(-lam), F = p, n = 0.0;
  for (int k = 0; k < 14; k++) { if (u <= F) break; n += 1.0; p *= lam / n; F += p; }
  return n;
}

void main() {
  vec2 uv = vScreenUv;
  float waterZ = vViewZ;
  vec4 op = textureLod(uOpaque, uv, 0.0);
  // Manual depth test: the opaque scene is in front of this water fragment.
  if (op.a < waterZ) discard;

  vec3 toCam = cameraPosition - vWorld;
  float dist = length(toCam);
  vec3 V = toCam / max(dist, 1e-4);

  // --- slopes and their variance ------------------------------------------------
  vec4 s0 = texture(uSlope0, vXZ / uLength.x);
  vec4 s1 = texture(uSlope1, vXZ / uLength.y);
  vec4 s2 = texture(uSlope2, vXZ / uLength.z);
  vec4 s3 = texture(uSlope3, vXZ / uLength.w);
  // The capillary cascade is damped here: the reference gets the same effect from its
  // shore map (chop is scaled by smoothstep on depth and by uWaveDamp.y in the lagoon),
  // and this stage has no bathymetry to ask. Without the damping the finest band carries
  // its full deep-water slope into the near field and the surface turns into crushed
  // foil -- sparkle everywhere, no swell.
  vec2 slope = s0.xy + s1.xy + s2.xy + s3.xy * 0.55;
  vec2 variance = max(s0.zw - s0.xy * s0.xy, 0.0) + max(s1.zw - s1.xy * s1.xy, 0.0)
                + max(s2.zw - s2.xy * s2.xy, 0.0) + max(s3.zw * 0.3 - s3.xy * s3.xy * 0.3, 0.0);
  vec3 Nrm = normalize(vec3(-slope.x, 1.0, -slope.y));

  // the normal's tilt as a screen offset: project a small world step along it
  vec3 vp = (viewMatrix * vec4(vWorld, 1.0)).xyz;
  vec3 dv = mat3(viewMatrix) * vec3(Nrm.x, 0.0, Nrm.z);
  vec2 nS = dv.xy - vp.xy / vp.z * dv.z;

  // geometric specular AA (Kaplanyan): the normal's change across the pixel is roughness
  vec3 dndx = dFdx(Nrm), dndy = dFdy(Nrm);
  float geoVar = min(0.25 * (dot(dndx, dndx) + dot(dndy, dndy)), 0.06);
  float alpha = sqrt(max(uOptics.x * uOptics.x + vUnresolved + variance.x + variance.y + geoVar, 1e-5));

  // Single-scattering albedo: the FRACTION of the light lost along the column that is
  // scattered back out. uScatterColor on its own is a coefficient (1/m, order 0.01..0.09),
  // so using it as a colour made every in-scattered term ~20x too dark -- the sea's body
  // went black and only the Fresnel-highlighted crests survived the tone map.
  vec3 albedo = uScatterColor / max(uScatterColor + uAbsorption, vec3(1e-4));
  float NoV = max(dot(Nrm, V), 1e-4);
  float NoL = dot(Nrm, uSunDir);

  // --- foam: the Jacobian of the choppy displacement ----------------------------
  float t0 = texture(uDisp0, vXZ / uLength.x).w;
  float t1 = texture(uDisp1, vXZ / uLength.y).w;
  float t2 = texture(uDisp2, vXZ / uLength.z).w;
  float jac = t0 + t1 + t2 - 2.0;
  float foam = clamp((uFoam.x - jac) * uFoam.y, 0.0, 1.0);

  // --- seen from below: Snell's window and total internal reflection -------------
  // Outside the window the surface mirrors the deep water; inside it, the sky above
  // comes through a ~97 degree cone. The edge is widened by the sub-pixel roughness so
  // a rough patch fades between the two instead of switching.
  if (int(uDebug) == 9) { fragColor = vec4(gl_FrontFacing ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0), 2.0); return; }
  if (!gl_FrontFacing) {
    float cosI = dot(V, -Nrm);
    const float COS_CRIT = 0.6614;  // sqrt(1 - 1/1.33^2)
    float edge = max(alpha * 1.5, 0.02);
    float win = smoothstep(COS_CRIT - edge, COS_CRIT + edge, cosI);
    vec3 deep = albedo * (skyViewLod(vec3(0.0, 1.0, 0.0), uSunDir, 5.0) + uSunColor * max(uSunDir.y, 0.0)) * 0.55;
    vec3 above = skyView(vec3(-V.x, abs(V.y), -V.z), uSunDir)
               + uSunColor * pow(max(dot(-V, uSunDir), 0.0), 48.0) * 0.6;
    vec3 c2 = mix(deep, above, win) * (1.0 - 0.55 * foam);
    // the column from the camera to the surface itself
    vec3 Tu = exp(-uAbsorption * dist);
    fragColor = vec4(c2 * Tu + albedo * (1.0 - Tu) * 0.55, 0.0);
    return;
  }

  // --- refraction + absorption through the water column -------------------------
  float thick = max(op.a - waterZ, 0.0) / max(dot(-V, uCamForward), 0.05);
  vec2 ruv = uv + nS * uOptics.y * clamp(thick * 0.25, 0.0, 1.0) / max(waterZ * 0.02, 1.0);
  ruv = clamp(ruv, vec2(0.002), vec2(0.998));
  vec4 rp = textureLod(uOpaque, ruv, 0.0);
  if (rp.a < waterZ) rp = op;                       // offset landed in front: no offset
  vec3 absorb = exp(-uAbsorption * thick);
  // Irradiance from the baked sky, not a constant: at golden hour the zenith and the
  // horizon differ by an order of magnitude, and a fixed "sky colour" is what made the
  // whole sea read as one flat navy slab.
  // The LUT level used here is the mean sky RADIANCE, while what lights the water is the
  // sky's IRRADIANCE (the cosine-weighted integral, ~pi times as much) -- and at sunset
  // that light is also warmer than the zenith. Without both corrections the body of the
  // sea sits an order of magnitude below the reference's, which is what made the troughs
  // read as black holes between the highlights.
  vec3 ambient = skyViewLod(vec3(0.0, 1.0, 0.0), uSunDir, 3.0) * vec3(15.0, 13.6, 11.5);
  vec3 inscatter = albedo * (ambient * 1.6 + uSunColor * 0.3 * max(uSunDir.y, 0.0));
  vec3 through = rp.rgb * absorb;

  // --- reflection: the sky, with the mirrored scene composited over it ----------
  // The reflection target is premultiplied and its alpha is coverage (0 where only sky
  // was drawn), so a blurred sample fades to sky instead of to black.
  vec3 R = reflect(-V, Nrm);
  R.y = abs(R.y);
  // The reflected sky is prefiltered by the surface roughness. Sampling level 0 made
  // every facet facing away mirror a razor-sharp cloud edge, which is what read as a
  // field of white cracks rather than as a sea.
  // The reference prefilters a 1024 cube; this LUT is 192x108, so its usable mip range
  // is ~2.7 levels shorter. Clamping at 5 (what the cube's log2(alpha*650) asks for)
  // landed on the 6x3 level -- the sky's MEAN radiance -- which turned every warm
  // reflection into flat grey and left the sea lit by nothing but its own body.
  float skyLod = clamp(alpha * 4.0, 0.0, 1.0);
  vec3 refl = skyViewLod(R, uSunDir, skyLod);
  float reflAmp = uOptics.z * 0.6 / (1.0 + dist * 0.04);
  vec2 ref2 = clamp(uv + clamp(nS * reflAmp, vec2(-0.06), vec2(0.06)), vec2(0.002), vec2(0.998));
  float reflLod = clamp(log2(max(alpha * 24.0, 1.0)), 0.0, 3.0);
  vec4 planar = textureLod(uReflection, ref2, reflLod);
  refl = refl * (1.0 - clamp(planar.a, 0.0, 1.0)) + planar.rgb;

  float F = 0.02 + 0.98 * pow(1.0 - NoV, 5.0);

  // --- sun: one GGX lobe, then the facet glint that breaks it into sparkles ------
  vec3 H = normalize(V + uSunDir);
  float NoH = max(dot(Nrm, H), 0.0), VoH = max(dot(V, H), 0.0);
  // GGX with the reference's height-correlated Smith visibility, and the lobe floored
  // so the sun acts as a small area light rather than a point: a point sun on a rough
  // surface is a few pixels of white, an area light is the broad amber road the
  // reference has.
  float aS = max(alpha, 0.055);
  float a2 = aS * aS;
  float nl = max(NoL, 0.0);
  float dd = NoH * NoH * (a2 - 1.0) + 1.0;
  float D = a2 / (PI * dd * dd);
  float vis = 0.5 / (nl * sqrt(NoV * NoV * (1.0 - a2) + a2) + NoV * sqrt(nl * nl * (1.0 - a2) + a2) + 1e-5);
  float Fh = 0.02 + 0.98 * pow(1.0 - VoH, 5.0);
  float spec = PI * D * vis * Fh * nl;

  // Glitter: the lobe as a finite number of sub-pixel facets. Per cell of about the
  // pixel footprint the expected count mirroring the sun is lam = density * area * D *
  // (sun solid angle / 4 VoH); a Poisson draw / lam keeps the mean energy while sparse
  // cells break into points. Two cell sizes crossfade so the dots do not crawl.
  if (uGlint > 0.0 && spec > 0.002) {
    const float FACETS = 2e4;   // per m^2
    vec2 fw = fwidth(vXZ);
    float lf = log2(max(max(fw.x, fw.y), 1e-3)) + 1.0;
    float l0 = floor(lf);
    float per = FACETS * D * NoH * 6.8e-5 / (4.0 * max(VoH, 0.05));
    float m = 0.0;
    for (int j = 0; j < 2; j++) {
      float l = l0 + float(j), sz = exp2(l);
      vec2 cell = floor(vXZ / sz);
      float lam = per * sz * sz;
      float tt = uTime * 3.0 + hash12(cell + l * 17.17) * 64.0, it = floor(tt);
      float n0 = poisson(lam, clamp(hash12(cell * 1.31 + it * 3.7), 1e-4, 0.9999));
      float n1 = poisson(lam, clamp(hash12(cell * 1.31 + (it + 1.0) * 3.7), 1e-4, 0.9999));
      m += (j == 0 ? 1.0 - (lf - l0) : lf - l0) *
           min(mix(n0, n1, smoothstep(0.0, 1.0, tt - it)) / max(lam, 1e-4), 300.0);
    }
    spec *= mix(1.0, clamp(m, 0.55, 6.0), uGlint * smoothstep(25.0, 90.0, dist));
  }
  vec3 sun = uSunColor * spec * (1.0 - foam * 0.7);

  // --- subsurface: light through a crest ---------------------------------------
  float h = max(vWorld.y, 0.0);
  float k1 = uSSS.x * h * pow(clamp(dot(uSunDir, -V), 0.0, 1.0), 4.0) * pow(0.5 - 0.5 * NoL, 3.0);
  float k2 = uSSS.y * pow(NoV, 2.0);
  vec3 sss = (k1 + k2) * albedo * uSunColor
           + uSSS.z * max(NoL, 0.0) * albedo * uSunColor;

  vec3 foamCol = (uSunColor * max(NoL, 0.0) * 0.35 + ambient * 0.85) * uFoam.w * vec3(0.72, 0.86, 0.9);
  vec3 body = through + (inscatter + sss) * (1.0 - absorb);
  body = mix(body, foamCol, foam * 0.85);
  vec3 col = mix(body, refl, F) + sun + refl * 0.22 * (1.0 - F);
  // Absolute level calibration. The reference's frame has a sky-to-water ratio of about
  // 1.8; this pass came out at ~3.5 because two of its inputs are weaker than the cube
  // they were ported from: the reflected sky is a 192x108 warped LUT rather than a 1024
  // cube (so the aureole and the horizon glow around a 3.5 degree sun are undersampled),
  // and the lagoon that reverts the body colour is a procedural floor rather than the
  // reference's lit sand. Rather than distort either input, the pass is lifted as a
  // whole to the level the tone mapping was designed around.
  col *= 1.45;

  // --- aerial perspective into the horizon sky ---------------------------------
  // Without this the far water stays as dark as the near water and the horizon reads
  // as a hard black edge instead of dissolving into the sky.
  float fog = 1.0 - exp(-dist * uOptics.w);
  col = mix(col, skyViewLod(-V, uSunDir, skyLod), fog);

  // Component channels for visual diagnosis (uDebug = 1..8). The composite passes them
  // through untone-mapped when it sees the same mode, so what comes back is the raw term
  // rather than an ACES-shaped version of it.
  if (int(uDebug) == 1) { fragColor = vec4(vec3(foam), 2.0); return; }
  if (int(uDebug) == 2) { fragColor = vec4(through, 2.0); return; }
  if (int(uDebug) == 3) { fragColor = vec4(refl, 2.0); return; }
  if (int(uDebug) == 4) { fragColor = vec4(sun, 2.0); return; }
  if (int(uDebug) == 5) { fragColor = vec4(vec3(thick / 32.0), 2.0); return; }
  if (int(uDebug) == 6) { fragColor = vec4(Nrm * 0.5 + 0.5, 2.0); return; }
  if (int(uDebug) == 7) { fragColor = vec4(vec3(alpha * 20.0), 2.0); return; }
  if (int(uDebug) == 8) { fragColor = vec4(vec3(F), 2.0); return; }
  if (int(uDebug) == 12) { fragColor = vec4(body, 2.0); return; }
  if (int(uDebug) == 13) { fragColor = vec4(refl * F, 2.0); return; }
  // tag 2 = top side: the composite must take this instead of the opaque scene
  fragColor = vec4(col, 2.0);
}