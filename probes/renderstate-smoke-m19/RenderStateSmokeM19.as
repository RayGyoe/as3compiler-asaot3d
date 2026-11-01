// asaot3d/probes/renderstate-smoke-m19/RenderStateSmokeM19.as -- M19 render-state smoke.
//
// Before M19 six state fields existed and nothing read them:
//
//   Material.side        renderer wrote setCulling('front') for every pass
//   Material.depthTest   setDepthTest was hard-coded per pass
//   Material.depthWrite  depth writing only followed `transparent`
//   Material.blending    the transparent pass hard-coded sourceAlpha/1-srcAlpha
//   Object3D.renderOrder only copied in Object3D.copy(), never sorted on
//   wireframe/flatShading  zero occurrences of either name in seam/
//
// M19 maps each field to the Stage3D call through one small static function per
// axis, and this probe pins those tables. It has to be static+pure to be pinned
// at all: the calls themselves need a Context3D and only show up as a picture
// (apps/renderstate-m19 is the picture).
//
//   A. cullingFor   -- side -> setCulling, including the CW/CCW inversion
//   B. shadowCullingFor -- the shadow pass's mapping (one documented divergence)
//   C. depthMaskFor / depthCompareFor -- the two halves of setDepthTest
//   D. blendSrcFor / blendDstFor -- five modes, legal Stage3D factor names
//   E. renderOrder  -- the two list comparison predicates
//   F. Material defaults -- three.js r187 values, so "unset" means the old look
//   G. flatNormalBlock -- the emitted 2-instruction face normal
//   H. wireframe    -- edge packing, color, width, which materials opt in
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/renderstate-smoke-m19/RenderStateSmokeM19.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/renderstate-smoke-m19 --run
import asaot.three.AGALRenderer;
import asaot.three.materials.Material;
import asaot.three.materials.MeshBasicMaterial;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.materials.LineBasicMaterial;
import asaot.three.math.Color;
import asaot.three.objects.Mesh;

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

// Number of non-overlapping occurrences of `needle` in `hay`.
function countOf(hay:String, needle:String):int
{
    var n:int = 0;
    var at:int = hay.indexOf(needle);
    while (at >= 0)
    {
        n++;
        at = hay.indexOf(needle, at + needle.length);
    }
    return n;
}

// The ten factor names Context3D.setBlendFactors accepts (AIR reference:
// Context3D.setBlendFactors). A typo here is a silent black screen, not an
// exception, so every emitted name is checked against this set.
var FACTORS:Array = ["zero", "one", "sourceAlpha", "oneMinusSourceAlpha",
                     "destinationAlpha", "oneMinusDestinationAlpha",
                     "sourceColor", "oneMinusSourceColor",
                     "destinationColor", "oneMinusDestinationColor"];

