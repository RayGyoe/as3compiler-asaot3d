// loader-smoke-m5.as -- M5 asset-loading smoke: FileLoader / ImageLoader /
// TextureLoader over the URLLoader + Skia decode chain, plus the ObjectLoader
// uuid guard for bare BufferGeometry JSON (three.js examples/models/json shape).
//
// Needs the same build manifest as the demo: ASC_USE_SKIA + skia sources/libs
// (probes/asset-load-probe/asset-load-probe.build.json is the reference; without
// ASC_USE_SKIA the decode stub reports #2124 for every image).

function check(cond:Boolean, msg:String):void { if (!cond) throw new Error("FAIL: " + msg); }

// 1. FileLoader text mode: read a small text file from disk.
var flTxt:FileLoader = new FileLoader();
var txtValue:String = "";
var txtErr:String = "";
function onTxtLoaded(data:Object):void { txtValue = String(data); }
function onTxtError(e:Object):void { txtErr = String(e); }
flTxt.load("assets/models/suzanne_buffergeometry.json", onTxtLoaded, null, onTxtError);
tickTimers();
check(txtValue.length > 1000, "FileLoader text mode delivers the suzanne JSON (" + txtValue.length + " chars)");
check(txtValue.indexOf("BufferGeometry") > 0, "text payload is the requested file");
check(txtErr == "", "text load reports no error");

// 2. FileLoader arraybuffer mode: PNG bytes as a ByteArray.
var flBin:FileLoader = new FileLoader();
flBin.responseType = "arraybuffer";
var binValue:ByteArray = null;
var binErr:String = "";
function onBinLoaded(data:Object):void { binValue = data as ByteArray; }
function onBinError(e:Object):void { binErr = String(e); }
flBin.load("assets/textures/checker.png", onBinLoaded, null, onBinError);
tickTimers();
check(binValue != null, "arraybuffer mode delivers a ByteArray");
check(binValue.length == 1072, "checker.png byte count is exact (got " + binValue.length + ")");
check(binErr == "", "binary load reports no error");

// 3. FileLoader path prefix: setPath prepends the directory.
var flPath2:FileLoader = new FileLoader();
flPath2.setPath("assets/textures/");
flPath2.responseType = "arraybuffer";
var pathValue2:ByteArray = null;
function onPathLoaded2(data:Object):void { pathValue2 = data as ByteArray; }
flPath2.load("uvgrid.png", onPathLoaded2, null, null);
tickTimers();
check(pathValue2 != null && pathValue2.length > 1000, "setPath prefix resolves the file (" + (pathValue2 != null ? pathValue2.length : 0) + " bytes)");

// 4. FileLoader IO_ERROR: a missing file calls onError, never onLoad.
var flMiss:FileLoader = new FileLoader();
var missLoaded:Boolean = false;
var missErrored:Boolean = false;
function onMissLoaded(data:Object):void { missLoaded = true; }
function onMissError(e:Object):void { missErrored = true; }
flMiss.load("definitely/not/here.bin", onMissLoaded, null, onMissError);
tickTimers();
check(missErrored && !missLoaded, "missing file reports onError, not onLoad");

// 5. ImageLoader: PNG -> decoded Bitmap -> BitmapData pixels.
var img:ImageLoader = new ImageLoader();
var bmp:Bitmap = null;
var imgErr:String = "";
function onImgLoaded(image:Bitmap):void { bmp = image; }
function onImgError(e:Object):void { imgErr = String(e); }
img.load("assets/textures/checker.png", onImgLoaded, null, onImgError);
tickTimers();
check(bmp != null, "ImageLoader delivers a Bitmap");
var bd:BitmapData = bmp.bitmapData;
check(bd != null && bd.width == 256 && bd.height == 256, "decoded checker is 256x256");
check((bd.getPixel32(0, 0) >> 16 & 0xff) > 200, "checker (0,0) is white");
check((bd.getPixel32(40, 0) >> 16 & 0xff) < 64, "checker (40,0) is near-black");
check(imgErr == "", "ImageLoader reports no error");

