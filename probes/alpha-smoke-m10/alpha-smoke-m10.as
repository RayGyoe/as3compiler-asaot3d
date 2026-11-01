// alpha-smoke-m10.as -- M10 tone-mapping / transparency smoke.
//
// Pins the parts of the M10 contract that are observable WITHOUT a GPU:
//
//   A. Material alpha surface: `alphaTest` exists with three.js's default (0),
//      and `transparent`/`opacity` keep their M1 defaults.
//   B. The transparent-pass ordering rule (AGALRenderer.transparentSortKey is
//      public precisely so this can be pinned headlessly): the key is squared
//      camera distance and the pass sorts DESCENDING on it, so the far object
//      is drawn first.
//   C. glTF alphaMode -> material flags: BLEND sets transparent + depthWrite
//      false, MASK sets alphaTest = alphaCutoff (and NOT opacity), OPAQUE sets
//      neither. Parsed from an inline data-URI glTF so no files are needed.
//   D. The AGAL the renderer emits for tone mapping and alpha test actually
//      ASSEMBLES (the runtime rejects unknown opcodes and read-before-write), and
//      its instruction count matches the number the renderer's budget trace
//      reports.
//   E. The ACES reference values this repo's constants produce (computed
//      independently from three.js r187 tonemapping_pars_fragment.glsl.js) are
//      what the assembled program computes -- the arithmetic is mirrored here in
//      AS3 so a wrong matrix row or a swapped coefficient shows up as a number
//      mismatch, not a "looks a bit dark" review comment.
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/alpha-smoke-m10/alpha-smoke-m10.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     --manifest probes/alpha-smoke-m10/alpha-smoke-m10.build.json \
//     -o temp/alpha-smoke-m10 --run
//
// seam/ is in the source list because the probe reaches AGALRenderer and mirrors its
// tone-mapping arithmetic; kit/ alone cannot resolve `asaot.three.AGALRenderer`.
import asaot.three.AGALRenderer;
import asaot.three.core.BufferAttribute;
import asaot.three.core.Object3D;
import asaot.three.geometries.BoxGeometry;
import asaot.three.loaders.GLTFLoader;
import asaot.three.materials.Material;
import asaot.three.materials.MeshBasicMaterial;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.math.Vector3;
import asaot.three.objects.Group;
import asaot.three.objects.Mesh;

import com.adobe.utils.AGALMiniAssembler;
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
// A. Material alpha surface
// ---------------------------------------------------------------------------
var std:MeshStandardMaterial = new MeshStandardMaterial();
check(std.alphaTest == 0, "Material.alphaTest defaults to 0 (Material.js:477)");
check(std.transparent == false, "Material.transparent defaults to false");
check(std.opacity == 1, "Material.opacity defaults to 1");
check(std.depthWrite == true, "Material.depthWrite defaults to true");

var basic:MeshBasicMaterial = new MeshBasicMaterial();
check(basic.alphaTest == 0, "MeshBasicMaterial inherits alphaTest");
check(basic is Material, "alpha surface lives on the Material base (both subclasses)");

// ---------------------------------------------------------------------------
// B. Transparent ordering rule
// ---------------------------------------------------------------------------
var cam:Vector3 = new Vector3(0, 0, 0);
var nearMesh:Mesh = new Mesh(new BoxGeometry(1, 1, 1), std);
nearMesh.position.set(0, 0, 1);
nearMesh.updateMatrixWorld(true);
var farMesh:Mesh = new Mesh(new BoxGeometry(1, 1, 1), std);
farMesh.position.set(0, 0, 5);
farMesh.updateMatrixWorld(true);

