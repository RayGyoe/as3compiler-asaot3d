// asaot3d/probes/shadow-smoke-m13/ShadowSmokeM13.as -- M13 shadow-quality smoke.
//
// Pins the parts of the M13 contract that are observable WITHOUT a GPU:
//
//   A. DirectionalLightShadow gains three.js's LightShadow PCF knobs: radius
//      (LightShadow.js:44) and normalBias (LightShadow.js:45), while keeping the
//      M7 defaults (bias 0, mapSize 512, ortho camera -5..5). No `mapPass`/
//      `biasNode` -- this backend is not node-based (registered divergence).
//   B. Renderer caps: two directional lights per draw, ONE shadow map per draw.
//      The one-map cap is a sampler-budget fact (fs0-fs7 are all taken by the
//      standard material), recorded as D93 -- a second light is lit, never
//      shadowed.
//   C. The static PCF tap grid: 9 taps in a 3x3 neighbourhood, ±1 texel in each
//      axis, centred, packed (dx, dy, 0, 0) one register per tap. The grid and
//      the snippet that consumes it must agree, or the kernel silently collapses
//      into a point sample.
//   D. The PCF snippet actually assembles under the runtime's AGAL rules (which
//      reject read-before-write and unknown opcodes), fetches with `nearest`
//      (a bilinear tap between two stored depths would fabricate a depth that
//      never existed and bleed the shadow across a depth discontinuity), and
//      costs exactly 5 instructions per tap.
//   E. The kernel constants: radius 1 on a 512 map is one texel; the radius is
//      clamped to a quarter of the map; 0 means a single hard tap; and
//      1/PCF_TAPS is the averaging factor the snippet multiplies by.
//   F. Shadow-caster program selection: an alphaTest material with uvs renders
//      through the cutout variant so a leaf/quat casts a shaped shadow (D89).
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/shadow-smoke-m13/ShadowSmokeM13.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/shadow-smoke-m13 --run
import asaot.three.AGALRenderer;
import asaot.three.core.BufferGeometry;
import asaot.three.geometries.BoxGeometry;
import asaot.three.lights.DirectionalLight;
import asaot.three.lights.DirectionalLightShadow;
import asaot.three.materials.MeshBasicMaterial;

import com.adobe.utils.AGALMiniAssembler;
import flash.display3D.Context3DProgramType;
import flash.display3D.AGALTranslator;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-6):Boolean
{
    return Math.abs(a - b) < eps;
}

function countOf(src:String, needle:String):int
{
    var n:int = 0;
    var at:int = src.indexOf(needle);
    while (at >= 0)
    {
        n++;
        at = src.indexOf(needle, at + needle.length);
    }
    return n;
}

// ---------------------------------------------------------------------------
// A. DirectionalLightShadow: three.js LightShadow PCF knobs, M7 defaults kept.
// ---------------------------------------------------------------------------
var s:DirectionalLightShadow = new DirectionalLightShadow();
check("A1 radius default 1 (LightShadow.js:44)", near(s.radius, 1));
check("A2 normalBias default 0 (LightShadow.js:45)", near(s.normalBias, 0));
check("A3 bias default kept 0 (M7)", near(s.bias, 0));
check("A4 mapSize default kept 512 (M7)", near(s.mapSize.x, 512) && near(s.mapSize.y, 512));
check("A5 shadow camera kept ortho -5..5 (M7)", near(s.camera.left, -5) && near(s.camera.right, 5));
var tunable:DirectionalLightShadow = new DirectionalLightShadow();
tunable.radius = 3.5;
tunable.normalBias = 0.02;
check("A6 radius/normalBias are writable", near(tunable.radius, 3.5) && near(tunable.normalBias, 0.02));

// A directional light owns a shadow object whose knobs are the ones the renderer
// reads (DirectionalLight.js: the shadow is constructed, not passed in).
var dl:DirectionalLight = new DirectionalLight(0xffffff, 1);
check("A7 DirectionalLight.shadow carries radius", near(dl.shadow.radius, 1));
check("A8 DirectionalLight.shadow carries normalBias", near(dl.shadow.normalBias, 0));