// 6. TextureLoader: synchronous Texture return, async image fill + onLoad.
var texLoader:TextureLoader = new TextureLoader();
var tex:Texture = null;
var texFilled:Boolean = false;
var texErr:String = "";
function onTexLoaded(t:Texture):void { texFilled = true; }
function onTexError(e:Object):void { texErr = String(e); }
tex = texLoader.load("assets/textures/checker.png", onTexLoaded, null, onTexError);
check(tex != null, "TextureLoader.load returns the Texture synchronously");
check(tex.image == null, "texture.image is null until the decode completes");
tickTimers();
check(texFilled, "onLoad fires after the decode");
check(tex.image != null && tex.image.width == 256, "texture.image is the decoded BitmapData");
check(tex.version > 0, "needsUpdate bump is visible through version (" + tex.version + ")");
check(texErr == "", "TextureLoader reports no error");

// 7. ObjectLoader uuid guard: bare BufferGeometry JSON without a uuid keeps the
//    constructor-generated one (BufferGeometryLoader.js semantics) instead of
//    collapsing to "null".
var bareJson:Object = JSON.parse(
    '{"metadata":{"type":"BufferGeometry","version":3},' +
    '"data":{"attributes":{' +
    '"position":{"itemSize":3,"type":"Float32Array","array":[0,0,0, 1,0,0, 0,1,0]}' +
    '}}}');
var bareLoader:ObjectLoader = new ObjectLoader();
var bare:BufferGeometry = bareLoader.parseGeometry(bareJson);
check(bare != null, "bare BufferGeometry JSON parses");
check(bare.uuid != null && bare.uuid.length > 8 && bare.uuid != "null", "uuid-less geometry keeps its generated uuid (got '" + bare.uuid + "')");
check(bare.getAttribute("position").count == 3, "bare geometry has 3 vertices");

// 8. Real model: parse suzanne from disk, compute vertex normals, verify the
//    normal attribute appears with unit length (suzanne ships position+index
//    only -- the three.js JSON test models' canonical shape).
var flSuz:FileLoader = new FileLoader();
var suzText:String = "";
function onSuzLoaded(data:Object):void { suzText = String(data); }
flSuz.load("assets/models/suzanne_buffergeometry.json", onSuzLoaded, null, null);
tickTimers();
check(suzText.length > 1000, "suzanne JSON loads");
var suz:BufferGeometry = new ObjectLoader().parseGeometry(JSON.parse(suzText));
check(suz != null, "suzanne parses as BufferGeometry");
check(suz.getAttribute("position").count == 505, "suzanne has 505 vertices");
check(suz.index != null && suz.index.count % 3 == 0, "suzanne index is triangular");
check(suz.getAttribute("normal") == null, "suzanne ships no normals (position+index only)");
suz.computeVertexNormals();
var suzN:BufferAttribute = suz.getAttribute("normal");
check(suzN != null && suzN.count == 505, "computeVertexNormals builds the normal attribute");
// Every computed normal must be unit length (the normalizeNormals tail).
var unitOk:Boolean = true;
for (var k:int = 0; k < suzN.count; k++)
{
    var nx:Number = suzN.getX(k), ny:Number = suzN.getY(k), nz:Number = suzN.getZ(k);
    var mag:Number = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (mag < 0.999 || mag > 1.001) { unitOk = false; break; }
}
check(unitOk, "all computed normals are unit length");

// ---------------------------------------------------------------------------
// 9. §31 loader alignment: ImageLoader.load() returns the decode handle
//    (three.js `load` returns the Image; D159). Before this change the method
//    returned void and callers could only wait for the callback.
// ---------------------------------------------------------------------------
var imgHandle:ImageLoader = new ImageLoader();
var handleGot:Bitmap = null;
var handleLoader:flash.display.Loader = imgHandle.load(
    "assets/textures/checker.png",
    function(image:Bitmap):void { handleGot = image; },
    null, null);
check(handleLoader != null, "ImageLoader.load returns a handle synchronously (D159)");
check(handleGot == null, "the handle is returned before the image decodes");
tickTimers();
check(handleGot != null, "the returned handle still drives the callback");
check(handleLoader.content == handleGot, "handle.content IS the decoded Bitmap handed to onLoad");

// Pixel signatures used by the concurrency checks below: the two textures must
// be distinguishable, otherwise "each callback got its own image" is unfalsifiable.
var checkerSig:int = bd.getPixel32(10, 10);
var uvgridLoader:ImageLoader = new ImageLoader();
var uvgridBmp:Bitmap = null;
uvgridLoader.load("assets/textures/uvgrid.png",
    function(image:Bitmap):void { uvgridBmp = image; }, null, null);
