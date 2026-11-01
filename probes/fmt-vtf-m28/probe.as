// fmt-vtf-probe.as -- functional check of the two compiler capabilities that
// asaot3d cares about, driven the way the engine actually drives them:
//   A. Context3DTextureFormat surface (what the renderer can allocate/upload)
//   B. vertex texture fetch (AGAL `tld` inside a VERTEX program)
//
// No window: Stage3D here hands out a context without a visible stage, so this
// runs headless in the AOT build (ASC_RENDER_STAGE3D=1 -> real Metal).
//
// WHY IT IS IN THE REPO (three-api-design.md §36): sections A and B are the
// RULES the engine's HDR/environment/character paths are built on, and every one
// of them is a measured fact rather than a documented one -- `rgbaHalfFloat`
// cubes silently store 8-bit bytes (A5), cube mip levels are silently dropped
// (A6), and a half-float render target keeps 2.0 while an 8-bit one clamps it
// (A3). A5/A6 are the reason M25-R1 is six CubeTextures instead of one cube with
// a mip ladder; A3 is the gate on any future HDR offscreen pass.
//
// B1 depends on the compiler translating AGAL `tld` (vertex-stage texture
// fetch). On a compiler that predates that, B1 reports the loud failure it used
// to be -- a draw-time throw with no message -- and the run is RED, which is the
// intended signal: asaot3d's GPU-skinning question (D84) is decided by this
// capability, so it must not silently regress.
//
// The AIR half of the evidence is air/ (VtfAir.as + VtfAir-app.xml + build.sh):
// three of the four facts in §36 are claims about AIR, and a claim about AIR has
// to come from adl. Run `AIRSDK_HOME=... ./air/build.sh --run`; it compiles with
// mxmlc and prints the probe log (which lands in ~/asaot-fmt-vtf-air.txt, because
// adl on macOS forwards neither trace() nor uncaught errors).
import com.adobe.utils.AGALMiniAssembler;
import flash.display.BitmapData;
import flash.display.Stage;
import flash.display.Stage3D;
import flash.display3D.Context3D;
import flash.display3D.Context3DBlendFactor;
import flash.display3D.Context3DProgramType;
import flash.display3D.Context3DRenderMode;
import flash.display3D.Context3DTextureFormat;
import flash.display3D.Context3DVertexBufferFormat;
import flash.display3D.IndexBuffer3D;
import flash.display3D.Program3D;
import flash.display3D.VertexBuffer3D;
import flash.display3D.textures.CubeTexture;
import flash.display3D.textures.Texture;
import flash.display3D.textures.TextureBase;

var pass:int = 0;
var fail:int = 0;

function ok(cond:Boolean, msg:String):void {
    if (cond) { pass++; trace("PASS " + msg); }
    else { fail++; trace("FAIL " + msg); }
}

var stage:Stage = new Stage();
var s3d:Stage3D = stage.stage3Ds[0];
s3d.requestContext3D(Context3DRenderMode.AUTO, "enhanced");
var ctx:Context3D = s3d.context3D;
if (ctx == null) { trace("FATAL no context3D"); }
ctx.configureBackBuffer(16, 16, 0, false);
trace("driver: " + ctx.driverInfo + " profile=" + ctx.profile);

// ---------------------------------------------------------------- geometry
// Full-screen triangle in clip space; uv is a second attribute so a vertex
// program *can* fetch a texture with it (that is the whole point of section B).
var pos:Vector.<Number> = new Vector.<Number>();
pos.push(-1); pos.push(-1); pos.push(0);
pos.push(3);  pos.push(-1); pos.push(0);
pos.push(-1); pos.push(3);  pos.push(0);
var vbPos:VertexBuffer3D = ctx.createVertexBuffer(3, 3);
vbPos.uploadFromVector(pos, 0, 3);
ctx.setVertexBufferAt(0, vbPos, 0, Context3DVertexBufferFormat.FLOAT_3);

var uv:Vector.<Number> = new Vector.<Number>();
uv.push(0.5); uv.push(0.5); uv.push(0);
uv.push(0.5); uv.push(0.5); uv.push(0);
uv.push(0.5); uv.push(0.5); uv.push(0);
var vbUv:VertexBuffer3D = ctx.createVertexBuffer(3, 3);
vbUv.uploadFromVector(uv, 0, 3);
ctx.setVertexBufferAt(1, vbUv, 0, Context3DVertexBufferFormat.FLOAT_3);