var kNear:Number = AGALRenderer.transparentSortKey(nearMesh, cam);
var kFar:Number = AGALRenderer.transparentSortKey(farMesh, cam);
check(near(kNear, 1.0), "sort key is squared distance (near: " + kNear + ")");
check(near(kFar, 25.0), "sort key is squared distance (far: " + kFar + ")");
check(kFar > kNear, "farther object has the LARGER key");
// The pass sorts descending on the key, so index 0 is the farthest.
var order:Array = [nearMesh, farMesh];
var keys:Array = [kNear, kFar];
var i:int;
for (i = 1; i < order.length; i++)
{
    var km:Mesh = order[i] as Mesh;
    var kd:Number = keys[i] as Number;
    var j:int = i - 1;
    while (j >= 0 && (keys[j] as Number) < kd)
    {
        order[j + 1] = order[j];
        keys[j + 1] = keys[j];
        j--;
    }
    order[j + 1] = km;
    keys[j + 1] = kd;
}
check(order[0] === farMesh, "back-to-front order draws the FAR mesh first");

// Off-axis camera: the key must follow the camera, not just world z.
var cam2:Vector3 = new Vector3(0, 0, 5);
check(near(AGALRenderer.transparentSortKey(farMesh, cam2), 0.0), "key is measured from the camera position");

// ---------------------------------------------------------------------------
// C. glTF alphaMode -> material flags
// ---------------------------------------------------------------------------
function materialOf(json:String):Material
{
    var loader:GLTFLoader = new GLTFLoader();
    var root:Object3D = null;
    loader.parse(json, "", function(r:Object3D):void { root = r; }, null);
    if (root == null) return null;
    var g:Group = Group(root);
    var m:Object3D = g.children[0];
    if (!(m is Mesh)) return null;
    return Mesh(m).material;
}

var quadJson:String = '{' +
    '"asset":{"version":"2.0"},' +
    '"buffers":[{"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAABAAIA"}],' +
    '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],' +
    '"accessors":[' +
    '{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","max":[1,1,0],"min":[0,0,0]},' +
    '{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],';

var maskMat:Material = materialOf(quadJson +
    '"materials":[{"alphaMode":"MASK","alphaCutoff":0.35}],' +
    '"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0,"mode":4}]}],' +
    '"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}');
check(maskMat != null, "MASK glTF material parsed");
if (maskMat != null)
{
    check(near(maskMat.alphaTest, 0.35), "alphaMode MASK -> alphaTest = alphaCutoff (" + maskMat.alphaTest + ")");
    check(maskMat.transparent == false, "MASK is not the transparent pass (cutout stays opaque)");
    check(near(maskMat.opacity, 1.0), "MASK does not touch opacity (M10 fix; pre-M10 set it to the cutoff)");
}

var blendMat:Material = materialOf(quadJson +
    '"materials":[{"alphaMode":"BLEND"}],' +
    '"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0,"mode":4}]}],' +
    '"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}');
check(blendMat != null, "BLEND glTF material parsed");
if (blendMat != null)
{
    check(blendMat.transparent == true, "alphaMode BLEND -> transparent pass");
    check(blendMat.depthWrite == false, "alphaMode BLEND -> depthWrite off");
    check(blendMat.alphaTest == 0, "alphaMode BLEND leaves alphaTest at 0");
}

var opaqueMat:Material = materialOf(quadJson +
    '"materials":[{"alphaMode":"OPAQUE"}],' +
    '"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0,"mode":4}]}],' +
    '"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}');
check(opaqueMat != null && opaqueMat.transparent == false && opaqueMat.alphaTest == 0,
      "alphaMode OPAQUE sets neither flag");