tickTimers();
check(uvgridBmp != null, "uvgrid decodes (baseline for the concurrency checks)");
var uvgridSig:int = uvgridBmp.bitmapData.getPixel32(10, 10);
check(checkerSig != uvgridSig, "the two fixture images differ at (10,10)");

// ---------------------------------------------------------------------------
// 10. §31/D158: two loads on ONE ImageLoader instance. Before the fix the
//     instance held `_onLoad`, so the first image was delivered to the SECOND
//     callback (and the first was starved) -- three.js is safe because it
//     builds fresh closures per load().
// ---------------------------------------------------------------------------
var imgRacy:ImageLoader = new ImageLoader();
var racySigA:int = 0, racySigB:int = 0;
var racyCallsA:int = 0, racyCallsB:int = 0;
imgRacy.load("assets/textures/checker.png",
    function(image:Bitmap):void { racyCallsA++; racySigA = image.bitmapData.getPixel32(10, 10); }, null, null);
imgRacy.load("assets/textures/uvgrid.png",
    function(image:Bitmap):void { racyCallsB++; racySigB = image.bitmapData.getPixel32(10, 10); }, null, null);
tickTimers();
check(racyCallsA == 1, "concurrent ImageLoader: first onLoad fires exactly once (got " + racyCallsA + ")");
check(racyCallsB == 1, "concurrent ImageLoader: second onLoad fires exactly once (got " + racyCallsB + ")");
check(racySigA == checkerSig, "concurrent ImageLoader: first callback got the checker image");
check(racySigB == uvgridSig, "concurrent ImageLoader: second callback got the uvgrid image");

// ---------------------------------------------------------------------------
// 11. Same for FileLoader (arraybuffer): each call must see its own bytes.
//     checker.png is 1072 bytes; the suzanne JSON is a different length.
// ---------------------------------------------------------------------------
var flRacy:FileLoader = new FileLoader();
flRacy.responseType = "arraybuffer";
var racyLenPng:int = -1, racyLenJson:int = -1;
flRacy.load("assets/textures/checker.png",
    function(data:Object):void { racyLenPng = (data as ByteArray).length; }, null, null);
flRacy.load("assets/models/suzanne_buffergeometry.json",
    function(data:Object):void { racyLenJson = (data as ByteArray).length; }, null, null);
tickTimers();
check(racyLenPng == 1072, "concurrent FileLoader: png callback got 1072 bytes (got " + racyLenPng + ")");
check(racyLenJson > 1000 && racyLenJson != 1072,
    "concurrent FileLoader: json callback got its own bytes (got " + racyLenJson + ")");

// ---------------------------------------------------------------------------
// 12. Same for TextureLoader: two textures, each filled with its own image.
// ---------------------------------------------------------------------------
var texRacy:TextureLoader = new TextureLoader();
var texRacyA:Texture = texRacy.load("assets/textures/checker.png", null, null, null);
var texRacyB:Texture = texRacy.load("assets/textures/uvgrid.png", null, null, null);
check(texRacyA != texRacyB, "concurrent TextureLoader returns two distinct textures");
tickTimers();
check(texRacyA.image != null && texRacyA.image.getPixel32(10, 10) == checkerSig,
    "concurrent TextureLoader: first texture holds the checker image");
check(texRacyB.image != null && texRacyB.image.getPixel32(10, 10) == uvgridSig,
    "concurrent TextureLoader: second texture holds the uvgrid image");

// ---------------------------------------------------------------------------
// 13. §31 L3/L4: the reference FileLoader surface that used to be missing.
// ---------------------------------------------------------------------------
// 13a. responseType 'json' delivers a parsed object (three.js FileLoader.js:229).
var flJson:FileLoader = new FileLoader();
var jsonValue:Object = null;
var jsonErr:String = "";
var chainOk:Boolean = (flJson.setResponseType("json") == flJson) && (flJson.setMimeType("application/json") == flJson);
flJson.load("assets/models/suzanne_buffergeometry.json",
    function(data:Object):void { jsonValue = data as Object; },
    null,
    function(e:Object):void { jsonErr = String(e); });