function isFactor(name:String):Boolean
{
    var i:int;
    for (i = 0; i < FACTORS.length; i++)
    {
        if (FACTORS[i] == name) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// A. side -> culling
// ---------------------------------------------------------------------------
// The backend declares front-facing = CW (Starling), three.js geometry winds
// CCW, so three.js FRONT faces are the backend's BACK faces. Culling three.js
// back faces (FrontSide) is therefore setCulling('front'), not 'back'.
check("A1 FrontSide culls the backend's front face (= three.js back faces)",
      AGALRenderer.cullingFor(Material.FrontSide) == "front");
check("A2 BackSide culls the backend's back face (= three.js front faces)",
      AGALRenderer.cullingFor(Material.BackSide) == "back");
check("A3 DoubleSide disables culling",
      AGALRenderer.cullingFor(Material.DoubleSide) == "none");
check("A4 an unknown side falls back to FrontSide",
      AGALRenderer.cullingFor(-7) == "front" && AGALRenderer.cullingFor(99) == "front");
check("A5 the three sides produce three distinct states",
      AGALRenderer.cullingFor(Material.FrontSide) != AGALRenderer.cullingFor(Material.BackSide) &&
      AGALRenderer.cullingFor(Material.BackSide) != AGALRenderer.cullingFor(Material.DoubleSide) &&
      AGALRenderer.cullingFor(Material.FrontSide) != AGALRenderer.cullingFor(Material.DoubleSide));
check("A6 every state is a legal setCulling argument",
      AGALRenderer.cullingFor(Material.FrontSide) == "front" ||
      AGALRenderer.cullingFor(Material.BackSide) == "back" ||
      AGALRenderer.cullingFor(Material.DoubleSide) == "none");

// ---------------------------------------------------------------------------
// B. side -> shadow-pass culling
// ---------------------------------------------------------------------------
// three.js flips FrontSide to BackSide for depth rendering so a closed caster
// records its far surface (WebGLShadowMap.js:51/486). This port keeps FrontSide
// on front faces: our verified cutout casters are single-sided plates, and
// rendering their back faces would cull every face and delete the shadow (R36).
check("B1 FrontSide casts with front faces (R36 divergence from three.js)",
      AGALRenderer.shadowCullingFor(Material.FrontSide) == "front");
check("B2 BackSide casts with front faces (matches three.js's flip)",
      AGALRenderer.shadowCullingFor(Material.BackSide) == "front");
check("B3 DoubleSide casts without culling",
      AGALRenderer.shadowCullingFor(Material.DoubleSide) == "none");

// ---------------------------------------------------------------------------
// C. depthTest / depthWrite -> setDepthTest(depthMask, compareMode)
// ---------------------------------------------------------------------------
// Stage3D's boolean is the WRITE mask and the string is the COMPARE mode, so
// "depth test off" needs both halves: no writes and compare 'always' (a GL
// depth buffer is also only updated while the test is enabled).
check("C1 test+write -> write on", AGALRenderer.depthMaskFor(true, true) == true);
check("C2 test without write -> write off", AGALRenderer.depthMaskFor(true, false) == false);
check("C3 test off suppresses writes even if depthWrite asks for them",
      AGALRenderer.depthMaskFor(false, true) == false);
check("C4 neither -> write off", AGALRenderer.depthMaskFor(false, false) == false);
check("C5 the default comparison is lessEqual", AGALRenderer.depthCompareFor(true) == "lessEqual");
check("C6 depthTest = false becomes compare 'always'", AGALRenderer.depthCompareFor(false) == "always");
check("C7 the two compare modes are distinct",
      AGALRenderer.depthCompareFor(true) != AGALRenderer.depthCompareFor(false));

// ---------------------------------------------------------------------------
// D. blending
// ---------------------------------------------------------------------------
check("D1 NormalBlending = (sourceAlpha, oneMinusSourceAlpha)",
      AGALRenderer.blendSrcFor(Material.NormalBlending) == "sourceAlpha" &&
      AGALRenderer.blendDstFor(Material.NormalBlending) == "oneMinusSourceAlpha");
check("D2 AdditiveBlending = (sourceAlpha, one)",
      AGALRenderer.blendSrcFor(Material.AdditiveBlending) == "sourceAlpha" &&
      AGALRenderer.blendDstFor(Material.AdditiveBlending) == "one");
check("D3 SubtractiveBlending = (zero, oneMinusSourceColor)",
      AGALRenderer.blendSrcFor(Material.SubtractiveBlending) == "zero" &&
      AGALRenderer.blendDstFor(Material.SubtractiveBlending) == "oneMinusSourceColor");
check("D4 MultiplyBlending = (zero, sourceColor)",
      AGALRenderer.blendSrcFor(Material.MultiplyBlending) == "zero" &&
      AGALRenderer.blendDstFor(Material.MultiplyBlending) == "sourceColor");
check("D5 NoBlending = (one, zero), i.e. replace",
      AGALRenderer.blendSrcFor(Material.NoBlending) == "one" &&
      AGALRenderer.blendDstFor(Material.NoBlending) == "zero");
check("D6 CustomBlending is reported as unimplemented (R35)",
      !AGALRenderer.blendingImplemented(Material.CustomBlending));
check("D7 the five standard modes are implemented",
      AGALRenderer.blendingImplemented(Material.NoBlending) &&
      AGALRenderer.blendingImplemented(Material.NormalBlending) &&
      AGALRenderer.blendingImplemented(Material.AdditiveBlending) &&
      AGALRenderer.blendingImplemented(Material.SubtractiveBlending) &&
      AGALRenderer.blendingImplemented(Material.MultiplyBlending));
check("D8 an out-of-range mode lands on the unimplemented path",
      !AGALRenderer.blendingImplemented(-3) && !AGALRenderer.blendingImplemented(42));

var modes:Array = [Material.NoBlending, Material.NormalBlending, Material.AdditiveBlending,
                   Material.SubtractiveBlending, Material.MultiplyBlending];
var allLegal:Boolean = true;
var mi:int;
for (mi = 0; mi < modes.length; mi++)
{
    if (!isFactor(AGALRenderer.blendSrcFor(modes[mi]))) allLegal = false;
    if (!isFactor(AGALRenderer.blendDstFor(modes[mi]))) allLegal = false;
}
check("D9 every emitted factor name is a legal setBlendFactors argument", allLegal);

// Numeric values must match three.js src/constants.js, because a scene ported
// from three.js may hard-code them.
check("D10 the blending constants match src/constants.js",
      Material.NoBlending == 0 && Material.NormalBlending == 1 &&
      Material.AdditiveBlending == 2 && Material.SubtractiveBlending == 3 &&
      Material.MultiplyBlending == 4 && Material.CustomBlending == 5);
check("D11 the side constants match src/constants.js",
      Material.FrontSide == 0 && Material.BackSide == 1 && Material.DoubleSide == 2);

// ---------------------------------------------------------------------------
// E. renderOrder
// ---------------------------------------------------------------------------
var red:Mesh = new Mesh(null, new MeshBasicMaterial());
var green:Mesh = new Mesh(null, new MeshBasicMaterial());

red.renderOrder = 1;
green.renderOrder = -1;
check("E1 the lower renderOrder is drawn first in the opaque list",
      AGALRenderer.opaqueOrderSwaps(red, green) && !AGALRenderer.opaqueOrderSwaps(green, red));
check("E2 renderOrderOf reads the field", AGALRenderer.renderOrderOf(red) == 1);

green.renderOrder = 1;
check("E3 equal renderOrder keeps the traversal order (stable sort)",
      !AGALRenderer.opaqueOrderSwaps(red, green) && !AGALRenderer.opaqueOrderSwaps(green, red));

// Transparent list: renderOrder first, then farthest-first.
green.renderOrder = -1;
check("E4 renderOrder outranks depth in the transparent list",
      AGALRenderer.transparentOrderSwaps(red, 100.0, green, 1.0) &&
      !AGALRenderer.transparentOrderSwaps(green, 1.0, red, 100.0));
green.renderOrder = 1;
check("E5 with equal renderOrder the FARTHER mesh is drawn first",
      AGALRenderer.transparentOrderSwaps(red, 1.0, green, 100.0) &&
      !AGALRenderer.transparentOrderSwaps(red, 100.0, green, 1.0));

// ---------------------------------------------------------------------------
// F. defaults (three.js r187) -- "unset" must mean the pre-M19 look
// ---------------------------------------------------------------------------
var std:MeshStandardMaterial = new MeshStandardMaterial();
check("F1 default side is FrontSide", std.side == Material.FrontSide);
check("F2 default blending is NormalBlending", std.blending == Material.NormalBlending);
check("F3 depthTest defaults to true", std.depthTest);
check("F4 depthWrite defaults to true", std.depthWrite);
check("F5 flatShading defaults to false", !std.flatShading);
check("F6 wireframe defaults to false and its width to 1px", !std.wireframe && std.wireframeLinewidth == 1);
var basic:MeshBasicMaterial = new MeshBasicMaterial();
check("F7 MeshBasicMaterial shares the same defaults",
      basic.side == Material.FrontSide && basic.blending == Material.NormalBlending &&
      basic.depthTest && basic.depthWrite && !basic.wireframe && basic.wireframeLinewidth == 1);

// ---------------------------------------------------------------------------
// G. flatShading's emitted block
// ---------------------------------------------------------------------------
var flatBlock:String = AGALRenderer.flatNormalBlock();
check("G1 flatNormalBlock is not null (AS3 return-ASI trap, same as M18)", flatBlock != null);
if (flatBlock == null) flatBlock = "";
var flatLines:Array = flatBlock.split("\n");
var flatCount:int = 0;
var fi:int;
for (fi = 0; fi < flatLines.length; fi++)
{
    if (flatLines[fi].length > 0) flatCount++;
}
check("G2 exactly two instructions", flatCount == 2);
check("G3 cross of the position derivatives, then normalize",
      flatBlock.indexOf("crs ft0.xyz, ft4.xyz, ft5.xyz") >= 0 &&
      flatBlock.indexOf("nrm ft0.xyz, ft0.xyz") >= 0);
check("G4 it writes ft0, the register the lighting reads as N",
      countOf(flatBlock, "ft0") == 3);
check("G5 no stray null/empty line slipped in", flatBlock.indexOf("null") < 0);
check("G6 flatShadingOf only answers true for MeshStandardMaterial",
      !AGALRenderer.flatShadingOf(basic));

// ---------------------------------------------------------------------------
// H. wireframe
// ---------------------------------------------------------------------------
check("H1 wireframe is opt-in per material",
      !AGALRenderer.wantsWireframe(std) && !AGALRenderer.wantsWireframe(basic));
std.wireframe = true;
check("H2 MeshStandardMaterial.wireframe opts in", AGALRenderer.wantsWireframe(std));
basic.wireframe = true;
check("H3 MeshBasicMaterial.wireframe opts in", AGALRenderer.wantsWireframe(basic));
check("H4 LineBasicMaterial has no wireframe flag",
      !AGALRenderer.wantsWireframe(new LineBasicMaterial()));

check("H5 half width is linewidth/2", near(AGALRenderer.wireframeHalfWidth(basic), 0.5));
basic.wireframeLinewidth = 3;
check("H6 a wider line widens the quad", near(AGALRenderer.wireframeHalfWidth(basic), 1.5));
basic.wireframeLinewidth = 0;
check("H7 a non-positive width falls back to 1px", near(AGALRenderer.wireframeHalfWidth(basic), 0.5));

var redColor:Color = new Color(0xff0000);
basic.wireframeLinewidth = 1;
basic.color = redColor;
check("H8 the edge color is the material color",
      AGALRenderer.wireframeColorOf(basic) == redColor);

// Edge packing: one edge -> 4 vertices (a,a,b,b), other endpoint (b,b,a,a),
// sides (-1,+1,+1,-1) and two triangles (0,1,2)(1,3,2) relative to the base.
var p:Vector.<Number> = new Vector.<Number>();
p.push(1, 2, 3);     // vertex 0
p.push(4, 5, 6);     // vertex 1
var pos:Vector.<Number> = new Vector.<Number>(12);
var other:Vector.<Number> = new Vector.<Number>(12);
var side:Vector.<Number> = new Vector.<Number>(4);
var idx:Vector.<uint> = new Vector.<uint>(6);
var next:int = AGALRenderer.wireEdgeInto(pos, other, side, idx, 0, p, 0, 1);

check("H9 the edge consumes index 1", next == 1);
check("H10 positions are [a, a, b, b]",
      pos[0] == 1 && pos[1] == 2 && pos[2] == 3 &&
      pos[3] == 1 && pos[4] == 2 && pos[5] == 3 &&
      pos[6] == 4 && pos[7] == 5 && pos[8] == 6 &&
      pos[9] == 4 && pos[10] == 5 && pos[11] == 6);
check("H11 the other endpoint is [b, b, a, a]",
      other[0] == 4 && other[1] == 5 && other[2] == 6 &&
      other[3] == 4 && other[4] == 5 && other[5] == 6 &&
      other[6] == 1 && other[7] == 2 && other[8] == 3 &&
      other[9] == 1 && other[10] == 2 && other[11] == 3);
check("H12 sides are (-1, +1, +1, -1) -- the end pair is pre-negated",
      side[0] == -1 && side[1] == 1 && side[2] == 1 && side[3] == -1);
check("H13 the two triangles are (0,1,2) and (1,3,2)",
      idx[0] == 0 && idx[1] == 1 && idx[2] == 2 &&
      idx[3] == 1 && idx[4] == 3 && idx[5] == 2);

var pos2:Vector.<Number> = new Vector.<Number>(24);
var other2:Vector.<Number> = new Vector.<Number>(24);
var side2:Vector.<Number> = new Vector.<Number>(8);
var idx2:Vector.<uint> = new Vector.<uint>(12);
var back:int = AGALRenderer.wireEdgeInto(pos2, other2, side2, idx2, 1, p, 0, 1);
check("H14 a second edge lands at base vertex 4 and index slot 6",
      back == 2 && pos2[12] == 1 && side2[4] == -1 && idx2[6] == 4 && idx2[11] == 6);

trace(failed == 0 ? "ALL PASS" : ("FAILED " + failed));