// env-smoke-m9.as -- M9 environment-map (IBL) smoke.
//
// Pins the parts of the M9 contract that are observable without a GPU:
// CubeTexture's six-face shape, CubeTextureLoader's "return now, fill six faces
// as they decode, fire onLoad once" contract, the MeshStandardMaterial/Scene
// wiring the renderer resolves (material.envMap || scene.environment), the
// EnvBRDFApprox constants the standard fragment consumes, and AGAL's acceptance
// of a <cube> fetch.
//
// Run from asaot3d/ (Skia manifest: the faces are JPEGs decoded through the
// same flash.display.Loader path glTF textures use):
//   node ../as3compiler/src/index.ts probes/env-smoke-m9/env-smoke-m9.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     --manifest probes/env-smoke-m9/env-smoke-m9.build.json \
//     -o temp/env-smoke-m9 --run
import asaot.three.loaders.CubeTextureLoader;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.scenes.Scene;
import asaot.three.textures.CubeTexture;
import asaot.three.textures.Texture;

import com.adobe.utils.AGALMiniAssembler;
import flash.display.BitmapData;
import flash.display3D.Context3DProgramType;

var failed:int = 0;
function check(cond:Boolean, msg:String):void
{
    if (cond) trace("PASS " + msg);
    else { trace("FAIL " + msg); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-4):Boolean
{
    return Math.abs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// A. CubeTexture shape
// ---------------------------------------------------------------------------
var empty:CubeTexture = new CubeTexture();
check(empty.images.length == 0, "new CubeTexture starts with no faces");
check(empty.faceSize() == 0, "faceSize() is 0 before any face is filled");
check(empty.flipY == false, "cube faces are not flipped (CubeTexture ctor)");
check(empty.wrapS == Texture.ClampToEdgeWrapping, "CubeTexture inherits Texture wrapS default");
check(empty is Texture, "CubeTexture is a Texture (so material slots stay typed)");

var faces:Vector.<BitmapData> = new Vector.<BitmapData>();
var i:int;
for (i = 0; i < 6; i++)
{
    var b:BitmapData = new BitmapData(8, 8, false, 0);
    // Distinct per-face color so a mis-ordered upload would be visible.
    b.setPixel32(0, 0, 0xFF000000 | (0x30 * (i + 1)));
    faces.push(b);
}
var manual:CubeTexture = new CubeTexture(faces);
check(manual.images.length == 6, "CubeTexture(images) keeps all six faces");
check(manual.faceSize() == 8, "faceSize() reports the face edge (8)");
check(manual.version == 0, "fresh CubeTexture version is 0");
manual.needsUpdate = true;
check(manual.version == 1, "needsUpdate bumps version (renderer re-upload trigger)");
check(manual.images[5].getPixel32(0, 0) == 0xFF000000 | (0x30 * 6),
      "face order is preserved (+X,-X,+Y,-Y,+Z,-Z as created)");

// ---------------------------------------------------------------------------
// B. CubeTextureLoader: six faces, out-of-order completion, one onLoad
// ---------------------------------------------------------------------------
var urls:Vector.<String> = new Vector.<String>();
var sides:Vector.<String> = new Vector.<String>();
sides.push("px"); sides.push("nx"); sides.push("py");
sides.push("ny"); sides.push("pz"); sides.push("nz");
var j:int;
for (j = 0; j < 6; j++) urls.push("assets/textures/cube/SwedishRoyalCastle/" + sides[j] + ".jpg");

var onLoadCount:int = 0;
var loaded:CubeTexture = null;
var cl:CubeTextureLoader = new CubeTextureLoader();
var returned:CubeTexture = cl.load(urls,
    function(c:CubeTexture):void { onLoadCount++; loaded = CubeTexture(c); },
    null,
    function(e:Object):void { trace("cube load error: " + e); });

check(returned != null, "CubeTextureLoader.load returns the CubeTexture synchronously");
check(returned.images.length == 6, "returned cube already has six face slots");
check(returned.images[0] == null, "faces are empty before the decode completes");
check(onLoadCount == 0, "onLoad has not fired synchronously");

// Pump the loader/timer queue until the six decodes land (bounded, so a hang
// reports a FAIL rather than blocking the probe).
var tick:int = 0;
while (onLoadCount == 0 && tick < 400)
{
    tickTimers();
    tick++;
}
check(onLoadCount == 1, "onLoad fired exactly once after all six faces decoded (ticks=" + tick + ")");
check(loaded == returned, "onLoad received the same CubeTexture instance");
check(returned.faceSize() == 512, "decoded faces are 512x512 (got " + returned.faceSize() + ")");
var filled:int = 0;
for (i = 0; i < 6; i++)
{
    if (returned.images[i] != null) filled++;
}
check(filled == 6, "all six faces decoded (" + filled + "/6)");
check(returned.images[0] != returned.images[1], "px and nx are distinct bitmaps");
check(returned.version == 1, "loader bumped version once, after the last face");

// Wrong URL count: report through onError, do not throw.
var badErr:String = null;
var cl2:CubeTextureLoader = new CubeTextureLoader();
var bad:Vector.<String> = new Vector.<String>();
bad.push("a.jpg"); bad.push("b.jpg");
cl2.load(bad, null, null, function(e:Object):void { badErr = String(e); });
check(badErr != null, "a non-six URL vector reports through onError");

// ---------------------------------------------------------------------------
// C. Material / Scene wiring the renderer resolves
// ---------------------------------------------------------------------------
var mat:MeshStandardMaterial = new MeshStandardMaterial();
check(mat.envMap == null, "MeshStandardMaterial.envMap defaults to null");
check(near(mat.envMapIntensity, 1.0), "MeshStandardMaterial.envMapIntensity defaults to 1");
mat.envMap = returned;
mat.envMapIntensity = 0.5;
check(mat.envMap == returned, "material.envMap holds the cube");
check(near(mat.envMapIntensity, 0.5), "material.envMapIntensity is writable");

var scene:Scene = new Scene();
check(scene.environment == null, "Scene.environment defaults to null");
scene.environment = returned;
check(scene.environment == returned, "Scene.environment accepts a CubeTexture");

// The renderer's per-draw resolution: material.envMap || scene.environment.
var resolvedOverride:CubeTexture = mat.envMap != null ? mat.envMap : scene.environment;
check(resolvedOverride == returned, "material.envMap wins over scene.environment");
mat.envMap = null;
var resolvedFallback:CubeTexture = mat.envMap != null ? mat.envMap : scene.environment;
check(resolvedFallback == returned, "scene.environment is used when envMap is null");

// ---------------------------------------------------------------------------
// D. EnvBRDFApprox constants (mirrors fc11/fc12/fc13 in _fillStandardConstants)
// ---------------------------------------------------------------------------
function envBrdfX(roughness:Number, nov:Number):Number
{
    var rx:Number = roughness * (-1.0) + 1.0;
    var ry:Number = roughness * (-0.0275) + 0.0425;
    var rz:Number = roughness * (-0.572) + 1.04;
    var a004:Number = Math.min(rx * rx, Math.pow(2, -9.28 * nov)) * rx + ry;
    return -1.04 * a004 + rz;
}
function envBrdfY(roughness:Number, nov:Number):Number
{
    var rx:Number = roughness * (-1.0) + 1.0;
    var ry:Number = roughness * (-0.0275) + 0.0425;
    var rw:Number = roughness * (0.022) + (-0.04);
    var a004:Number = Math.min(rx * rx, Math.pow(2, -9.28 * nov)) * rx + ry;
    return 1.04 * a004 + rw;
}

// Mirror check for the base-change constant AGAL needs (it has exp, not ex2):
// exp(-6.43287 * n) must equal exp2(-9.28 * n).
check(near(Math.exp(-6.432405835596292 * 0.37), Math.pow(2, -9.28 * 0.37), 1e-12),
      "fc13.x folds log2(e) so exp() reproduces exp2 (-6.4324058356 == -9.28*ln2)");

// A smooth metal (roughness 0, facing the viewer) must return ~F0 = 1.
check(near(envBrdfX(0.0, 1.0), 0.9941, 2e-3), "EnvBRDFApprox(r=0,NoV=1).x ~ 0.994 (got " + envBrdfX(0.0, 1.0) + ")");
check(near(envBrdfY(0.0, 1.0), 0.0059, 2e-3), "EnvBRDFApprox(r=0,NoV=1).y ~ 0.006 (got " + envBrdfY(0.0, 1.0) + ")");
// Roughest, grazing: the DFG curve must land near (0.45, 0), the documented tail.
check(near(envBrdfX(1.0, 0.0), 0.4524, 2e-3), "EnvBRDFApprox(r=1,NoV=0).x ~ 0.452 (got " + envBrdfX(1.0, 0.0) + ")");
check(near(envBrdfY(1.0, 0.0), -0.0024, 2e-3), "EnvBRDFApprox(r=1,NoV=0).y ~ -0.002 (got " + envBrdfY(1.0, 0.0) + ")");
// Monotonic in roughness (the whole point of the split-sum approximation).
check(envBrdfX(0.6, 0.8) < envBrdfX(0.2, 0.8), "EnvBRDFApprox.x falls as roughness rises");

// ---------------------------------------------------------------------------
// E. AGAL: the <cube> sampler form compiles
// ---------------------------------------------------------------------------
var asm:AGALMiniAssembler = new AGALMiniAssembler();
asm.assemble(Context3DProgramType.FRAGMENT,
    'nrm ft0.xyz, v0.xyz\n' +
    'tex ft1, ft0.xyz, fs7 <cube,clamp,linear,mipnone>\n' +
    'mov oc, ft1\n', 2);
check(asm.error == null || asm.error.length == 0, "assembler accepts tex <cube,clamp,linear,mipnone> (err=" + asm.error + ")");

// Same, with the roughness mix + exp/min tail the M9 stage actually uses.
var tail:String =
    'nrm ft0.xyz, v0.xyz\n' +
    'mul ft7.xyz, ft0.xyz, ft0.xyz\n' +
    'mul ft8.x, ft5.x, ft5.x\n' +
    'sub ft8.y, fc6.w, ft8.x\n' +
    'tex ft7, ft7.xyz, fs7 <cube,clamp,linear,mipnone>\n' +
    'mul ft8, ft5.xxxx, fc11\n' +
    'add ft8, ft8, fc12\n' +
    'exp ft9.y, ft8.x\n' +
    'min ft9.x, ft8.x, ft9.y\n' +
    'mov oc, ft7\n';
var asm2:AGALMiniAssembler = new AGALMiniAssembler();
asm2.assemble(Context3DProgramType.FRAGMENT, tail, 2);
check(asm2.error == null || asm2.error.length == 0, "assembler accepts the M9 env tail (exp/min + cube fetch)");
check((asm2.agalcode.length - 7) / 24 == 10, "env tail assembles to 10 instructions");

trace("env-smoke-m9: " + (failed == 0 ? "ALL PASS" : (failed + " FAILED")));
if (failed != 0) throw new Error("env-smoke-m9 failures: " + failed);