tickTimers();
check(chainOk, "setResponseType/setMimeType chain like three.js Loader setters");
check(jsonErr == "", "responseType 'json' reports no error (got '" + jsonErr + "')");
check(jsonValue != null, "responseType 'json' delivers an object, not a String");
check(jsonValue["metadata"]["type"] == "BufferGeometry", "the parsed object is the suzanne geometry JSON");

// 13b. An unsupported responseType reports through onError instead of silently
//      degrading to text (D32).
var flBad:FileLoader = new FileLoader();
flBad.responseType = "document";
var badLoaded:Boolean = false;
var badErrored:Boolean = false;
flBad.load("assets/textures/checker.png",
    function(data:Object):void { badLoaded = true; },
    null,
    function(e:Object):void { badErrored = true; });
tickTimers();
check(badErrored && !badLoaded, "unsupported responseType 'document' reports onError, never onLoad");

// 13c. setRequestHeader is accepted and does not disturb the read (header names
//      are sent by URLRequest.requestHeaders; a file:// read ignores them).
var flHdr:FileLoader = new FileLoader();
var hdrText:String = "";
flHdr.setRequestHeader({"X-Probe":"1", "X-Second":"two"});
flHdr.load("assets/textures/uvgrid.png",
    function(data:Object):void { hdrText = String(data); }, null, null);
tickTimers();
check(hdrText.length > 0, "setRequestHeader does not break the transfer");

// 13d. abort() cancels the in-flight request: neither callback fires.
var flAbort:FileLoader = new FileLoader();
var abortLoaded:Boolean = false;
var abortErrored:Boolean = false;
flAbort.load("assets/textures/checker.png",
    function(data:Object):void { abortLoaded = true; },
    null,
    function(e:Object):void { abortErrored = true; });
flAbort.abort();
tickTimers();
check(!abortLoaded && !abortErrored, "abort() cancels the load (no onLoad, no onError)");
// abort() with nothing in flight is a no-op (three.js semantics), not #2029.
var abortErr:String = "";
try { flAbort.abort(); } catch (err:Error) { abortErr = err.message; }
check(abortErr == "", "a second abort() is a silent no-op (got '" + abortErr + "')");


// ---------------------------------------------------------------------------
// 14. §31 leftovers: L6 LoadingManager, L12 register(), L3
//     KHR_texture_transform, plus the "not borrowed, but stated" items
//     (L7 dedupe / L11 six-face guard / L13 no image progress / image type).
// ---------------------------------------------------------------------------

// 14a. L6: one manager aggregates a batch. onStart fires once (first item),
//      onProgress once per item, onLoad when loaded == total.
var mgr:LoadingManager = new LoadingManager();
var mStart:int = 0, mProg:int = 0, mDone:int = 0;
mgr.onStart = function(u:String, loaded:int, total:int):void { mStart++; };
mgr.onProgress = function(u:String, loaded:int, total:int):void { mProg++; };
mgr.onLoad = function():void { mDone++; };
var flMgr1:FileLoader = new FileLoader(mgr);
var flMgr2:FileLoader = new FileLoader(mgr);
flMgr1.responseType = "arraybuffer";
flMgr2.responseType = "arraybuffer";
flMgr1.load("assets/textures/checker.png", null, null, null);
flMgr2.load("assets/textures/uvgrid.png", null, null, null);
check(mgr.itemsTotal == 2, "LoadingManager counts both itemStart calls (total " + mgr.itemsTotal + ")");
check(mgr.isLoading, "LoadingManager reports loading while items are in flight");
tickTimers();
check(mgr.itemsLoaded == 2, "LoadingManager counts both itemEnd calls (loaded " + mgr.itemsLoaded + ")");
check(mStart == 1, "onStart fires once for the whole batch (got " + mStart + ")");
check(mProg == 2, "onProgress fires per finished item (got " + mProg + ")");
check(mDone == 1, "onLoad fires once when the batch balances (got " + mDone + ")");
check(!mgr.isLoading, "LoadingManager clears isLoading after the batch");

// 14b. L6 error path: itemError names the URL and itemEnd still balances, so a
//      batch with one failure still completes (three.js FileLoader.js:299-318).
var mgrErr:LoadingManager = new LoadingManager();
var errUrls:Array = [];
var errDone:int = 0;
mgrErr.onError = function(u:String):void { errUrls.push(u); };
mgrErr.onLoad = function():void { errDone++; };
var flMgrErr:FileLoader = new FileLoader(mgrErr);
flMgrErr.load("definitely/not/here.bin", null, null, null);
tickTimers();
check(errUrls.length == 1, "itemError fires once for a failed item (got " + errUrls.length + ")");
check(String(errUrls[0]).indexOf("not/here") >= 0, "itemError names the failed URL ('" + errUrls[0] + "')");
check(mgrErr.itemsLoaded == 1 && errDone == 1, "a failed item still balances the batch (loaded " + mgrErr.itemsLoaded + ", done " + errDone + ")");