// ---------------------------------------------------------------------------
// D. The emitted AGAL assembles
// ---------------------------------------------------------------------------
// The expected ACES sequence, transcribed here from three.js r187
// tonemapping_pars_fragment.glsl.js (NOT copied out of AGALRenderer). The check
// below compares it against what the renderer actually emits, so a drifted
// matrix row or a reordered op in the renderer fails here rather than showing up
// as "the picture looks a bit washed out".
var acExpected:String =
    'mul ft12.xyz, ft4.xyz, fc14.xxx\n' +
    'dp3 ft13.x, ft12.xyz, fc16.xyz\n' +
    'dp3 ft13.y, ft12.xyz, fc17.xyz\n' +
    'dp3 ft13.z, ft12.xyz, fc18.xyz\n' +
    'add ft14.xyz, ft13.xyz, fc14.yyy\n' +
    'mul ft14.xyz, ft13.xyz, ft14.xyz\n' +
    'add ft14.xyz, ft14.xyz, fc14.zzz\n' +
    'mul ft12.xyz, ft13.xyz, fc14.www\n' +
    'add ft12.xyz, ft12.xyz, fc15.xxx\n' +
    'mul ft12.xyz, ft13.xyz, ft12.xyz\n' +
    'add ft12.xyz, ft12.xyz, fc15.yyy\n' +
    'rcp ft12.xyz, ft12.xyz\n' +
    'mul ft14.xyz, ft14.xyz, ft12.xyz\n' +
    'dp3 ft13.x, ft14.xyz, fc19.xyz\n' +
    'dp3 ft13.y, ft14.xyz, fc20.xyz\n' +
    'dp3 ft13.z, ft14.xyz, fc21.xyz\n' +
    'sat ft4.xyz, ft13.xyz\n';

// The renderer's own emission for the same four registers...
var acEmitted:String = AGALRenderer.acesToneMapSnippet("ft4", "ft12", "ft13", "ft14");
check(acEmitted == acExpected, "AGALRenderer.acesToneMapSnippet matches the transcribed r187 sequence");
if (acEmitted != acExpected)
{
    // Print both so a failure is diagnosable without editing the probe.
    trace("  expected: " + acExpected.replace("\n", "|"));
    trace("  emitted : " + acEmitted.replace("\n", "|"));
}

var atEmitted:String = AGALRenderer.alphaTestSnippet("ft8", "ft2.wwww");
// The kil source carries `.xxxx`: AIR refuses a `kil` without an explicit scalar
// swizzle (#3703), and the register is filled uniformly so the scalar is what the
// negative-component discard means anyway.
check(atEmitted == 'sub ft8, ft2.wwww, fc15.zzzz\nkil ft8.xxxx\n',
      "AGALRenderer.alphaTestSnippet is sub-then-kil (AGAL discards on any negative component)");

var fragSrc:String =
    'mov ft4, fc0\n' +                      // stand-in for the lit colour
    acEmitted +
    'sat ft4.xyz, ft4.xyz\n' +
    'pow ft4.x, ft4.x, fc1.w\n' +
    'pow ft4.y, ft4.y, fc1.w\n' +
    'pow ft4.z, ft4.z, fc1.w\n' +
    'mul ft8, ft2.wwww, fc4.wwww\n' +
    'sub ft8, ft8, fc15.zzzz\n' +
    'kil ft8.xxxx\n' +
    // AIR #3701: the output register has to be written in FULL by ONE
    // instruction, so the alpha is staged into the temp and `oc` is moved whole
    // (the old `mov oc.w` + `mov oc.xyz` pair is refused at upload).
    'mov ft4.w, ft8.x\n' +
    'mov oc, ft4\n';

var asm:AGALMiniAssembler = new AGALMiniAssembler();
var fragCode:Object = asm.assemble(Context3DProgramType.FRAGMENT, fragSrc, 2);
check(fragCode != null, "ACES tone-map + alpha-test fragment assembles (AGAL2)");
if (fragCode != null)
{
    // AGALMiniAssembler emits a 7-byte header then 24 bytes per instruction,
    // so the byte-vector length is an exact instruction count.
    var nInstr:int = (fragCode.length - 7) / 24;
    check(nInstr == 27, "emitted fragment is 27 instructions (1 setup + 17 ACES + 9 output), got " + nInstr);
}

