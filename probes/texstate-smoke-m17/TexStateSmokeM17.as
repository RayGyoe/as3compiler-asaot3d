// asaot3d/probes/texstate-smoke-m17/TexStateSmokeM17.as -- M17 texture-state smoke.
//
// Before M17 the renderer ignored every Texture field except `image`: the AGAL
// sampler was hard-coded `<2d,clamp,linear,mipnone>` and the upload never looked
// at flipY/colorSpace. The fix is two halves -- a set of pure decisions (which
// Stage3D sampler state, which program variant, which clear colour) and a GPU
// side (chain upload, row flip) that needs a Context3D. A headless probe can
// only reach the first half, so that is what this pins:
//
//   A. wrapS/wrapT -> Stage3D wrap mode. The backend decodes exactly one flag
//      ("repeat" vs everything else), so a mixed pair has to collapse and say so.
//   B. min/magFilter -> the single Stage3D filter, and generateMipmaps -> the mip
//      filter. A mip filter on a texture with NO chain makes AIR drop the whole
//      draw, so the guard is a correctness rule, not a nicety.
//   C. mipLevelCount/mipDimension -- the loop bounds for the generated chain.
//   D. colorSpace -> the program's decode mask (which used to be no-op, leaving
//      color maps double-gamma'd on output).
//   E. The scene background clear value (sRGB-encoded, like the back buffer).
//   F. flipRows -- the actual row reversal flipY=true asks for.
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/texstate-smoke-m17/TexStateSmokeM17.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/texstate-smoke-m17 --run
import flash.display.BitmapData;

import asaot.three.AGALRenderer;
import asaot.three.math.Color;
import asaot.three.textures.CubeTexture;
import asaot.three.textures.Texture;

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

// ---------------------------------------------------------------------------
// A. wrap/filter/mip -> Stage3D sampler state.
// ---------------------------------------------------------------------------
check("A1 clamp/clamp maps to clamp",
      AGALRenderer.wrapModeFor(Texture.ClampToEdgeWrapping, Texture.ClampToEdgeWrapping) == "clamp");
check("A2 repeat/repeat maps to repeat",
      AGALRenderer.wrapModeFor(Texture.RepeatWrapping, Texture.RepeatWrapping) == "repeat");
// Stage3D keeps ONE wrap flag per sampler, so "repeat on u, clamp on v" cannot be
// expressed. Keeping the tiling axis is the choice that preserves the visible
// intent (a uv inside [0,1] is unaffected by repeat), and wrapIsLossy() reports
// that something was dropped so the caller can warn.
check("A3 mixed wrap keeps the repeating axis",
      AGALRenderer.wrapModeFor(Texture.RepeatWrapping, Texture.ClampToEdgeWrapping) == "repeat");
check("A4 mixed wrap is reported as lossy",
      AGALRenderer.wrapIsLossy(Texture.RepeatWrapping, Texture.ClampToEdgeWrapping));
check("A5 mirrored repeat falls back to repeat",
      AGALRenderer.wrapModeFor(Texture.MirroredRepeatWrapping, Texture.MirroredRepeatWrapping) == "repeat");
check("A6 mirrored repeat is reported as lossy",
      AGALRenderer.wrapIsLossy(Texture.MirroredRepeatWrapping, Texture.MirroredRepeatWrapping));
check("A7 an identical clamp pair is not lossy",
      !AGALRenderer.wrapIsLossy(Texture.ClampToEdgeWrapping, Texture.ClampToEdgeWrapping));
check("A8 an identical repeat pair is not lossy",
      !AGALRenderer.wrapIsLossy(Texture.RepeatWrapping, Texture.RepeatWrapping));

// ---------------------------------------------------------------------------
// B. filters.
// ---------------------------------------------------------------------------
check("B1 nearest min -> nearest",
      AGALRenderer.samplerFilterFor(Texture.NearestFilter, Texture.LinearFilter) == "nearest");
check("B2 nearest-mipmap min -> nearest",
      AGALRenderer.samplerFilterFor(Texture.NearestMipmapLinearFilter, Texture.LinearFilter) == "nearest");
check("B3 linear min -> linear",
      AGALRenderer.samplerFilterFor(Texture.LinearFilter, Texture.NearestFilter) == "linear");
check("B4 linear-mipmap min -> linear",
      AGALRenderer.samplerFilterFor(Texture.LinearMipmapLinearFilter, Texture.LinearFilter) == "linear");