// ---------------------------------------------------------------------------
// B. Renderer caps.
// ---------------------------------------------------------------------------
check("B1 MAX_DIR_LIGHTS == 2", AGALRenderer.MAX_DIR_LIGHTS == 2);
check("B2 MAX_SHADOW_LIGHTS == 1 (D93: sampler budget)", AGALRenderer.MAX_SHADOW_LIGHTS == 1);
check("B3 PCF_TAPS == 9 (3x3)", AGALRenderer.PCF_TAPS == 9);
check("B4 PCF offsets live at fc27 (fc27..fc35)", AGALRenderer.PCF_OFFSET_BASE == 27);

// castsShadow: opt-in on the light AND a shadow config present.
var lit:DirectionalLight = new DirectionalLight();
lit.castShadow = false;
check("B5 castShadow false -> no shadow", AGALRenderer.castsShadow(lit) == false);
lit.castShadow = true;
check("B6 castShadow true + shadow -> shadow", AGALRenderer.castsShadow(lit) == true);
lit.shadow = null;
check("B7 castShadow true, shadow null -> no shadow", AGALRenderer.castsShadow(lit) == false);

// ---------------------------------------------------------------------------
// C. The static 3x3 tap grid.
// ---------------------------------------------------------------------------
var off:Vector.<Number> = AGALRenderer.pcfOffsets();
check("C1 one register per tap", off.length == AGALRenderer.PCF_TAPS * 4);
var cx:int = 0;
var cy:int = 0;
var seen:String = "";
var okGrid:Boolean = true;
for (var i:int = 0; i < AGALRenderer.PCF_TAPS; i++)
{
    var dx:Number = off[i * 4];
    var dy:Number = off[i * 4 + 1];
    var dz:Number = off[i * 4 + 2];
    var dw:Number = off[i * 4 + 3];
    if ((dx != -1 && dx != 0 && dx != 1) || (dy != -1 && dy != 0 && dy != 1)) okGrid = false;
    if (dz != 0 || dw != 0) okGrid = false;
    if (dx == 0 && dy == 0) cx++;
    seen += int(dx) + "," + int(dy) + " ";
}
check("C2 every tap is an integer offset in {-1,0,1}", okGrid);
check("C3 exactly one centre tap", cx == 1);
check("C4 the nine cells are distinct",
      seen == "-1,-1 0,-1 1,-1 -1,0 0,0 1,0 -1,1 0,1 1,1 ");
// The same grid must be handed out as a fresh vector each call (the renderer
// uploads it once and later draws must not be able to corrupt it).
var off2:Vector.<Number> = AGALRenderer.pcfOffsets();
off2[0] = 99;
check("C5 pcfOffsets returns an independent copy", near(AGALRenderer.pcfOffsets()[0], -1));

// ---------------------------------------------------------------------------
// D. The PCF snippet: assembles, uses nearest taps, 6 instructions per tap.
// ---------------------------------------------------------------------------
// The snippet consumes 'c' (shadow coord -> factor in .w), 'm' (frustum mask),
// 'rv' (receiveShadow flag), 't' (texel), 'o' (offset scratch) and 'a'
// (accumulator). Feed it written registers so the only thing under test is the
// snippet itself.
var block:String = AGALRenderer.shadowFactorBlock('ft9', 'fc9', 'fc24', 'v5',
                                                 'ft9', 'ft10', 'ft13', 'ft11', 'ft12', 4);
check("D1 snippet has one tex per tap", countOf(block, "tex ") == AGALRenderer.PCF_TAPS);
check("D2 every tap samples fs4", countOf(block, "fs4") == AGALRenderer.PCF_TAPS);
check("D3 every tap is NEAREST (no depth interpolation)", countOf(block, "nearest") == AGALRenderer.PCF_TAPS);
check("D4 no linear tap slipped in", countOf(block, "linear") == 0);
check("D5 carries the kernel constant fc24", countOf(block, "fc24") == AGALRenderer.PCF_TAPS + 1);
check("D6 carries the bias constant fc9", countOf(block, "fc9") > 0);
check("D7 the factor is parked in c.w", block.indexOf("mov ft9.w, ft12.x") >= 0);
// M13 depth packing: every tap unpacks the two-digit depth before comparing.
check("D11 every tap unpacks the packed depth (dp3)", countOf(block, "dp3 ") == AGALRenderer.PCF_TAPS);
check("D12 unpack uses fc" + AGALRenderer.DEPTH_UNPACK_CONST,
      countOf(block, "fc" + AGALRenderer.DEPTH_UNPACK_CONST) == AGALRenderer.PCF_TAPS);
check("D13 the receiveShadow gate is in the block", countOf(block, "v5") == 1);