// 14c. L6 setURLModifier: the hook runs on the path-prefixed URL, before the read.
var mgrUrl:LoadingManager = new LoadingManager();
var seenUrls:Array = [];
mgrUrl.setURLModifier(function(u:String):String
{
    seenUrls.push(u);
    if (u.indexOf("checker.png") >= 0) return u.substr(0, u.length - 11) + "uvgrid.png";
    return u;
});
var flMod:FileLoader = new FileLoader(mgrUrl);
flMod.responseType = "arraybuffer";
var modLen:int = -1;
flMod.load("assets/textures/checker.png", function(d:Object):void { modLen = (d as ByteArray).length; }, null, null);
tickTimers();
check(seenUrls.length == 1 && String(seenUrls[0]) == "assets/textures/checker.png",
    "setURLModifier receives the path-prefixed URL ('" + seenUrls[0] + "')");
check(modLen > 0 && modLen != 1072, "setURLModifier really redirects the read (got " + modLen + " bytes, checker is 1072)");

// 14d. Texture.image is a BitmapData, not a DOM image (registered leftover:
//      ported code that treats texture.image as an element must be rewritten).
check(tex.image is BitmapData, "texture.image is a BitmapData (D16), not an image element");

// 14e. L7 / D161: NO fetch dedupe. The same URL loaded twice concurrently reads
//      twice and hands back two distinct objects (three.js shares one).
var flDup:FileLoader = new FileLoader();
flDup.responseType = "arraybuffer";
var dupA:ByteArray = null, dupB:ByteArray = null;
flDup.load("assets/textures/checker.png", function(d:Object):void { dupA = d as ByteArray; }, null, null);
flDup.load("assets/textures/checker.png", function(d:Object):void { dupB = d as ByteArray; }, null, null);
tickTimers();
check(dupA != null && dupB != null, "both duplicate loads deliver");
check(dupA !== dupB, "no fetch dedupe: each load owns its ByteArray (D161)");
check(dupA.length == dupB.length, "duplicate loads deliver identical content");

// 14f. L11: a cube load with != 6 URLs reports through onError and never hangs.
var cubeUrls:Vector.<String> = new Vector.<String>();
cubeUrls.push("assets/textures/checker.png");
cubeUrls.push("assets/textures/uvgrid.png");
cubeUrls.push("assets/textures/checker.png");
var cubeErr:int = 0, cubeLoaded:int = 0;
var cubeBad:CubeTextureLoader = new CubeTextureLoader();
var cubeObj:CubeTexture = cubeBad.load(cubeUrls,
    function(c:CubeTexture):void { cubeLoaded++; }, null,
    function(e:Object):void { cubeErr++; });
check(cubeObj != null, "CubeTextureLoader still returns the CubeTexture on a bad URL count");
check(cubeErr == 1, "3 face URLs report onError instead of hanging (got " + cubeErr + ")");
check(cubeLoaded == 0, "onLoad never fires for an incomplete cube");

// 14g. L13: ImageLoader decodes with no progress stream, so onProgress is
//      accepted but never called (three.js documents the same).
var progCalls:int = 0;
var imgProg:ImageLoader = new ImageLoader();
imgProg.load("assets/textures/checker.png", null,
    function(e:Object):void { progCalls++; }, null);
tickTimers();
check(progCalls == 0, "ImageLoader never calls onProgress (got " + progCalls + ")");