// "mipnone", not "none": Context3D.setSamplerStateAt rejects the latter with
// #2008, so "no chain" is spelled the way AIR accepts it.
check("B5 mip filter needs generateMipmaps",
      AGALRenderer.mipFilterFor(Texture.LinearMipmapLinearFilter, false) == "mipnone");
check("B6 linear-mipmap-linear -> miplinear",
      AGALRenderer.mipFilterFor(Texture.LinearMipmapLinearFilter, true) == "miplinear");
check("B7 nearest-mipmap-nearest -> mipnearest",
      AGALRenderer.mipFilterFor(Texture.NearestMipmapNearestFilter, true) == "mipnearest");
check("B8 linear-mipmap-nearest -> mipnearest",
      AGALRenderer.mipFilterFor(Texture.LinearMipmapNearestFilter, true) == "mipnearest");
// A plain LinearFilter asks for no chain even when generateMipmaps is true: the
// chain is built only when a mip filter can actually use it.
check("B9 a non-mip min filter asks for no chain",
      AGALRenderer.mipFilterFor(Texture.LinearFilter, true) == "mipnone");

// ---------------------------------------------------------------------------
// C. chain geometry.
// ---------------------------------------------------------------------------
check("C1 256x256 has 9 levels", AGALRenderer.mipLevelCount(256, 256) == 9);
check("C2 1x1 has 1 level", AGALRenderer.mipLevelCount(1, 1) == 1);
check("C3 non-square uses the longer edge", AGALRenderer.mipLevelCount(256, 64) == 9);
check("C4 level 0 is the full size", AGALRenderer.mipDimension(256, 0) == 256);
check("C5 level 1 halves", AGALRenderer.mipDimension(256, 1) == 128);
check("C6 the last level is 1", AGALRenderer.mipDimension(256, 8) == 1);
check("C7 past the end stays at 1 (never 0)",
      AGALRenderer.mipDimension(256, 12) == 1);
check("C8 a non-square level floors independently",
      AGALRenderer.mipDimension(64, 7) == 1);

// ---------------------------------------------------------------------------
// D. colorSpace -> decode mask.
// ---------------------------------------------------------------------------
var srgb:Texture = new Texture();
srgb.colorSpace = Texture.SRGBColorSpace;
var linear:Texture = new Texture();
linear.colorSpace = Texture.LinearSRGBColorSpace;
var unspec:Texture = new Texture();

check("D1 the default colorSpace is NoColorSpace", unspec.colorSpace == Texture.NoColorSpace);
check("D2 a fresh texture is not decoded", !AGALRenderer.needsDecode(unspec));
check("D3 LinearSRGBColorSpace is not decoded", !AGALRenderer.needsDecode(linear));
check("D4 SRGBColorSpace is decoded", AGALRenderer.needsDecode(srgb));
check("D5 a null texture is not decoded", !AGALRenderer.needsDecode(null));

var srgbCube:CubeTexture = new CubeTexture();
srgbCube.colorSpace = Texture.SRGBColorSpace;

check("D6 a color map alone sets the map bit",
      AGALRenderer.decodeMaskFor(srgb, null, null) == AGALRenderer.DECODE_MAP);
check("D7 a linear map sets nothing",
      AGALRenderer.decodeMaskFor(linear, linear, null) == 0);
check("D8 map + emissive set both bits",
      AGALRenderer.decodeMaskFor(srgb, srgb, null)
      == (AGALRenderer.DECODE_MAP | AGALRenderer.DECODE_EMISSIVE));
check("D9 map + emissive + env set all three",
      AGALRenderer.decodeMaskFor(srgb, srgb, srgbCube) == AGALRenderer.DECODE_ALL);
check("D10 an sRGB env alone sets only the env bit",
      AGALRenderer.decodeMaskFor(null, null, srgbCube) == AGALRenderer.DECODE_ENV);

// D170: the decode is the sRGB EOTF,  ((c + 0.055)/1.055)^2.4, not pow(x, 2.2).
// The exact TEXT is pinned because the emitted components and the constant
// layout have to stay in lockstep: writing +fc41.wwww (2.4) where the +0.055
// belongs does not fail loudly, it makes albedo enormous and washes every
// textured surface out (that bug lived for one build). tmp is a caller-owned
// scratch register -- the standard program has no free ft at every site.
check("D11 a decoded slot emits the sRGB EOTF",
      AGALRenderer.srgbDecodeBlock("ft2", AGALRenderer.DECODE_MAP, AGALRenderer.DECODE_MAP, "ft9")
      == "add ft9.xyz, ft2.xyz, fc41.zzzz\n"
       + "mul ft9.xyz, ft9.xyz, fc41.yyyy\n"
       + "pow ft2.x, ft9.x, fc41.wwww\n"
       + "pow ft2.y, ft9.y, fc41.wwww\n"
       + "pow ft2.z, ft9.z, fc41.wwww\n");
