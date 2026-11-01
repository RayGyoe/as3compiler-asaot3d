// asset-load-probe.as -- M5 hard-gate probe: PNG on disk -> URLLoader(BINARY)
// -> Loader.loadBytes -> Bitmap -> BitmapData -> pixel checks.
//
// This pins the exact chain TextureLoader uses. Skia decode is linked in via
// ASC_USE_SKIA (the probe's build manifest); without that define the runtime
// compiles in a NULL stub and every image reports #2124 "unknown type" -- the
// failure this probe exists to catch. The generated checker/uvgrid/bead-normal
// patterns let pixel values prove the decode, not just the event flow.

function check(cond:Boolean, msg:String):void { if (!cond) throw new Error("FAIL: " + msg); }

var pngPath:String = "assets/textures/checker.png";

// 1. URLLoader BINARY reads the PNG from disk.
var ul:URLLoader = new URLLoader();
ul.dataFormat = URLLoaderDataFormat.BINARY;
var ulDone:Boolean = false;
var ulFailed:Boolean = false;
function onUlComplete(e:Event):void { ulDone = true; }
function onUlError(e:IOErrorEvent):void { ulFailed = true; trace("URLLoader IO_ERROR: " + e.text); }
ul.addEventListener(Event.COMPLETE, onUlComplete);
ul.addEventListener(IOErrorEvent.IO_ERROR, onUlError);
ul.load(new URLRequest(pngPath));
tickTimers();
check(ulDone, "URLLoader(BINARY) completes for " + pngPath);
check(!ulFailed, "URLLoader(BINARY) reports no IO_ERROR");
var bytes:ByteArray = ul.data as ByteArray;
check(bytes != null, "BINARY data is a ByteArray");
check(bytes.length > 100, "PNG byte count plausible (" + bytes.length + ")");

// 2. Loader.loadBytes decodes the PNG into a Bitmap.
// Fully qualified: asaot.three.loaders.Loader is in the same compilation set and
// shadows the built-in name, and only this one has contentLoaderInfo/loadBytes.
var ldr:flash.display.Loader = new flash.display.Loader();
var ldrDone:Boolean = false;
var ldrFailed:Boolean = false;
function onLdrComplete(e:Event):void { ldrDone = true; }
function onLdrError(e:IOErrorEvent):void { ldrFailed = true; trace("Loader IO_ERROR: " + e.text); }
ldr.contentLoaderInfo.addEventListener(LoaderInfo.COMPLETE, onLdrComplete);
ldr.contentLoaderInfo.addEventListener(LoaderInfo.IO_ERROR, onLdrError);
ldr.loadBytes(bytes);
check(ldr.content == null, "content stays null until the terminal event");
tickTimers();
check(ldrDone, "Loader.loadBytes dispatches COMPLETE for a PNG");
check(!ldrFailed, "Loader.loadBytes reports no IO_ERROR for a PNG");
var bmp:Bitmap = ldr.content as Bitmap;
check(bmp != null, "decoded content is a Bitmap");
var bd:BitmapData = bmp.bitmapData;
check(bd != null, "Bitmap carries a BitmapData");
check(bd.width == 256 && bd.height == 256, "decoded size is 256x256 (got " + bd.width + "x" + bd.height + ")");

// 3. Pixels: checker cells 32px, cell (0,0) white, cell (40,0) near-black.
var c00:uint = bd.getPixel32(0, 0);
var c40:uint = bd.getPixel32(40, 0);
check((c00 >> 16 & 0xff) > 200 && (c00 >> 8 & 0xff) > 200 && (c00 & 0xff) > 200,
    "cell (0,0) is white (got 0x" + c00.toString(16) + ")");
check((c40 >> 16 & 0xff) < 64 && (c40 >> 8 & 0xff) < 64 && (c40 & 0xff) < 64,
    "cell (40,0) is near-black (got 0x" + c40.toString(16) + ")");

// 4. RGBA decode: bead-normal.png keeps its RGB payload (alpha 255 everywhere).
var ul2:URLLoader = new URLLoader();
ul2.dataFormat = URLLoaderDataFormat.BINARY;
var ul2Done:Boolean = false;
function onUl2Complete(e:Event):void { ul2Done = true; }
ul2.addEventListener(Event.COMPLETE, onUl2Complete);
ul2.load(new URLRequest("assets/textures/bead-normal.png"));
tickTimers();
check(ul2Done, "second PNG (RGBA) loads");
var ldr2:flash.display.Loader = new flash.display.Loader();
var ldr2Done:Boolean = false;
function onLdr2Complete(e:Event):void { ldr2Done = true; }
ldr2.contentLoaderInfo.addEventListener(LoaderInfo.COMPLETE, onLdr2Complete);
ldr2.loadBytes(ul2.data as ByteArray);
tickTimers();
check(ldr2Done, "RGBA PNG decodes");
var bd2:BitmapData = (ldr2.content as Bitmap).bitmapData;
check(bd2.width == 256 && bd2.height == 256, "RGBA decode size is 256x256");
// Flat area between beads (corner): normal (0,0,1) -> (128,128,255).
var flat:uint = bd2.getPixel32(3, 3);
check((flat >> 16 & 0xff) > 120 && (flat >> 16 & 0xff) < 136, "flat normal R~128 (got " + (flat >> 16 & 0xff) + ")");
check((flat >> 8 & 0xff) > 120 && (flat >> 8 & 0xff) < 136, "flat normal G~128 (got " + (flat >> 8 & 0xff) + ")");
check((flat & 0xff) > 245, "flat normal B~255 (got " + (flat & 0xff) + ")");

// 5. Cross-check: Loader.load(file) — the AS_JOB_IMAGE path — decodes the same
//    PNG, so both decode entry points (file read + in-memory bytes) are pinned.
var ldrF:flash.display.Loader = new flash.display.Loader();
var ldrFDone:Boolean = false;
var ldrFFailText:String = "";
function onLdrFComplete(e:Event):void { ldrFDone = true; }
function onLdrFError(e:IOErrorEvent):void { ldrFFailText = e.text; }
ldrF.contentLoaderInfo.addEventListener(LoaderInfo.COMPLETE, onLdrFComplete);
ldrF.contentLoaderInfo.addEventListener(LoaderInfo.IO_ERROR, onLdrFError);
ldrF.load(new URLRequest(pngPath));
tickTimers();
check(ldrFDone, "Loader.load(file) decodes the same PNG (IO_ERROR: " + ldrFFailText + ")");
var bdF:BitmapData = (ldrF.content as Bitmap).bitmapData;
check(bdF != null && bdF.width == 256, "file-path decode yields 256-wide BitmapData");
check((bdF.getPixel32(0, 0) >> 16 & 0xff) > 200, "file-path decode pixels are white at (0,0)");

trace("asset-load-probe: all image-chain assertions passed");