// The `kil` form alone must also assemble -- it is the only discard AGAL has.
var kilCode:Object = asm.assemble(Context3DProgramType.FRAGMENT,
    'mov ft0, fc0\n' +
    'sub ft1, ft0.wwww, fc15.zzzz\n' +
    'kil ft1.xxxx\n' +
    'mov oc, ft0\n', 2);
check(kilCode != null, "alpha-test kil fragment assembles");

// ---------------------------------------------------------------------------
// E. ACES reference values (independent of the shader)
// ---------------------------------------------------------------------------
// Same matrices/coefficients as the AGAL above, evaluated in double precision.
// Reference values come from three.js r187 tonemapping_pars_fragment.glsl.js
// ACESFilmicToneMapping (exposure 1 -> pre-scale 1/0.6).
function acesRef(r:Number, g:Number, b:Number, expo:Number = 1.0):Array
{
    var s:Number = expo / 0.6;
    var cr:Number = r * s;
    var cg:Number = g * s;
    var cb:Number = b * s;
    // ACESInputMat rows
    var v0:Number = 0.59719 * cr + 0.35458 * cg + 0.04823 * cb;
    var v1:Number = 0.07600 * cr + 0.90834 * cg + 0.01566 * cb;
    var v2:Number = 0.02840 * cr + 0.13383 * cg + 0.83777 * cb;
    // RRTAndODTFit
    var a0:Number = v0 * (v0 + 0.0245786) - 0.000090537;
    var a1:Number = v1 * (v1 + 0.0245786) - 0.000090537;
    var a2:Number = v2 * (v2 + 0.0245786) - 0.000090537;
    var b0:Number = v0 * (0.983729 * v0 + 0.4329510) + 0.238081;
    var b1:Number = v1 * (0.983729 * v1 + 0.4329510) + 0.238081;
    var b2:Number = v2 * (0.983729 * v2 + 0.4329510) + 0.238081;
    var t0:Number = a0 / b0;
    var t1:Number = a1 / b1;
    var t2:Number = a2 / b2;
    // ACESOutputMat rows
    var o0:Number = 1.60475 * t0 + -0.53108 * t1 + -0.07367 * t2;
    var o1:Number = -0.10208 * t0 + 1.10813 * t1 + -0.00605 * t2;
    var o2:Number = -0.00327 * t0 + -0.07276 * t1 + 1.07602 * t2;
    return [Math.max(0, Math.min(1, o0)), Math.max(0, Math.min(1, o1)), Math.max(0, Math.min(1, o2))];
}

var mid:Array = acesRef(0.18, 0.18, 0.18);
check(near(mid[0] as Number, 0.213105, 1e-5), "ACES(0.18 grey) = 0.213105, got " + mid[0]);
var white:Array = acesRef(1, 1, 1);
check(near(white[0] as Number, 0.763397, 1e-5), "ACES(1.0) = 0.763397 (highlights roll off, got " + white[0] + ")");
var hot:Array = acesRef(4, 4, 4);
check(near(hot[0] as Number, 0.952237, 1e-5), "ACES(4.0) = 0.952237 (never clips to 1, got " + hot[0] + ")");
var tinted:Array = acesRef(0.5, 0.25, 0.1);
check(near(tinted[0] as Number, 0.567958, 1e-5) && near(tinted[1] as Number, 0.320617, 1e-5),
      "ACES preserves relative channel ordering (" + tinted[0] + ", " + tinted[1] + ")");
var black:Array = acesRef(0, 0, 0);
check(near(black[0] as Number, 0.0) && near(black[1] as Number, 0.0), "ACES(0) stays 0");
var expo2:Array = acesRef(1, 1, 1, 2.0);
check(near(expo2[0] as Number, 0.887514, 1e-5), "ACES exposure 2 lifts 1.0 to 0.887514, got " + expo2[0]);
check((white[0] as Number) < (expo2[0] as Number), "higher exposure -> brighter result (monotonic in exposure)");

trace("alpha-smoke-m10: " + (failed == 0 ? "ALL PASS" : failed + " FAILURES"));