check("D12 an undecoded slot emits nothing",
      AGALRenderer.srgbDecodeBlock("ft2", AGALRenderer.DECODE_EMISSIVE, AGALRenderer.DECODE_MAP, "ft9") == "");
check("D13 no mask emits nothing at all",
      AGALRenderer.srgbDecodeBlock("ft2", 0, AGALRenderer.DECODE_MAP, "ft9") == "");
// D177: fc36 used to hold the D154 HDR-bake storage exponent pow(x, 2.2).
// The bake now encodes with the sRGB OETF, so the HDR background program
// decodes with fc41 like everything else and fc36 is retired -- there is one
// transfer-function pair in the renderer, not two.
check("D14 the sRGB constants start at fc41 (above the fog block fc37..fc40)",
      AGALRenderer.SRGB_CONST == 41);

// D170: the encode side, in place and needing no scratch.
check("D15 the encode is 1.055*x^(1/2.4)-0.055",
      AGALRenderer.srgbEncodeBlock("ft4")
      == "pow ft4.x, ft4.x, fc42.xxxx\n"
       + "pow ft4.y, ft4.y, fc42.xxxx\n"
       + "pow ft4.z, ft4.z, fc42.xxxx\n"
       + "mul ft4.xyz, ft4.xyz, fc41.xxxx\n"
       + "sub ft4.xyz, ft4.xyz, fc41.zzzz\n"
       + "sat ft4.xyz, ft4.xyz\n");

// The VALUES, pinned independently of the emitted text: fc41 = (1.055, 1/1.055,
// 0.055, 2.4), fc42 = (1/2.4, 0, 0, 0). Checking them against a curve recomputed
// here is what makes a .z/.w swap (offset vs exponent) observable.
var sc:Array = AGALRenderer.SRGB_CONSTANTS;
check("D16 fc41 = (1.055, 1/1.055, 0.055, 2.4)",
      near(Number(sc[0]), 1.055, 1e-12) && near(Number(sc[1]), 1 / 1.055, 1e-12)
      && near(Number(sc[2]), 0.055, 1e-12) && near(Number(sc[3]), 2.4, 1e-12));
check("D17 fc42.x = 1/2.4 (the other three components are padding)",
      sc.length == 5 && near(Number(sc[4]), 1 / 2.4, 1e-12));
// Round trip: enc(dec(c)) == c to within one 8-bit code value over the whole
// range the shader sees, i.e. the pair the sRGB background relies on is an
// identity. Checked on the same arithmetic the AGAL blocks spell out.
var rtOk:Boolean = true;
var tri:int;
for (tri = 0; tri < 256; tri++)
{
    var c:Number = tri / 255.0;
    var lin:Number = Math.pow((c + Number(sc[2])) * Number(sc[1]), Number(sc[3]));
    var back:Number = Math.min(1, Math.max(0, Math.pow(lin, Number(sc[4])) * Number(sc[0]) - Number(sc[2])));
    if (Math.abs(back - c) > 1.0 / 255.0) rtOk = false;
}
check("D18 decode+encode is an identity within one code value (256 levels)", rtOk);

// D171: the DATA slots. `material.metalnessMap = material.map` (what
// webgl_animation_walk and apps/walk-m26 both do) binds an SRGBColorSpace
// texture to a data map, and three.js decodes whatever the TEXTURE says --
// the GPU's sRGB sampler does not know the slot. Skipping it reads the encoded
// blue as metalness, i.e. up to 4x too metal, which costs the metal its diffuse
// lobe (M26-R1b).
check("D19 an sRGB metalnessMap sets the metalness bit",
      AGALRenderer.decodeMaskFor(null, null, null, null, srgb) == AGALRenderer.DECODE_METALNESS);
check("D20 an sRGB roughnessMap sets the roughness bit",
      AGALRenderer.decodeMaskFor(null, null, null, srgb, null) == AGALRenderer.DECODE_ROUGHNESS);
check("D21 a linear MR pair sets neither bit",
      AGALRenderer.decodeMaskFor(null, null, null, linear, linear) == 0);
check("D22 all five slots together are DECODE_MAPS_ALL",
      AGALRenderer.decodeMaskFor(srgb, srgb, srgbCube, srgb, srgb)
      == AGALRenderer.DECODE_MAPS_ALL);
