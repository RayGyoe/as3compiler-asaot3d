#version 300 es
// water.frag -- the ocean surface, shaded from the cascade slopes.
//
// MODELLED ON Ultra-Water src/water/OceanSurface.js (FRAG), minus the parts this stage
// has no input for yet (shore map, shore waves, impacts, cascaded shadows): what is kept
// is the part that decides whether the water reads as water -- slope sum with per-cascade
// variance, geometric specular AA from dFdx/dFdy, screen-space refraction through the
// opaque depth with Beer-Lambert absorption, Fresnel-mixed planar reflection, foam from
// the displacement Jacobian, and the sun's GGX lobe.
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
uniform sampler2D uReflection;  // half-res mirrored scene

uniform vec4 uLength;
uniform vec4 uOptics;     // base roughness, refraction, reflection distortion, -
uniform vec4 uFoam;       // bias, scale, foam tint, -
uniform vec3 uSunDir;
uniform vec3 uSunColor;
uniform vec3 uAbsorption;
uniform vec3 uScatterColor;
uniform vec3 uSkyAmbient;
uniform vec3 uCamForward;
uniform float uGlint;
uniform float uCamSide;   // -1 above the surface, +1 below
const float PI = 3.14159265359;

in vec3 vWorld;
in vec2 vXZ;
in float vUnresolved;
in vec2 vScreenUv;
in float vViewZ;
out vec4 fragColor;

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
  vec2 slope = s0.xy + s1.xy + s2.xy + s3.xy;
  vec2 variance = max(s0.zw - s0.xy * s0.xy, 0.0) + max(s1.zw - s1.xy * s1.xy, 0.0)
                + max(s2.zw - s2.xy * s2.xy, 0.0) + max(s3.zw - s3.xy * s3.xy, 0.0);
  vec3 Nrm = normalize(vec3(-slope.x, 1.0, -slope.y));

  // the normal's tilt as a screen offset: project a small world step along it
  vec3 vp = (viewMatrix * vec4(vWorld, 1.0)).xyz;
  vec3 dv = mat3(viewMatrix) * vec3(Nrm.x, 0.0, Nrm.z);
  vec2 nS = dv.xy - vp.xy / vp.z * dv.z;

  // geometric specular AA (Kaplanyan): the normal's change across the pixel is roughness
  vec3 dndx = dFdx(Nrm), dndy = dFdy(Nrm);
  float geoVar = min(0.25 * (dot(dndx, dndx) + dot(dndy, dndy)), 0.18);
  float alpha = sqrt(max(uOptics.x * uOptics.x + vUnresolved + variance.x + variance.y + geoVar, 1e-5));

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
  if (!gl_FrontFacing) {
    float cosI = dot(V, -Nrm);
    const float COS_CRIT = 0.6614;  // sqrt(1 - 1/1.33^2)
    float edge = max(alpha * 1.5, 0.02);
    float win = smoothstep(COS_CRIT - edge, COS_CRIT + edge, cosI);
    vec3 deep = uScatterColor * (uSkyAmbient + uSunColor * max(uSunDir.y, 0.0)) * 0.55;
    vec3 above = uSkyAmbient + uSunColor * pow(max(dot(-V, uSunDir), 0.0), 48.0) * 0.6;
    vec3 c2 = mix(deep, above, win) * (1.0 - 0.55 * foam);
    // the column from the camera to the surface itself
    vec3 Tu = exp(-uAbsorption * dist);
    fragColor = vec4(c2 * Tu + uScatterColor * (1.0 - Tu) * 0.55, 0.0);
    return;
  }

  // --- refraction + absorption through the water column -------------------------
  float thick = max(op.a - waterZ, 0.0) / max(dot(-V, uCamForward), 0.05);
  vec2 ruv = uv + nS * uOptics.y * clamp(thick * 0.25, 0.0, 1.0) / max(waterZ * 0.02, 1.0);
  ruv = clamp(ruv, vec2(0.002), vec2(0.998));
  vec4 rp = textureLod(uOpaque, ruv, 0.0);
  if (rp.a < waterZ) rp = op;                       // offset landed in front: no offset
  vec3 absorb = exp(-uAbsorption * thick);
  vec3 through = rp.rgb * absorb + uScatterColor * (1.0 - absorb);

  // --- planar reflection --------------------------------------------------------
  float F = 0.02 + 0.98 * pow(1.0 - NoV, 5.0);
  // The reflection target is the scene seen by the camera mirrored about y = 0. A point
  // ON the plane projects to the same screen position in both cameras, so the fragment's
  // OWN screen uv is the sampling coordinate -- the mirrored camera's matrices never have
  // to be uploaded, and the old uReflMatrix path (which was never set, so rc.w was ~0)
  // cannot silently sample the texture corner again.
  float reflAmp = uOptics.z * 0.6 / (1.0 + dist * 0.04);
  vec2 ref2 = uv + clamp(nS * reflAmp, vec2(-0.06), vec2(0.06));
  float reflLod = clamp(log2(max(alpha * 24.0, 1.0)), 0.0, 4.0);
  vec3 refl = textureLod(uReflection, clamp(ref2, vec2(0.002), vec2(0.998)), reflLod).rgb;

  // --- sun: one GGX lobe, plus the glint that makes the horizon sparkle ----------
  vec3 H = normalize(V + uSunDir);
  float NoH = max(dot(Nrm, H), 0.0), VoH = max(dot(V, H), 0.0);
  float a2 = alpha * alpha;
  float dd = NoH * NoH * (a2 - 1.0) + 1.0;
  float D = a2 / (PI * dd * dd);
  float Fh = 0.02 + 0.98 * pow(1.0 - VoH, 5.0);
  float kk = a2 * 0.5;
  float Gl = (max(NoL, 0.0) / (max(NoL, 0.0) * (1.0 - kk) + kk)) * (NoV / (NoV * (1.0 - kk) + kk));
  float spec = D * Fh * Gl / (4.0 * NoV * max(NoL, 1e-4)) * max(NoL, 0.0);
  float glint = pow(NoH, 900.0) * uGlint;
  vec3 sun = uSunColor * (spec + glint * 0.02) * (1.0 - foam * 0.7);

  // --- subsurface: light coming through a crest --------------------------------
  float crest = clamp(vWorld.y * 0.4, 0.0, 1.0);
  float sss = crest * pow(max(dot(V, -uSunDir), 0.0), 3.0) * 0.8;

  vec3 foamCol = (uSunColor * max(NoL, 0.0) * 0.35 + uSkyAmbient * 0.85) * uFoam.z;
  vec3 body = mix(through, foamCol, foam * 0.85);
  vec3 col = mix(body, refl, F) + sun + uScatterColor * sss * (0.3 + 0.7 * crest);
  // tag 2 = top side: the composite must take this instead of the opaque scene
  fragColor = vec4(col, 2.0);
}