// asaot3d/probes/scene-smoke-m20/SceneSmokeM20.as -- M20 scene/state smoke.
//
// M20 fixed four P1 divergences and turned two inert scene fields into real
// features. The GPU side of each is a picture (apps/scene-m20); what can be
// pinned here is the pure decision tables and the CPU mirror of the fog math:
//
//   A. effectiveBlending  -- three.js only special-cases NormalBlending+opaque
//   B. drawFirstIndex / drawNumTriangles -- geometry.drawRange (with -1 = end)
//   C. fog mode + fogFactorAt -- the CPU mirror of the emitted AGAL block
//   D. Fog / FogExp2 defaults -- three.js r187 values
//   E. material / scene defaults -- `fog = true`, `map = null`, bg/fog null
//   F. drawRange rounding rules -- never index out of bounds
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/scene-smoke-m20/SceneSmokeM20.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/scene-smoke-m20 --run
import asaot.three.AGALRenderer;
import asaot.three.core.BufferGeometry;
import asaot.three.materials.Material;
import asaot.three.materials.MeshBasicMaterial;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.math.Color;
import asaot.three.scenes.Fog;
import asaot.three.scenes.FogExp2;
import asaot.three.scenes.Scene;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-9):Boolean
{
    return Math.abs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// A. blending gate
// ---------------------------------------------------------------------------
// three.js WebGLState.setMaterial:763-766
//   (blending === NormalBlending && transparent === false) ? NoBlending
//                                                          : blending
// Everything else is applied as authored -- including AdditiveBlending on an
// opaque material, which three.js does NOT downgrade.
check("A1 opaque NormalBlending degrades to NoBlending",
      AGALRenderer.effectiveBlending(Material.NormalBlending, false) == Material.NoBlending);
check("A2 transparent NormalBlending is applied as authored",
      AGALRenderer.effectiveBlending(Material.NormalBlending, true) == Material.NormalBlending);
check("A3 opaque NoBlending stays NoBlending",
      AGALRenderer.effectiveBlending(Material.NoBlending, false) == Material.NoBlending);
check("A4 opaque AdditiveBlending is NOT downgraded (three.js applies it)",
      AGALRenderer.effectiveBlending(Material.AdditiveBlending, false) == Material.AdditiveBlending);
check("A5 transparent AdditiveBlending is unchanged",
      AGALRenderer.effectiveBlending(Material.AdditiveBlending, true) == Material.AdditiveBlending);
check("A6 opaque MultiplyBlending is unchanged",
      AGALRenderer.effectiveBlending(Material.MultiplyBlending, false) == Material.MultiplyBlending);
check("A7 CustomBlending passes through (degradation happens at the setBlendFactors site)",
      AGALRenderer.effectiveBlending(Material.CustomBlending, false) == Material.CustomBlending);
check("A8 the gated opaque Normal pair is (one, zero)",
      AGALRenderer.blendSrcFor(AGALRenderer.effectiveBlending(Material.NormalBlending, false)) == "one" &&
      AGALRenderer.blendDstFor(AGALRenderer.effectiveBlending(Material.NormalBlending, false)) == "zero");
check("A9 the transparent Normal pair is (sourceAlpha, oneMinusSourceAlpha)",
      AGALRenderer.blendSrcFor(AGALRenderer.effectiveBlending(Material.NormalBlending, true)) == "sourceAlpha" &&
      AGALRenderer.blendDstFor(AGALRenderer.effectiveBlending(Material.NormalBlending, true)) == "oneMinusSourceAlpha");

// ---------------------------------------------------------------------------
// B/C. drawRange: start/count are INDEX offsets, count = -1 means "to the end"
// ---------------------------------------------------------------------------
var geo:BufferGeometry = new BufferGeometry();
check("B1 the default range starts at 0", geo.drawRange.start == 0);
check("B2 the default range is the -1 sentinel (D7), not JS Infinity", geo.drawRange.count == -1);

// 4 triangles = 12 indices.
check("B3 default: first index 0", AGALRenderer.drawFirstIndex(geo) == 0);
check("B4 default: every triangle is drawn", AGALRenderer.drawNumTriangles(geo, 12) == 4);

geo.setDrawRange(3, 6);
check("B5 start=3 -> first index 3", AGALRenderer.drawFirstIndex(geo) == 3);
check("B6 count=6 -> two triangles", AGALRenderer.drawNumTriangles(geo, 12) == 2);

geo.setDrawRange(6, -1);
check("B7 count=-1 from index 6 reaches the end", AGALRenderer.drawNumTriangles(geo, 12) == 2);

geo.setDrawRange(0, 100);
check("B8 a count past the buffer is clamped", AGALRenderer.drawNumTriangles(geo, 12) == 4);

geo.setDrawRange(12, 3);
check("B9 a range starting at the end draws nothing", AGALRenderer.drawNumTriangles(geo, 12) == 0);

geo.setDrawRange(99, 3);
check("B10 a start past the buffer draws nothing", AGALRenderer.drawNumTriangles(geo, 12) == 0);

geo.setDrawRange(4, 3);
check("B11 a mid-triangle start is floored to the triangle boundary",
      AGALRenderer.drawFirstIndex(geo) == 3);

geo.setDrawRange(0, 5);
check("B12 a partial trailing triangle is dropped",
      AGALRenderer.drawNumTriangles(geo, 12) == 1);

geo.setDrawRange(-5, -1);
check("B13 a negative start is clamped to 0",
      AGALRenderer.drawFirstIndex(geo) == 0 && AGALRenderer.drawNumTriangles(geo, 12) == 4);

// An empty geometry must never yield a negative triangle count (drawTriangles
// with a negative count is not defined).
check("B14 an empty buffer yields zero triangles", AGALRenderer.drawNumTriangles(geo, 0) == 0);

// ---------------------------------------------------------------------------
// C. fog mode dispatch
// ---------------------------------------------------------------------------
var lin:Fog = new Fog(0x112233, 2, 40);
var exp:FogExp2 = new FogExp2(0x445566, 0.05);

check("C1 Fog maps to FOG_LINEAR", AGALRenderer.fogModeOf(lin) == AGALRenderer.FOG_LINEAR);
check("C2 FogExp2 maps to FOG_EXP2", AGALRenderer.fogModeOf(exp) == AGALRenderer.FOG_EXP2);
check("C3 a null fog is FOG_NONE", AGALRenderer.fogModeOf(null) == AGALRenderer.FOG_NONE);
check("C4 an unrelated object is FOG_NONE (not a crash)",
      AGALRenderer.fogModeOf(new Color(0xff0000)) == AGALRenderer.FOG_NONE);
check("C5 the three modes are distinct values",
      AGALRenderer.FOG_NONE != AGALRenderer.FOG_LINEAR &&
      AGALRenderer.FOG_LINEAR != AGALRenderer.FOG_EXP2 &&
      AGALRenderer.FOG_EXP2 != AGALRenderer.FOG_NONE);

// Linear: smoothstep(near, far, depth) -- fog_fragment.glsl.js:4-13 runs
//   t = smoothstep(fogNear, fogFar, vFogDepth);  fogFactor = t;  when USE_FOG
check("C6 at near the linear factor is 0", near(AGALRenderer.fogFactorAt(1, 2, 42, 0, 2), 0));
check("C7 at far the linear factor is 1", near(AGALRenderer.fogFactorAt(1, 2, 42, 0, 42), 1));
check("C8 the linear midpoint is 0.5 (smoothstep symmetry)",
      near(AGALRenderer.fogFactorAt(1, 2, 42, 0, 22), 0.5));
check("C9 in front of near clamps to 0", near(AGALRenderer.fogFactorAt(1, 2, 42, 0, 0), 0));
check("C10 past far clamps to 1", near(AGALRenderer.fogFactorAt(1, 2, 42, 0, 400), 1));
// A quarter of the way: smoothstep(0.25) = 0.25^2 * (3 - 0.5) = 0.15625, i.e.
// NOT linear -- this is what distinguishes smoothstep from a plain lerp.
check("C11 a quarter of the way is smoothstep(0.25) = 0.15625",
      near(AGALRenderer.fogFactorAt(1, 0, 100, 0, 25), 0.15625));

// Exp2: 1 - exp(-density^2 * depth^2).
check("C12 exp2 at depth 0 is 0", near(AGALRenderer.fogFactorAt(2, 0, 1, 0.05, 0), 0));
check("C13 exp2 matches 1-exp(-(d*density)^2)",
      near(AGALRenderer.fogFactorAt(2, 0, 1, 0.05, 7), 1 - Math.exp(-(7 * 0.05) * (7 * 0.05)), 1e-12));
check("C14 exp2 is monotonic in depth",
      AGALRenderer.fogFactorAt(2, 0, 1, 0.05, 3) < AGALRenderer.fogFactorAt(2, 0, 1, 0.05, 9));
check("C15 exp2 stays in [0,1]",
      AGALRenderer.fogFactorAt(2, 0, 1, 0.05, 1e6) <= 1 &&
      AGALRenderer.fogFactorAt(2, 0, 1, 0.05, 1e6) >= 0);
check("C16 an unknown mode contributes nothing",
      near(AGALRenderer.fogFactorAt(7, 0, 10, 0.1, 5), 0));

// C17-C24: the CPU -> fc37..fc40 packing. The fragment program reads fc37.wwww
// as 1/(far-near) (a `sub` of two constants is illegal AGAL, see
// linearFogScale), so the upload MUST fill it; when it did not, fog was dead in
// BOTH runtimes with every other check in this file still green -- the mirror
// above and the shader are two separate arithmetics, so only the packing ties
// them together.
check("C17 linearFogScale is 1/(far-near)", near(AGALRenderer.linearFogScale(12, 30), 1 / 18, 1e-15));
check("C18 a degenerate span scales to 0 (no Infinity)",
      AGALRenderer.linearFogScale(5, 5) == 0);
check("C19 linearFogScale(NaN, x) degrades to 0",
      AGALRenderer.linearFogScale(Number.NaN, 30) == 0);
check("C20 fogFactorAt agrees with the shader's mul-by-scale form",
      near(AGALRenderer.fogFactorAt(1, 2, 42, 0, 22),
           0.5 * 0.5 * (3 - 1), 1e-12));

var fogPack:Vector.<Number> = new Vector.<Number>(16);
var camM:Vector.<Number> = new Vector.<Number>(16);
// identity rotation + translation (0,1,2): column 3 is the position, column 2
// the +Z axis.
camM[0] = 1; camM[5] = 1; camM[10] = 1; camM[15] = 1;
camM[12] = 0; camM[13] = 1; camM[14] = 2;
var packMode:int = AGALRenderer.packFogConstants(fogPack, lin, camM);
check("C21 packFogConstants reports the mode it packed", packMode == AGALRenderer.FOG_LINEAR);
check("C22 fc37 = (near, far, density, 1/(far-near))",
      fogPack[0] == 2 && fogPack[1] == 40 && fogPack[2] == 0 &&
      near(fogPack[3], 1 / 38, 1e-15));
check("C23 fc37.w is NOT zero for a linear fog (the silent-fog regression)", fogPack[3] != 0);
check("C24 fc38 = (cameraPos.xyz, 1) and fc39.w = 3",
      fogPack[4] == 0 && fogPack[5] == 1 && fogPack[6] == 2 && fogPack[7] == 1 &&
      fogPack[11] == 3);
var expPack:Vector.<Number> = new Vector.<Number>(16);
// fc37.w is the shader's base-change scale for FogExp2: AGAL's `exp` is base 2
// (measured on adl 51.4.1, temp/agalprobe/Exp.as), so the fragment program
// multiplies the exponent by log2(e) to reproduce three.js's natural exp.
check("C25 FogExp2 packs density and puts log2(e) in fc37.w",
      AGALRenderer.packFogConstants(expPack, exp, camM) == AGALRenderer.FOG_EXP2 &&
      near(expPack[2], 0.05) && near(expPack[3], Math.LOG2E, 1e-15));

// ---------------------------------------------------------------------------
// D. Fog / FogExp2 defaults (three.js r187)
// ---------------------------------------------------------------------------
var dLin:Fog = new Fog();
check("D1 Fog defaults to white", dLin.color.r == 1 && dLin.color.g == 1 && dLin.color.b == 1);
check("D2 Fog near defaults to 1", dLin.near == 1);
check("D3 Fog far defaults to 1000", dLin.far == 1000);
check("D4 Fog.isFog is set", dLin.isFog);

var dExp:FogExp2 = new FogExp2();
check("D5 FogExp2 density defaults to 0.00025", near(dExp.density, 0.00025));
check("D6 FogExp2.isFogExp2 is set", dExp.isFogExp2);

// Color.setHex decodes to the linear working space (D30), so an authored
// 0x808080 is NOT 0.5. The transfer is the exact piecewise sRGB curve from
// ColorManagement.js:186-194, not pow(2.2), so the reference is spelled out.
var c8080:Number = 0x80 / 255;
var lin8080:Number = Math.pow((c8080 + 0.055) / 1.055, 2.4);
var mid:Fog = new Fog(0x808080);
check("D7 the fog color is decoded to linear (D30), not stored as authored",
      near(mid.color.r, lin8080, 1e-9) && mid.color.r < 0.25);

// ---------------------------------------------------------------------------
// E. material / scene defaults
// ---------------------------------------------------------------------------
var basic:MeshBasicMaterial = new MeshBasicMaterial();
check("E1 Material.fog defaults to true (three.js Material.fog)", basic.fog);
check("E2 MeshBasicMaterial.map defaults to null", basic.map == null);

var std:MeshStandardMaterial = new MeshStandardMaterial();
check("E3 MeshStandardMaterial.fog defaults to true", std.fog);
std.fog = false;
check("E4 a material can opt out of fog", !std.fog);
std.fog = true;

var scene:Scene = new Scene();
check("E5 Scene.background defaults to null", scene.background == null);
check("E6 Scene.fog defaults to null", scene.fog == null);

// Scene.background accepts the three supported forms; the renderer dispatches
// with `is` so an unsupported type is a warning, never a crash.
scene.background = new Color(0x223344);
check("E7 a Color background is accepted", scene.background is Color);
scene.background = lin;
check("E8 an object that is neither Color nor Texture is still storable",
      scene.background is Fog);
check("E9 fogModeOf does not confuse a background with the scene fog",
      AGALRenderer.fogModeOf(scene.fog) == AGALRenderer.FOG_NONE);

if (failed == 0) trace("ALL PASS");
else trace("FAILED " + failed);