// 14h. L12: GLTFLoader.register() — a plugin's hooks must fire for a material
//      carrying its extension, and afterRoot must run once per parse.
var pluginMatType:int = 0, pluginExtend:int = 0, pluginRoots:int = 0;
var regLoader:GLTFLoader = new GLTFLoader();
regLoader.register(function(parser:Object):Object
{
    var p:Object = {};
    p["name"] = "KHR_probe_ext";
    p["getMaterialType"] = function(index:int):Material { pluginMatType++; return null; };
    p["extendMaterial"] = function(index:int, material:Material, def:Object):void
    {
        pluginExtend++;
        material.name = "extended-by-plugin";
    };
    p["afterRoot"] = function(root:Object3D):void { pluginRoots++; };
    return p;
});
var pluginJson:String = '{"asset":{"version":"2.0"},' +
    '"scene":0,"scenes":[{"nodes":[0]}],' +
    '"nodes":[{"name":"probe-node"}],' +
    '"materials":[{"name":"probe-mat","extensions":{"KHR_probe_ext":{"v":1}}}]}';
var parseErr:String = "";
function onPluginParsed(root:Object3D):void { }
regLoader.parse(pluginJson, null, onPluginParsed, function(e:Object):void { parseErr = String(e); });
check(parseErr == "", "plugin glTF parses (got '" + parseErr + "')");
check(pluginRoots == 1, "afterRoot hook runs once per parse (got " + pluginRoots + ")");
var pluginMat:Material = regLoader.materialAt(0);
check(pluginMatType == 1, "getMaterialType hook fires for the extended material (got " + pluginMatType + ")");
check(pluginExtend == 1, "extendMaterial hook fires once (got " + pluginExtend + ")");
check(pluginMat != null && pluginMat.name == "extended-by-plugin",
    "the plugin's extendMaterial mutation survives ('" + (pluginMat != null ? pluginMat.name : "null") + "')");

// 14i. L3 KHR_texture_transform: offset/rotation/scale land on the Texture's uv
//      transform, and the transform is PER REFERENCE (the index-cached texture
//      must stay untouched, so the second slot keeps the identity transform).
var ttJson:String = '{"asset":{"version":"2.0"},' +
    '"scene":0,"scenes":[{"nodes":[0]}],' +
    '"nodes":[{"name":"tt"}],' +
    '"materials":[' +
    '{"name":"tt-on","pbrMetallicRoughness":{"baseColorTexture":{"index":0,"extensions":{"KHR_texture_transform":{"offset":[0.25,0.5],"scale":[2,3]}}}}},' +
    '{"name":"tt-off","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],' +
    '"textures":[{"source":0}],' +
    '"images":[{"uri":"assets/textures/checker.png"}]}';
var ttLoader:GLTFLoader = new GLTFLoader();
var ttErr:String = "";
ttLoader.parse(ttJson, null, null, function(e:Object):void { ttErr = String(e); });
check(ttErr == "", "KHR_texture_transform glTF parses (got '" + ttErr + "')");
var ttOn:MeshStandardMaterial = ttLoader.materialAt(0) as MeshStandardMaterial;
var ttOff:MeshStandardMaterial = ttLoader.materialAt(1) as MeshStandardMaterial;
check(ttOn != null && ttOn.map != null, "the transformed slot has a map");
check(ttOn.map.offset.x == 0.25 && ttOn.map.offset.y == 0.5,
    "KHR_texture_transform offset applied (" + ttOn.map.offset.x + "," + ttOn.map.offset.y + ")");
check(ttOn.map.repeat.x == 2 && ttOn.map.repeat.y == 3,
    "KHR_texture_transform scale applied (" + ttOn.map.repeat.x + "," + ttOn.map.repeat.y + ")");
check(ttOff != null && ttOff.map != null && ttOff.map.offset.x == 0 && ttOff.map.repeat.x == 1,
    "the untransformed slot keeps the identity uv transform");
check(ttOn.map !== ttOff.map, "the transform is per reference (clone), not a mutation of the cached texture");

// 14j. D158 also applies to RGBELoader: two loads on one instance must not
//      cross-deliver (the request and callbacks are per-call locals now).
var hdrRacy:RGBELoader = new RGBELoader();
var hdrA:int = 0, hdrB:int = 0;
hdrRacy.load("assets/textures/hdr/studio.hdr",
    function(img:HDRImage):void { hdrA = img.width; }, null, null);
hdrRacy.load("assets/textures/hdr/studio.hdr",
    function(img:HDRImage):void { hdrB = img.width; }, null, null);
tickTimers();
check(hdrA == 512, "concurrent RGBELoader: first callback got its image (width " + hdrA + ")");
check(hdrB == 512, "concurrent RGBELoader: second callback got its image (width " + hdrB + ")");

trace("loader-smoke-m5: all M5 loader assertions passed");