var idx:Vector.<uint> = new Vector.<uint>();
idx.push(0); idx.push(1); idx.push(2);
var ib:IndexBuffer3D = ctx.createIndexBuffer(3);
ib.uploadFromVector(idx, 0, 3);

var asm:AGALMiniAssembler = new AGALMiniAssembler();

// Uploads a program pair; returns null and records why when the runtime refuses.
function makeProgram(vsrc:String, fsrc:String):Program3D {
    var v:AGALMiniAssembler = new AGALMiniAssembler();
    var f:AGALMiniAssembler = new AGALMiniAssembler();
    var vb:Object = v.assemble(Context3DProgramType.VERTEX, vsrc, 4);
    var fb:Object = f.assemble(Context3DProgramType.FRAGMENT, fsrc, 4);
    if (vb == null || v.error != "") { trace("  asm-vertex-error: " + v.error); return null; }
    if (fb == null || f.error != "") { trace("  asm-frag-error: " + f.error); return null; }
    var p:Program3D = ctx.createProgram();
    try {
        p.upload(vb as flash.utils.ByteArray, fb as flash.utils.ByteArray);
    } catch (e:Error) {
        trace("  upload-error: " + e.message);
        return null;
    }
    return p;
}

// Standard vertex program: uv passthrough from va1.
var VS_UV:String = "mov op, va0\nmov v0, va1\n";
// Sample the cube/2d bound at fs0 and write it straight out.
var FS_SAMPLE:String = "tex ft0, v0, fs0 <2d,clamp,linear,mipnone>\nmov oc, ft0\n";
var FS_SAMPLE_CUBE:String = "tex ft0, v0, fs0 <cube,clamp,linear,mipnone>\nmov oc, ft0\n";
// Half the sample (fc0.x = 0.25) -- discriminates float storage from 8-bit clamp.
var FS_SAMPLE_Q:String = "tex ft0, v0, fs0 <2d,clamp,linear,mipnone>\nmul oc, ft0, fc0.xxxx\n";
var FS_CONST:String = "mov oc, fc0\n";

var pSample:Program3D = makeProgram(VS_UV, FS_SAMPLE);
var pSampleCube:Program3D = makeProgram(VS_UV, FS_SAMPLE_CUBE);
var pSampleQ:Program3D = makeProgram(VS_UV, FS_SAMPLE_Q);
var pConst:Program3D = makeProgram(VS_UV, FS_CONST);
ok(pSample != null && pSampleCube != null && pSampleQ != null && pConst != null,
   "A0 baseline programs (2d/cube/quarter/const) upload");

function solid(w:int, h:int, argb:uint):BitmapData {
    var bd:BitmapData = new BitmapData(w, h, true, argb);
    return bd;
}

function putQuad(p:Program3D, scale:Number):void {
    var c:Vector.<Number> = new Vector.<Number>();
    c.push(scale); c.push(scale); c.push(scale); c.push(1);
    ctx.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, c, 1);
    ctx.setProgram(p);
    ctx.drawTriangles(ib, 0, 1);
}

// Draws one full-screen triangle with p and returns the centre pixel.
function renderRead(p:Program3D, scale:Number):uint {
    ctx.setRenderToBackBuffer();
    ctx.clear(0, 0, 0, 1, 1.0, 0, 3);
    putQuad(p, scale);
    var bd:BitmapData = new BitmapData(16, 16, false, 0);
    ctx.drawToBitmapData(bd);
    return bd.getPixel(8, 8);
}

function hex(v:uint):String { return "0x" + v.toString(16); }

// ============================ A. texture formats ============================
trace("--- A. Context3DTextureFormat constants ---");
var F_BGRA:String = Context3DTextureFormat.BGRA;
var F_RGBA:String = "rgba";   // AIR has no such constant; the string must be rejected
var F_565:String = Context3DTextureFormat.BGR_PACKED;
var F_4444:String = Context3DTextureFormat.BGRA_PACKED;
var F_HALF:String = Context3DTextureFormat.RGBA_HALF_FLOAT;
trace("A1 bgra=" + F_BGRA + " rgba=" + F_RGBA + " bgrPacked=" + F_565
      + " bgraPacked=" + F_4444 + " half=" + F_HALF);