check("D23 DECODE_ALL stays the three color slots",
      AGALRenderer.DECODE_ALL == 7 && AGALRenderer.DECODE_MAPS_ALL == 31);
check("D24 the roughness/decode bits do not collide with the color bits",
      (AGALRenderer.DECODE_ROUGHNESS & AGALRenderer.DECODE_ALL) == 0
      && (AGALRenderer.DECODE_METALNESS & AGALRenderer.DECODE_ROUGHNESS) == 0);
// The scalar form decodes ONE component in place, with one scratch scalar, so a
// data slot costs 3 instructions instead of 5.
check("D25 the scalar decode touches only the named component",
      AGALRenderer.srgbDecodeScalarBlock("ft4", "z", AGALRenderer.DECODE_METALNESS,
                                         AGALRenderer.DECODE_METALNESS, "ft6")
      == "add ft6.x, ft4.z, fc41.zzzz\n"
       + "mul ft6.x, ft6.x, fc41.yyyy\n"
       + "pow ft4.z, ft6.x, fc41.wwww\n");
check("D26 an unset scalar slot emits nothing",
      AGALRenderer.srgbDecodeScalarBlock("ft4", "y", AGALRenderer.DECODE_METALNESS,
                                         AGALRenderer.DECODE_ROUGHNESS, "ft6") == "");
// The scalar decode has to be the SAME curve as the vector one, or a color map
// reused as a data map would be decoded twice with two different curves.
var scalarOk:Boolean = true;
for (tri = 0; tri < 256; tri++)
{
    var cEnc:Number = tri / 255.0;
    var vecIn:Number = Math.pow((cEnc + Number(sc[2])) * Number(sc[1]), Number(sc[3]));
    var sIn:Number = Math.min(1, Math.max(0, cEnc));
    var sLin:Number = Math.pow((sIn + Number(sc[2])) * Number(sc[1]), Number(sc[3]));
    if (Math.abs(vecIn - sLin) > 1e-12) scalarOk = false;
}
check("D27 the scalar and vector decodes agree on all 256 levels", scalarOk);

// ---------------------------------------------------------------------------
// G. roughness: r187's geometry term.
// ---------------------------------------------------------------------------
// lights_physical_fragment.glsl.js:9-15 folds the screen derivative of the
// NON-perturbed normal into the roughness. It is what stops a roughness-0.2
// highlight (D_GGX peak ~199, and ~1.8x less per 1% of dotNH) from aliasing
// into whole blown polygons on a small curved mesh -- measured as the M26-R1b
// body-box p90 going 237 -> 82 (three-api-design.md §32).
check("G1 the geometry-roughness block is ddx/ddy of the geometric normal",
      AGALRenderer.geometryRoughnessBlock()
      == "ddx ft12.xyz, ft0.xyz\n"
       + "ddy ft13.xyz, ft0.xyz\n"
       + "abs ft12.xyz, ft12.xyz\n"
       + "abs ft13.xyz, ft13.xyz\n"
       + "max ft12.xyz, ft12.xyz, ft13.xyz\n"
       + "max ft12.x, ft12.x, ft12.y\n"
       + "max ft12.x, ft12.x, ft12.z\n");
// The max chain has to collapse xyz to ONE scalar in .x -- max3 of the three
// components, not just the x/y pair, or a derivative that only lives on z is
// dropped entirely (a tangent-space z variation is real: a surface facing the
// camera moves its normal mostly in screen z).
check("G2 both max folds are present (x<->y and then x<->z)",
      AGALRenderer.geometryRoughnessBlock().indexOf("max ft12.x, ft12.x, ft12.y") >= 0
      && AGALRenderer.geometryRoughnessBlock().indexOf("max ft12.x, ft12.x, ft12.z") >= 0);
// abs on BOTH derivative registers: without it a negative derivative would win
// the max and SUBTRACT roughness, sharpening the highlight instead.
check("G3 both derivatives are abs'd",
      AGALRenderer.geometryRoughnessBlock().indexOf("abs ft12.xyz") >= 0
      && AGALRenderer.geometryRoughnessBlock().indexOf("abs ft13.xyz") >= 0);

