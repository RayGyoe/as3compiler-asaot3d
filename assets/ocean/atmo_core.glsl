// atmo_core.glsl -- constants every atmosphere shader shares. No uniforms, no
// functions: a pass includes only the blocks it actually references, because the
// native channel binds author uniforms by reflected name and a uniform the
// optimiser dropped is an ArgumentError at draw time.
//
// Ported from Ultra-Water src/scene/atmosphere.js (Hillaire 2020, "A Scalable and
// Production Ready Sky and Atmosphere Rendering Technique"). Distances are km.
precision highp float;
precision highp sampler2D;

#define PI 3.14159265359
const float RB = 6360.0;          // ground radius
const float RT = 6460.0;          // top of the atmosphere
const float OBS_H = 0.01;         // observer altitude (sea level)
const float H_TOP = 1132.2544;    // sqrt(RT^2 - RB^2)
const float MIE_G = 0.8;          // aerosol phase anisotropy
const float GROUND_ALBEDO = 0.1;
const vec2 SKY_RES = vec2(192.0, 108.0);
const float SUN_ILLUM = 1.0;

// LUT parameterisation helpers (Bruneton): the stored texel centres are inset half a
// texel so linear filtering never reaches past the edge.
vec2 toSub(vec2 u, vec2 n) { return u * (n - 1.0) / n + 0.5 / n; }
vec2 fromSub(vec2 u, vec2 n) { return (u - 0.5 / n) * n / (n - 1.0); }