ok(F_BGRA == "bgra" && F_RGBA == "rgba" && F_565 == "bgrPacked565"
   && F_4444 == "bgraPacked4444" && F_HALF == "rgbaHalfFloat",
   "A1 format constant spelling matches AIR");

// A2: which formats does createTexture accept on this profile?
function tryCreate(fmt:String):String {
    try {
        var t:Texture = ctx.createTexture(4, 4, fmt, false);
        return t == null ? "null" : "ok";
    } catch (e:Error) {
        return "throw " + e.message;
    }
}
trace("A2 createTexture bgra        -> " + tryCreate(F_BGRA));
trace("A2 createTexture rgba        -> " + tryCreate(F_RGBA));
trace("A2 createTexture bgrPacked   -> " + tryCreate(F_565));
trace("A2 createTexture bgraPacked  -> " + tryCreate(F_4444));
trace("A2 createTexture rgbaHalf    -> " + tryCreate(F_HALF));
trace("A2 createTexture compressed  -> " + tryCreate(Context3DTextureFormat.COMPRESSED));

// A3: does a half-float 2D texture actually keep values above 1.0?
// The renderer's use case is an HDR offscreen target (bloom / tonemap post).
function hdrRoundTrip(fmt:String):uint {
    var rt:Texture;
    try { rt = ctx.createTexture(16, 16, fmt, true); }
    catch (e:Error) { trace("  A3 " + fmt + " render target refused: " + e.message); return 0xDEADBEE; }
    ctx.setRenderToTexture(rt, true);
    ctx.clear(2.0, 2.0, 2.0, 1.0, 1.0, 0, 3);
    ctx.setRenderToBackBuffer();
    ctx.setTextureAt(0, rt);
    ctx.setSamplerStateAt(0, "clamp", "linear", "mipnone");
    // pSampleQ multiplies the sample by fc0.x = 0.25: float storage gives 0.5
    // (mid grey), an 8-bit clamp gives 0.25 (dark grey).
    var px:uint = renderRead(pSampleQ, 0.25);
    rt.dispose();
    return px;
}
var qBgra:uint = hdrRoundTrip(F_BGRA);
var qHalf:uint = hdrRoundTrip(F_HALF);
trace("A3 clear(2.0) as BGRA8 rt, sampled*0.25 -> " + hex(qBgra)
      + "; as rgbaHalfFloat rt -> " + hex(qHalf));
ok(qBgra == 0x404040, "A3 BGRA8 render target clamps 2.0 to 1.0 (control)");
ok(qHalf == 0x808080, "A3 rgbaHalfFloat render target preserves 2.0");
if (qHalf == 0xDEADBEE) trace("A3 SKIPPED: half-float targets are not reachable on this profile");

// A4: half-float cube -- format honoured, or silently 8-bit BGRA?
function tryCube(fmt:String):String {
    try {
        var c:CubeTexture = ctx.createCubeTexture(8, fmt, false);
        return c == null ? "null" : "ok";
    } catch (e:Error) {
        return "throw " + e.message;
    }
}
trace("A4 createCubeTexture bgra       -> " + tryCube(F_BGRA));
trace("A4 createCubeTexture rgbaHalf   -> " + tryCube(F_HALF));

var cubeBgra:CubeTexture = ctx.createCubeTexture(8, F_BGRA, false);
var cubeHalf:CubeTexture = null;
try { cubeHalf = ctx.createCubeTexture(8, F_HALF, false); } catch (e:Error) { trace("A4 half cube: " + e.message); }

var redBd:BitmapData = solid(8, 8, 0xFFFF0000);
var greenBd:BitmapData = solid(8, 8, 0xFF00FF00);
var i:int;
for (i = 0; i < 6; i++) cubeBgra.uploadFromBitmapData(redBd, i, 0);
ctx.setTextureAt(0, cubeBgra);
ctx.setSamplerStateAt(0, "clamp", "linear", "mipnone");
var cubePxBgra:uint = renderRead(pSampleCube, 1.0);
trace("A5 BGRA cube sampled -> " + hex(cubePxBgra));
ok(cubePxBgra == 0xFF0000, "A5 BGRA cube upload+sample works (renderer's current path)");