var lines:int = countOf(block, "\n");
check("D8 snippet is exactly 6 instructions per tap + 22 fixed (" + lines + ")",
      lines == AGALRenderer.PCF_TAPS * 6 + 22);

// Assemble it for real: the runtime rejects read-before-write and unknown
// opcodes, so a successful translate is the structural proof.
var prelude:String =
    'mov ft0, v0\n' +
    'mov v5, fc9.xxxx\n' +
    'mov ft9, v0\n' +
    'mov ft10, v0\n' +
    'mov ft11, v0\n' +
    'mov ft12, v0\n' +
    'mov ft13, v0\n';
var asm:AGALMiniAssembler = new AGALMiniAssembler();
asm.assemble(Context3DProgramType.FRAGMENT, prelude + block + "mov oc, ft0\n", 2);
var translated:Boolean = true;
var tmsg:String = "";
try
{
    AGALTranslator.translate(asm.agalcode, "msl");
}
catch (e:Error)
{
    translated = false;
    tmsg = e.message;
}
check("D9 snippet assembles + translates (" + tmsg + ")", translated);
var nInstr:int = (asm.agalcode.length - 7) / 24;
// +1: AGALMiniAssembler.hoistConstantOperands parks `fc24.xy` in a free
// temporary ONCE, so the nine `mul o.xy, fc24.xy, off.xy` taps become legal
// single-constant instructions instead of nine illegal two-constant ones (AIR
// rejects the raw form with #3625). Measured: 85.
check("D10 assembled program is 7 + taps*6 + 22 + 1, plus one hoisted constant move ("
      + nInstr + ")", nInstr == 7 + AGALRenderer.PCF_TAPS * 6 + 22 + 1 + 1);

// ---------------------------------------------------------------------------
// E. Kernel constants.
// ---------------------------------------------------------------------------
var k:Vector.<Number> = AGALRenderer.pcfKernel(1, 512, 512);
check("E1 radius 1 on 512 == one texel", near(k[0], 1 / 512) && near(k[1], 1 / 512));
check("E2 averaging factor is 1/9", near(k[2], 1 / 9));
check("E3 unused channel is 0", near(k[3], 0));
var k0:Vector.<Number> = AGALRenderer.pcfKernel(0, 512, 512);
check("E4 radius 0 collapses the kernel to a point sample", near(k0[0], 0) && near(k0[1], 0));
var kNeg:Vector.<Number> = AGALRenderer.pcfKernel(-2, 512, 512);
check("E5 negative radius clamps to 0", near(kNeg[0], 0));
var kBig:Vector.<Number> = AGALRenderer.pcfKernel(500, 256, 256);
check("E6 radius clamps to a quarter of the map", near(kBig[0], 64 / 256) && near(kBig[1], 64 / 256));
var kRect:Vector.<Number> = AGALRenderer.pcfKernel(4, 1024, 256);
check("E7 anisotropic map keeps x/y separate", near(kRect[0], 4 / 1024) && near(kRect[1], 4 / 256));
var kZero:Vector.<Number> = AGALRenderer.pcfKernel(2, 0, 0);
check("E8 zero-sized map cannot divide by zero", near(kZero[0], 0) && near(kZero[1], 0));

// ---------------------------------------------------------------------------
// F. Shadow-caster program selection (alphaTest cutout, D89).
// ---------------------------------------------------------------------------
var geo:BufferGeometry = new BoxGeometry(1, 1, 1);
check("F1 BoxGeometry has uvs", geo.getAttribute('uv') != null);
var opaque:MeshBasicMaterial = new MeshBasicMaterial();
check("F2 alphaTest 0 -> depth-only caster", AGALRenderer.shadowDepthKind(opaque, geo) == 0);
var cut:MeshBasicMaterial = new MeshBasicMaterial();
cut.alphaTest = 0.5;
check("F3 alphaTest > 0 + uvs -> cutout caster", AGALRenderer.shadowDepthKind(cut, geo) == 1);
var noUV:BufferGeometry = new BufferGeometry();
noUV.setAttribute('position', geo.getAttribute('position'));
check("F4 alphaTest > 0 but no uvs -> depth-only (nothing to sample)",
      AGALRenderer.shadowDepthKind(cut, noUV) == 0);
check("F5 null material -> depth-only", AGALRenderer.shadowDepthKind(null, geo) == 0);
check("F6 null geometry -> depth-only", AGALRenderer.shadowDepthKind(cut, null) == 0);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));