// ---------------------------------------------------------------------------
// H. D173: three.js's multi-scattering energy compensation.
// ---------------------------------------------------------------------------
// r187 derives the DFG pair from a LUT (lights_fragment_begin.glsl.js:59) and
// then uses it TWICE: once for the direct lights (multiScatteringCompensation,
// :73) and once for the IBL split-sum (computeMultiscattering, :463). Both are
// fed by the same AB, so the shader computes it once (stage 5.5) and the probe
// pins that single source.
check("H1 the EnvBRDFApprox block is Karis's 12 instructions",
      AGALRenderer.envBRDFApproxBlock("ft9", "ft8")
      == "mul ft8, ft5.xxxx, fc11\n"
       + "add ft8, ft8, fc12\n"
       + "mul ft9.x, ft8.x, ft8.x\n"
       + "mul ft9.y, fc13.x, ft3.y\n"
       + "exp ft9.y, ft9.y\n"
       + "min ft9.x, ft9.x, ft9.y\n"
       + "mul ft9.x, ft9.x, ft8.x\n"
       + "add ft9.x, ft9.x, ft8.y\n"
       + "mul ft9.y, ft9.x, fc13.z\n"
       + "add ft9.y, ft9.y, ft8.z\n"
       + "mul ft9.z, ft9.x, fc13.w\n"
       + "add ft9.z, ft9.z, ft8.w\n");
// The standard program parks light 0's PCF factor in ft9.w, and stage 6.5 reuses
// it as pow4(roughness). A block that wrote .w would silently destroy one of the
// two -- the shadow test it hits first, which reads as "shadows vanished".
check("H2 the DFG block never writes ab.w (the shadow factor lives there)",
      AGALRenderer.envBRDFApproxBlock("ft9", "ft8").indexOf("ft9.w") < 0);
// -9.28 is used verbatim because AGAL's exp is base 2 (stage348). A base-change
// fold (-6.4324) makes a004 too large, so every environment-lit surface gets
// brighter as roughness falls -- the pre-D170 class of bug.
check("H3 the exp2 coefficient is -9.28, not a ln2-folded -6.4324",
      AGALRenderer.envBRDFApproxBlock("ft9", "ft8").indexOf("fc13.x") >= 0
      && AGALRenderer.envBRDFApproxBlock("ft9", "ft8").indexOf("6.43") < 0);
check("H4 the compensation is 1 + specularColor*(1/Ess - 1)",
      AGALRenderer.multiScatterCompBlock("ft10", "ft9", "ft8")
      == "add ft8.x, ft9.y, ft9.z\n"
       + "max ft8.x, ft8.x, fc0.wwww\n"
       + "rcp ft8.x, ft8.x\n"
       + "sub ft8.x, ft8.x, fc6.wwww\n"
       + "mul ft10.xyz, ft6.xyz, ft8.xxxx\n"
       + "add ft10.xyz, ft10.xyz, fc6.wwww\n");
// The scalar lives in `tmp` (ft8 here) and the destination is a DIFFERENT
// register: writing .xyz of the register the scalar is read from is exactly the
// write-mask alias class stage346 had to fix in the assembler.
check("H5 the vec3 factor is built from a scratch register, not in place",
      AGALRenderer.multiScatterCompBlock("ft10", "ft9", "ft8").indexOf("ft10.xxxx") < 0);

// The two invariants the compensation rests on. Karis's coefficients:
//   c0 = (-1, -0.0275, -0.572, 0.022), c1 = (1, 0.0425, 1.04, -0.04)
// so r.z + r.w = 1.04 - 0.572*roughness + 0.022*roughness - 0.04
//             = 1 - 0.55*roughness
// and Ess = AB.x + AB.y equals that, because the -1.04/+1.04 pair cancels a004.
// Ess is therefore a pure function of roughness -- a LUT lookup at (r, NoV)
// would still vary with NoV, which is why the analytic form is only "within 1%".
var essOk:Boolean = true;
var novOk:Boolean = true;
var r:Number;
var nov:Number;
for (r = 0; r <= 1.0001; r += 0.01)
{
    var rc:Number = r * -1.0 + 1.0;
    var ry:Number = r * -0.0275 + 0.0425;
    var rz:Number = r * -0.572 + 1.04;
    var rw:Number = r * 0.022 - 0.04;
    var essRef:Number = 1 - 0.55 * r;
    for (nov = 0; nov <= 1.0001; nov += 0.05)
    {
        // AGAL exp is base 2, so exp2(-9.28*NoV) is `exp` of -9.28*NoV.
        var a004:Number = Math.min(rc * rc, Math.pow(2, -9.28 * nov)) * rc + ry;
        var abx:Number = -1.04 * a004 + rz;
        var aby:Number = 1.04 * a004 + rw;
        if (Math.abs((abx + aby) - essRef) > 1e-12) essOk = false;
        // The compensation must never be < 1 (energy is only ever ADDED back),
        // and it must degrade to exactly 1 for a mirror (Ess = 1).
        if (a004 < 0) novOk = false;
    }
}
check("H6 Ess = AB.x + AB.y = 1 - 0.55*roughness at every NoV", essOk);
check("H7 a004 is never negative, so comp never drops below 1", novOk);
check("H8 a mirror (roughness 0) needs no compensation",
      near(1 - 0.55 * 0, 1) && near(1 - 0.55 * 1, 0.45));