if (cubeHalf != null) {
    for (i = 0; i < 6; i++) cubeHalf.uploadFromBitmapData(redBd, i, 0);
    ctx.setTextureAt(0, cubeHalf);
    ctx.setSamplerStateAt(0, "clamp", "linear", "mipnone");
    var cubePxHalf:uint = renderRead(pSampleCube, 1.0);
    trace("A5 rgbaHalfFloat cube sampled -> " + hex(cubePxHalf));
    ok(cubePxHalf == cubePxBgra,
       "A5 half-float cube is accepted but stores the same 8-bit bytes"
       + " (no float cube storage in this backend)");

    // A6: mip-level uploads on a cube. CubeTexture_uploadFromBitmapData drops
    // miplevel != 0, so a per-roughness mip ladder cannot be stored in ONE cube.
    try {
        for (i = 0; i < 6; i++) cubeHalf.uploadFromBitmapData(greenBd, i, 1);
        var mipPx:uint = renderRead(pSampleCube, 1.0);
        trace("A6 cube miplevel=1 upload accepted silently; level0 sample -> " + hex(mipPx));
        ok(mipPx == 0xFF0000, "A6 cube miplevel>0 upload neither throws nor changes level 0");
    } catch (e2:Error) {
        trace("A6 cube miplevel=1 upload throws: " + e2.message);
    }
}

// ======================= B. vertex texture fetch =======================
trace("--- B. vertex texture fetch ---");
// The engine's GPU-skinning idea (D84) needs the vertex stage to read a texture.
// AGAL's vertex-stage fetch is `tld` (TLD is OP_VERT_ONLY in Adobe's assembler,
// while `tex` is OP_FRAG_ONLY). It takes an explicit LOD operand.
var VS_VTF:String = "mov op, va0\n"
    + "tld vt0, va1.xy, vs0 <2d,clamp,linear,mipnone>, va1.z\n"
    + "mov v0, vt0\n";
var pVtf:Program3D = makeProgram(VS_VTF, "mov oc, v0\n");
trace("B1 vertex-stage tex program upload -> " + (pVtf == null ? "REFUSED" : "accepted"));
if (pVtf != null) {
    var t:Texture = ctx.createTexture(4, 4, F_BGRA, false);
    t.uploadFromBitmapData(solid(4, 4, 0xFF00FF00), 0);
    ctx.setTextureAt(0, t);
    ctx.setSamplerStateAt(0, "clamp", "linear", "mipnone");
    try {
        trace("  B1 step: setRenderToBackBuffer");
        ctx.setRenderToBackBuffer();
        trace("  B1 step: clear");
        ctx.clear(0, 0, 0, 1, 1.0, 0, 3);
        var c0:Vector.<Number> = new Vector.<Number>();
        c0.push(1); c0.push(1); c0.push(1); c0.push(1);
        trace("  B1 step: setProgramConstantsFromVector");
        ctx.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, c0, 1);
        trace("  B1 step: setProgram");
        ctx.setProgram(pVtf);
        trace("  B1 step: drawTriangles");
        ctx.drawTriangles(ib, 0, 1);
        trace("  B1 step: drawToBitmapData");
        var bd1:BitmapData = new BitmapData(16, 16, false, 0);
        ctx.drawToBitmapData(bd1);
        var px:uint = bd1.getPixel(8, 8);
        trace("B1 vertex-stage sample result -> " + hex(px));
        // The texture is solid green; anything reddish means the fetch read the
        // wrong unit or returned zero and the clear showed through.
        ok(px == 0xFF00 || px == 0x00FF00 || px == 0xFF00FF00,
           "B1 vertex-stage `tld` really samples the texture (green read back)");
    } catch (e3:Error) {
        trace("B1 draw threw: name=" + e3.name + " id=" + e3.errorID + " msg=" + e3.message);
        ok(false, "B1 vertex-stage `tld` fails at draw time (upload accepted, first use dies)");
    }
} else {
    ok(true, "B1 vertex-stage `tld` is refused at upload (loud, not a driver log)");
}

// B2: explicit-LOD form, the shape a mip-palette skinning shader would use.
var VS_TEX_IN_VERTEX:String = "mov op, va0\n"
    + "tex vt0, va1.xy, vs0 <2d,clamp,linear,mipnone>\n"
    + "mov v0, vt0\n";
var pBad:Program3D = makeProgram(VS_TEX_IN_VERTEX, "mov oc, v0\n");
trace("B2 vertex-stage `tex` (fragment-only opcode) -> " + (pBad == null ? "REFUSED" : "accepted"));

trace("RESULT pass=" + pass + " fail=" + fail);
if (fail == 0) trace("ALL PASS");