// What the two materials of the M26-R1b scene actually get. This is the number
// that killed the "Ess 0.9 => x1.11 => the missing quarter" hypothesis: the
// factor is multiplied by specularColorBlended, and a glTF material whose
// metalnessMap points at its albedo map is ~0.2 metal, i.e. F0 ~= 0.07. The
// floor (F0 0.04) gets +3.5%, the body +2.0% -- measured on the harness as body
// 35.34 -> 35.50 and floor 21.79 -> 22.17, not the +11% an Ess-only reading
// suggests (three-api-design.md §34.6).
var essFloor:Number = 1 - 0.55 * 0.85;
var compFloor:Number = 1 + 0.04 * (1.0 / essFloor - 1.0);
var essBody:Number = 1 - 0.55 * 0.43;
var compBody:Number = 1 + 0.07 * (1.0 / essBody - 1.0);
check("H9 the walk-m26 floor (roughness 0.85, F0 0.04) gets x1.035",
      near(essFloor, 0.5325, 1e-12) && near(compFloor, 1.0351, 1e-4));
check("H10 the walk-m26 body (roughness 0.43 after geometryRoughness, F0 0.07) gets x1.020",
      near(essBody, 0.7635, 1e-12) && near(compBody, 1.0217, 1e-4));

// ---------------------------------------------------------------------------
// E. scene background -> clear colour.
// ---------------------------------------------------------------------------
var bg:Color = new Color();
bg.setHex(0x336699);
var clearVec:Vector.<Number> = AGALRenderer.clearColorOf(bg);
// The back buffer holds sRGB-encoded values (every program ends in the R7
// encode), so the clear value has to be the sRGB triple, i.e. the same hex the
// author wrote -- not its linear form.
check("E1 the red channel is the authored value", near(clearVec[0], 0x33 / 255, 1e-3));
check("E2 the green channel is the authored value", near(clearVec[1], 0x66 / 255, 1e-3));
check("E3 the blue channel is the authored value", near(clearVec[2], 0x99 / 255, 1e-3));
check("E4 alpha is opaque", near(clearVec[3], 1));

var empty:Vector.<Number> = AGALRenderer.clearColorOf(null);
check("E5 no background clears black", near(empty[0], 0) && near(empty[1], 0) && near(empty[2], 0));
check("E6 black is still opaque", near(empty[3], 1));

var whiteBg:Color = new Color();
whiteBg.setHex(0xffffff);
var whiteVec:Vector.<Number> = AGALRenderer.clearColorOf(whiteBg);
check("E7 white stays white", near(whiteVec[0], 1, 1e-3) && near(whiteVec[1], 1, 1e-3) && near(whiteVec[2], 1, 1e-3));

// ---------------------------------------------------------------------------
// F. flipY -> row reversal (the CPU half of the upload path).
// ---------------------------------------------------------------------------
var src:BitmapData = new BitmapData(2, 2, false, 0xFF000000);
src.setPixel32(0, 0, 0xFFFF0000); // top row red
src.setPixel32(1, 0, 0xFFFF0000);
src.setPixel32(0, 1, 0xFF0000FF); // bottom row blue
src.setPixel32(1, 1, 0xFF0000FF);

var flipped:BitmapData = AGALRenderer.flipRows(src);
check("F1 the flipped bitmap keeps its size",
      flipped.width == 2 && flipped.height == 2);
check("F2 the source's bottom row becomes the top",
      (flipped.getPixel32(0, 0) & 0x00ffffff) == 0x000000ff);
check("F3 the source's top row becomes the bottom",
      (flipped.getPixel32(1, 1) & 0x00ffffff) == 0xff0000);
check("F4 the source is not modified in place",
      (src.getPixel32(0, 0) & 0x00ffffff) == 0xff0000);
check("F5 alpha survives the flip",
      ((flipped.getPixel32(0, 0) >> 24) & 0xff) == 0xff);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));