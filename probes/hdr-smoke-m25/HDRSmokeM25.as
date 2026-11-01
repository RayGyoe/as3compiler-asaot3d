// asaot3d/probes/hdr-smoke-m25/HDRSmokeM25.as -- M25 HDR environment smoke.
//
// M25 makes `scene.environment` accept a real HDR panorama: RGBE decode ->
// CPU equirect->cube bake -> hdrScale carried into the environment intensity.
// The GPU side of that is a picture (apps/hdr-m25); what can be pinned here is
// everything that decides what the picture means, and all of it is CPU-side:
//
//   A. RGBE -> linear anchors (three.js RGBELoader's exact arithmetic)
//   B. the file decoder: header, resolution line, flat / new-RLE / old-RLE
//      scanlines, axis flips, and the two loud refusals (D153)
//   C. the equirect<->cube conventions (face directions + equirect uv): a
//      direction-coloured panorama must come back with the axis colours on the
//      matching face centres. This is the one test that catches an inverted
//      v-axis, a swapped face order, or a mirrored longitude.
//   D. the 8-bit encode (D154): gamma-encoded linear radiance, power-of-two
//      divisor, exact round trip
//   E. autoScale: power of two, >= 1, driven by the 99.5th percentile
//   F. renderer-side pure functions + the new defaults
//   G. the .exr decoder (M25-R3): NONE and RLE chunks, the delta predictor +
//      byte de-interleave that OpenEXRCore's RLE/ZIP both apply, and the loud
//      refusals (D168/D169)
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/hdr-smoke-m25/HDRSmokeM25.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/hdr-smoke-m25 --run
import asaot.three.AGALRenderer;
import asaot.three.extras.EquirectangularToCube;
import asaot.three.loaders.EXRLoader;
import asaot.three.loaders.RGBELoader;
import asaot.three.math.Vector2;
import asaot.three.math.Vector3;
import asaot.three.scenes.Scene;
import asaot.three.textures.CubeTexture;
import asaot.three.textures.HDRImage;
import asaot.three.textures.Texture;
import flash.utils.ByteArray;

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
// A. RGBE -> linear
// ---------------------------------------------------------------------------
// three.js RGBELoader.js RGBEByteToRGBFloat: scale = 2^(e-128)/255, rgb = m*scale.
var px:Vector.<Number> = new Vector.<Number>(3, true);

HDRImage.rgbeToLinear(255, 128, 0, 128, px);
check("A1 (255,128,0) at e=128 is (1.0, 0.5019, 0)", near(px[0], 1.0) && near(px[1], 128.0 / 255.0) && px[2] == 0);

HDRImage.rgbeToLinear(128, 0, 0, 127, px);
check("A2 e=127 halves the scale (0.2510 for mantissa 128)", near(px[0], 128.0 * Math.pow(2, -1) / 255.0));

HDRImage.rgbeToLinear(128, 0, 0, 136, px);
check("A3 e=136 is the unbounded end of the 8-bit mantissa (64.0)", near(px[0], 128.0 * 256.0 / 255.0));

HDRImage.rgbeToLinear(255, 255, 255, 0, px);
check("A4 e=0 means black (Radiance convention), NOT 2^-128", px[0] == 0 && px[1] == 0 && px[2] == 0);

// ---------------------------------------------------------------------------
// B. file decode
// ---------------------------------------------------------------------------
function hdrHeader(format:String, res:String):ByteArray
{
    var b:ByteArray = new ByteArray();
    b.writeUTFBytes("#?RADIANCE\n");
    b.writeUTFBytes("FORMAT=" + format + "\n");
    b.writeUTFBytes("\n");
    b.writeUTFBytes(res + "\n");
    return b;
}

function putRgbe(b:ByteArray, r:int, g:int, bl:int, e:int):void
{
    b.writeByte(r); b.writeByte(g); b.writeByte(bl); b.writeByte(e);
}

var loader:RGBELoader = new RGBELoader();

// B1: flat scanlines, 3x2 (width < 8, so new-RLE is not legal).
var f1:ByteArray = hdrHeader("32-bit_rle_rgbe", "-Y 2 +X 3");
putRgbe(f1, 255, 0, 0, 128);
putRgbe(f1, 0, 255, 0, 128);
putRgbe(f1, 0, 0, 255, 128);
putRgbe(f1, 128, 128, 128, 128);
putRgbe(f1, 64, 64, 64, 128);
putRgbe(f1, 32, 32, 32, 128);
var img1:HDRImage = loader.parse(f1);
check("B1 flat 3x2 decodes to 3x2", img1.width == 3 && img1.height == 2);
img1.linearAt(0, 0, px);
check("B2 first scanline texel is 1.0 red", near(px[0], 1.0) && px[1] == 0 && px[2] == 0);
img1.linearAt(2, 1, px);
check("B3 second scanline texel 2 is the dim grey", near(px[0], 32.0 / 255.0));

// B4: "+Y" stores bottom-up, so the decoded row 0 is the file's LAST scanline.
var f2:ByteArray = hdrHeader("32-bit_rle_rgbe", "+Y 2 +X 3");
putRgbe(f2, 0, 255, 0, 128);
putRgbe(f2, 0, 255, 0, 128);
putRgbe(f2, 0, 255, 0, 128);
putRgbe(f2, 0, 0, 255, 128);
putRgbe(f2, 0, 0, 255, 128);
putRgbe(f2, 0, 0, 255, 128);
var img2:HDRImage = loader.parse(f2);
img2.linearAt(0, 0, px);
// Radiance: the resolution line's first axis is the SCANLINE order. "+Y" means
// the first scanline in the file is the BOTTOM row, so the decoded row 0 (the
// top) is the file's LAST scanline -- the blue one.
check("B4a '+Y' puts the file's last scanline in decoded row 0 (blue)", near(px[2], 1.0));
img2.linearAt(0, 1, px);
check("B4b '+Y' leaves the file's first scanline in the bottom row (green)", near(px[1], 1.0));

// B5: "-X" mirrors each scanline.
var f3:ByteArray = hdrHeader("32-bit_rle_rgbe", "-Y 1 -X 3");
putRgbe(f3, 255, 0, 0, 128);
putRgbe(f3, 0, 255, 0, 128);
putRgbe(f3, 0, 0, 255, 128);
var img3:HDRImage = loader.parse(f3);
img3.linearAt(0, 0, px);
check("B5 '-X' puts the file's last texel at x=0", near(px[2], 1.0));

// B6: old-style RLE -- (1,1,1,count) repeats the PREVIOUS texel.
var f4:ByteArray = hdrHeader("32-bit_rle_rgbe", "-Y 1 +X 5");
putRgbe(f4, 255, 0, 0, 128);   // texel 0
putRgbe(f4, 1, 1, 1, 4);       // + 4 copies of texel 0
var img4:HDRImage = loader.parse(f4);
var i4:int;
var allRed:Boolean = true;
for (i4 = 0; i4 < 5; i4++)
{
    img4.linearAt(i4, 0, px);
    if (!near(px[0], 1.0) || px[1] != 0) allRed = false;
}
check("B6 old-style RLE repeats the previous texel 4 times", allRed);

// B7: new-style RLE, one literal run + one repeat run per channel.
var W:int = 16;
var f5:ByteArray = hdrHeader("32-bit_rle_rgbe", "-Y 1 +X " + W);
f5.writeByte(2); f5.writeByte(2); f5.writeByte(0); f5.writeByte(W);
// channel R: 4 literals (10,20,30,40) + a repeat of 12x 99
f5.writeByte(4); f5.writeByte(10); f5.writeByte(20); f5.writeByte(30); f5.writeByte(40);
f5.writeByte(128 + 12); f5.writeByte(99);
// channel G: 16 literals
f5.writeByte(16);
var c:int;
for (c = 0; c < 16; c++) f5.writeByte(c + 1);
// channel B: one repeat of 16x 7
f5.writeByte(128 + 16); f5.writeByte(7);
// channel E: one repeat of 16x 128
f5.writeByte(128 + 16); f5.writeByte(128);
var img5:HDRImage = loader.parse(f5);
img5.linearAt(0, 0, px);
check("B7a new-RLE literal run decodes (R=10/255)", near(px[0], 10.0 / 255.0));
img5.linearAt(3, 0, px);
check("B7b new-RLE literal run ends at texel 3 (R=40/255)", near(px[0], 40.0 / 255.0));
img5.linearAt(4, 0, px);
check("B7c new-RLE repeat run decodes (R=99/255)", near(px[0], 99.0 / 255.0));
img5.linearAt(15, 0, px);
check("B7d repeat run reaches texel 15, G channel literal is 16",
      near(px[0], 99.0 / 255.0) && near(px[1], 16.0 / 255.0) && near(px[2], 7.0 / 255.0));

// B8: EXPOSURE divides (Radiance: the image is N times brighter than it looks).
var f6:ByteArray = new ByteArray();
f6.writeUTFBytes("#?RADIANCE\n");
f6.writeUTFBytes("FORMAT=32-bit_rle_rgbe\n");
f6.writeUTFBytes("EXPOSURE=2.0\n");
f6.writeUTFBytes("\n-Y 1 +X 1\n");
putRgbe(f6, 255, 0, 0, 128);
var img6:HDRImage = loader.parse(f6);
img6.linearAt(0, 0, px);
check("B8 EXPOSURE=2 divides the radiance", near(px[0], 0.5));

// B9/B10: the two loud refusals (D153).
var threw:Boolean = false;
try
{
    var f7:ByteArray = hdrHeader("32-bit_rle_xyze", "-Y 1 +X 1");
    putRgbe(f7, 255, 0, 0, 128);
    loader.parse(f7);
}
catch (e1:Error) { threw = e1.message.indexOf("xyze") >= 0; }
check("B9 32-bit_rle_xyze is refused BY NAME, not decoded as RGB", threw);

threw = false;
try
{
    var f8:ByteArray = new ByteArray();
    f8.writeUTFBytes("P6\n1 1\n255\n");
    loader.parse(f8);
}
catch (e2:Error) { threw = e2.message.indexOf("Radiance") >= 0; }
check("B10 a non-HDR file is refused with the magic in the message", threw);

// ---------------------------------------------------------------------------
// C. equirect <-> cube conventions
// ---------------------------------------------------------------------------
// A panorama coloured by direction itself: linear rgb = 0.5 + 0.5 * dir. Because
// the store is the exact inverse of the lookup, a correct pipeline returns the
// axis colour on each face centre:
//   +X (1,.5,.5)  -X (0,.5,.5)  +Y (.5,1,.5)
//   -Y (.5,0,.5)  +Z (.5,.5,1)  -Z (.5,.5,0)
function directionColouredPanorama(w:int, h:int):HDRImage
{
    var img:HDRImage = new HDRImage(w, h);
    img.exposure = 1.0;
    var x:int, y:int;
    for (y = 0; y < h; y++)
    {
        var lat:Number = (0.5 - (y + 0.5) / h) * Math.PI;      // +pi/2 at the top row
        for (x = 0; x < w; x++)
        {
            var lon:Number = ((x + 0.5) / w - 0.5) * 2 * Math.PI;
            var dx:Number = Math.cos(lat) * Math.cos(lon);
            var dy:Number = Math.sin(lat);
            var dz:Number = Math.cos(lat) * Math.sin(lon);
            var i:int = (y * w + x) * 4;
            img.rgbe[i] = int((0.5 + 0.5 * dx) * 255 + 0.5);
            img.rgbe[i + 1] = int((0.5 + 0.5 * dy) * 255 + 0.5);
            img.rgbe[i + 2] = int((0.5 + 0.5 * dz) * 255 + 0.5);
            img.rgbe[i + 3] = 128;
        }
    }
    return img;
}

var pano:HDRImage = directionColouredPanorama(256, 128);
var FACE:int = 16;
var baked:Vector.<Vector.<uint>> = EquirectangularToCube.bakeTexels(pano, FACE, 1.0);

// Decode one baked texel back to linear radiance (undo D154's gamma encode).
function decodeTexel(argb:uint):Vector.<Number>
{
    var out:Vector.<Number> = new Vector.<Number>(3, true);
    out[0] = Math.pow(((argb >> 16) & 0xFF) / 255.0, 2.2);
    out[1] = Math.pow(((argb >> 8) & 0xFF) / 255.0, 2.2);
    out[2] = Math.pow((argb & 0xFF) / 255.0, 2.2);
    return out;
}

function faceCentre(face:int):Vector.<Number>
{
    var t:int = baked[face][(FACE >> 1) * FACE + (FACE >> 1)];
    return decodeTexel(t);
}

var axisR:Number = 0.5, eps:Number = 0.05;
var fc0:Vector.<Number> = faceCentre(0);
check("C1 +X face centre is red-hot (dir=(1,0,0))",
      near(fc0[0], 1.0, eps) && near(fc0[1], axisR, eps) && near(fc0[2], axisR, eps));
var fc1:Vector.<Number> = faceCentre(1);
check("C2 -X face centre is dark (dir=(-1,0,0))",
      near(fc1[0], 0.0, eps) && near(fc1[1], axisR, eps) && near(fc1[2], axisR, eps));
var fc2:Vector.<Number> = faceCentre(2);
check("C3 +Y face centre is green-hot (dir=(0,1,0))",
      near(fc2[1], 1.0, eps) && near(fc2[0], axisR, eps) && near(fc2[2], axisR, eps));
var fc3:Vector.<Number> = faceCentre(3);
check("C4 -Y face centre is dark green (dir=(0,-1,0))",
      near(fc3[1], 0.0, eps) && near(fc3[0], axisR, eps) && near(fc3[2], axisR, eps));
var fc4:Vector.<Number> = faceCentre(4);
check("C5 +Z face centre is blue-hot (dir=(0,0,1))",
      near(fc4[2], 1.0, eps) && near(fc4[0], axisR, eps) && near(fc4[1], axisR, eps));
var fc5:Vector.<Number> = faceCentre(5);
check("C6 -Z face centre is dark blue (dir=(0,0,-1))",
      near(fc5[2], 0.0, eps) && near(fc5[0], axisR, eps) && near(fc5[1], axisR, eps));

// C7/C8: sample away from the centres too, so a per-face mirror is caught.
// Top-centre of the +Z face has v=0 -> direction (0,1,1)/sqrt2 -> green > 0.5.
var t7:Vector.<Number> = decodeTexel(baked[4][0 * FACE + (FACE >> 1)]);
check("C7 +Z top-centre tilts toward +Y (green above 0.5)", t7[1] > 0.75);
// Left-centre of the +Z face: u=0 -> direction (-1,0,1)/sqrt2 -> red below 0.5.
var t8:Vector.<Number> = decodeTexel(baked[4][(FACE >> 1) * FACE + 0]);
check("C8 +Z left-centre tilts toward -X (red below 0.5)", t8[0] < 0.25);

// C9: the same via the published helpers, so a formula edit cannot pass by
// matching only the bake.
var d:Vector3 = new Vector3();
var uv:Vector2 = new Vector2();
EquirectangularToCube.faceDirection(2, 0.5, 0.5, d);
check("C9a +Y face centre direction is (0,1,0)", near(d.x, 0, 1e-9) && near(d.y, 1, 1e-9) && near(d.z, 0, 1e-9));
EquirectangularToCube.faceDirection(3, 0.5, 0.0, d);
// faceDirection normalises, so the -Y face's top edge is (0,-1,1)/sqrt2.
check("C9b -Y face top edge points at +Z (normalised)", near(d.z, 0.70710678, 1e-6) && near(d.y, -0.70710678, 1e-6));
d.set(0, 1, 0);
EquirectangularToCube.equirectUv(d, uv);
check("C9c equirect uv: the +Y pole is v=0", near(uv.y, 0, 1e-6));
d.set(1, 0, 0);
EquirectangularToCube.equirectUv(d, uv);
check("C9d equirect uv: the +X axis is the panorama centre (u=.5, v=.5)",
      near(uv.x, 0.5, 1e-6) && near(uv.y, 0.5, 1e-6));
d.set(0, 0, 1);
EquirectangularToCube.equirectUv(d, uv);
check("C9e equirect uv: +Z is a quarter turn from +X", near(uv.x, 0.75, 1e-6));

// ---------------------------------------------------------------------------
// D. the 8-bit encode (D154, revised by D177)
// ---------------------------------------------------------------------------
// The storage curve is the sRGB OETF because every decoder in the renderer is
// the exact sRGB EOTF since D170. These pins are the round trip, not the
// authoring formula: if encode and decode stop being inverses, they fail.
var lin:Vector.<Number> = new Vector.<Number>(3, true);
lin[0] = 1.0; lin[1] = 0.25; lin[2] = 0.0;
var enc:uint = EquirectangularToCube.encode(lin, 1.0);
check("D1 encode(1.0, .25, 0) keeps alpha 255", ((enc >> 24) & 0xFF) == 0xFF);
check("D2 encode(1.0) saturates to 255", ((enc >> 16) & 0xFF) == 255);
// The decoder the shader runs: ((c + 0.055) / 1.055) ^ 2.4 (fc41/fc42).
function srgbEotf(c:Number):Number
{
    if (c <= 0) return 0;
    return Math.pow((c + 0.055) / 1.055, 2.4);
}
var rt:Number = srgbEotf(((enc >> 8) & 0xFF) / 255.0);
check("D3 sRGB-encoded 8-bit round-trips 0.25 within one code value",
      near(rt, 0.25, 0.02));

// D177: the encode is the sRGB curve, NOT pow(x, 1/2.2). At mid grey the two
// differ by ~1.7% in linear radiance, which is exactly the systematic error the
// mismatch used to put into every HDR environment term.
check("D3b encode(0.25) is the sRGB OETF value 137, not pow(.25,1/2.2)=135",
      ((enc >> 8) & 0xFF) == 137);
check("D3c the two curves really do differ (guard against a no-op change)",
      Math.abs(Math.pow(0.25, 1.0 / 2.2) * 255 - 135) < 1);
// Below the knee the OETF is linear (12.92x), so dark radiance keeps resolution.
check("D3d the OETF has a linear toe: 0.0005 -> ~2 code values",
      near(EquirectangularToCube.srgbOetf(0.0005), 0.00646, 1e-4));

// encode() takes the RECIPROCAL (the bake precomputes 1/scale).
var enc2:uint = EquirectangularToCube.encode(lin, 1.0 / 4.0);
check("D4 the hdrScale divisor is applied before the encode (1.0/4 -> 0.25)",
      near(srgbEotf(((enc2 >> 16) & 0xFF) / 255.0), 0.25, 0.02));
check("D5 a texel above the divisor clips to 255",
      ((EquirectangularToCube.encode(lin, 1.0 / 0.25) >> 16) & 0xFF) == 255);

// ---------------------------------------------------------------------------
// E. autoScale
// ---------------------------------------------------------------------------
// A flat panorama of one linear value (e=128 keeps the mantissa = v*255).
function flatPanorama(w:int, h:int, v:Number):HDRImage
{
    var img:HDRImage = new HDRImage(w, h);
    var m:int = int(v * 255 + 0.5);
    if (m < 0) m = 0;
    if (m > 255) m = 255;
    var i:int;
    for (i = 0; i < w * h; i++)
    {
        img.rgbe[i * 4] = m;
        img.rgbe[i * 4 + 1] = m;
        img.rgbe[i * 4 + 2] = m;
        img.rgbe[i * 4 + 3] = 128;
    }
    return img;
}

// A flat ~3.1 panorama (mantissa 200 at e=130 is 200*4/255 = 3.137), so the
// 99.5th percentile is 3.137 -> 2^ceil(log2 3.137) = 4.
var bright:HDRImage = new HDRImage(32, 16);
var k:int;
for (k = 0; k < 32 * 16; k++)
{
    bright.rgbe[k * 4] = 200; bright.rgbe[k * 4 + 1] = 200;
    bright.rgbe[k * 4 + 2] = 200; bright.rgbe[k * 4 + 3] = 130;
}
var s1:Number = EquirectangularToCube.autoScale(bright);
check("E1 autoScale rounds UP to a power of two (3.0 -> 4)", near(s1, 4.0, 1e-9));

var dim:HDRImage = new HDRImage(32, 16);
for (k = 0; k < 32 * 16; k++)
{
    dim.rgbe[k * 4] = 20; dim.rgbe[k * 4 + 1] = 20;
    dim.rgbe[k * 4 + 2] = 20; dim.rgbe[k * 4 + 3] = 128;
}
var s2:Number = EquirectangularToCube.autoScale(dim);
check("E2 autoScale never goes below 1 (a dim panorama keeps 1.0)", near(s2, 1.0, 1e-9));

// A panorama that is 99.5% dark and 0.5% blinding: the scale follows the
// PERCENTILE, not the max, so the common case keeps its precision.
var spiky:HDRImage = new HDRImage(64, 32);
var total:int = 64 * 32;
var spikeEvery:int = 200;   // 0.5%
for (k = 0; k < total; k++)
{
    var hi:Boolean = (k % spikeEvery) == 0;
    var m:int = hi ? 255 : 51;
    spiky.rgbe[k * 4] = m; spiky.rgbe[k * 4 + 1] = m;
    spiky.rgbe[k * 4 + 2] = m; spiky.rgbe[k * 4 + 3] = 128;
}
var s3:Number = EquirectangularToCube.autoScale(spiky);
check("E3 autoScale ignores the top 0.5% (dark sky + spikes -> 1.0)", near(s3, 1.0, 1e-9));

// E4: alpha of every baked texel, and the face count/size.
var ts:Vector.<Vector.<uint>> = EquirectangularToCube.bakeTexels(pano, 8, 1.0);
check("E4 bakeTexels returns six 8x8 faces", ts.length == 6 && ts[0].length == 64 && ts[5].length == 64);

// ---------------------------------------------------------------------------
// F. renderer-side pure functions and the new defaults
// ---------------------------------------------------------------------------
var cube:CubeTexture = new CubeTexture();
check("F1 a fresh CubeTexture has hdrScale 1 (the M9 path is untouched)", near(cube.hdrScale, 1.0));
cube.hdrScale = 4.0;

check("F2 envIntensityOf multiplies material x scene x hdrScale",
      near(AGALRenderer.envIntensityOf(2.0, cube, 3.0), 24.0));
check("F3 envIntensityOf is 0 without a cube (the neutral cube case)",
      near(AGALRenderer.envIntensityOf(2.0, null, 3.0), 0.0));
var ldr:CubeTexture = new CubeTexture();
check("F4 an LDR cube leaves the intensity at material x scene",
      near(AGALRenderer.envIntensityOf(1.0, ldr, 1.0), 1.0));
check("F5 a NaN scene intensity degrades to 1 instead of poisoning fc10",
      near(AGALRenderer.envIntensityOf(1.0, ldr, Number.NaN), 1.0));

var sc:Scene = new Scene();
check("F6 Scene.environmentIntensity defaults to 1", near(sc.environmentIntensity, 1.0));
check("F7 Scene.backgroundIntensity defaults to 1", near(sc.backgroundIntensity, 1.0));
check("F8 Scene.backgroundBlurriness defaults to 0", near(sc.backgroundBlurriness, 0.0));
check("F9 BACKGROUND_BLUR_RADIUS is 0.5 rad", near(AGALRenderer.BACKGROUND_BLUR_RADIUS, 0.5));
check("F10 fc3..fc6 are +X, +Z(1/5), +Y and the XZ diagonal(1/9)",
      AGALRenderer.bgTapAxes.length == 16 &&
      AGALRenderer.bgTapAxes[0] == 1 && AGALRenderer.bgTapAxes[5] == 0 &&
      AGALRenderer.bgTapAxes[6] == 1 && near(AGALRenderer.bgTapAxes[7], 0.2, 1e-12) &&
      AGALRenderer.bgTapAxes[9] == 1 && AGALRenderer.bgTapAxes[11] == 0 &&
      near(AGALRenderer.bgTapAxes[12], Math.SQRT1_2, 1e-12) &&
      near(AGALRenderer.bgTapAxes[15], 1.0 / 9.0, 1e-12));

// F10b/F10c (M25-R2): the blur is tiered by TAP COUNT, so the ramp has to be a
// pure function of scene.backgroundBlurriness that a probe can pin without a GPU.
check("F10b blurTapsFor: 0 -> sharp, 0.5 -> 5 taps, above -> 9 taps",
      AGALRenderer.blurTapsFor(0) == 0 &&
      AGALRenderer.blurTapsFor(0.001) == 5 &&
      AGALRenderer.blurTapsFor(AGALRenderer.BACKGROUND_BLUR_WIDE_TIER) == 5 &&
      AGALRenderer.blurTapsFor(0.5000001) == 9 &&
      AGALRenderer.blurTapsFor(1) == 9);
check("F10c a negative/NaN blurriness falls back to the sharp program",
      AGALRenderer.blurTapsFor(-1) == 0 && AGALRenderer.blurTapsFor(Number.NaN) == 0);

// F11/F12: an HDR bake declares the decode bit and carries the divisor.
// (decorate() instead of bakeCube() so this runs without a bitmap backend;
// apps/hdr-m25 exercises the BitmapData leg.)
var bake:CubeTexture = EquirectangularToCube.decorate(new CubeTexture(), 4.0);
check("F11 a baked cube is marked sRGB-decoded", bake.colorSpace == Texture.SRGBColorSpace);
check("F12 a baked cube carries the divisor in hdrScale", near(bake.hdrScale, 4.0));
check("F13 a non-positive divisor degrades to 1", near(EquirectangularToCube.decorate(new CubeTexture(), 0).hdrScale, 1.0));

// ---------------------------------------------------------------------------
// G. EXR (M25-R3)
// ---------------------------------------------------------------------------
// Two tiny 4x2 files are assembled here rather than shipped as bytes: the
// loader takes a ByteArray, and a 4x2 image makes every assertion exact. The
// writer below mirrors tools/gen-exr.js, whose 256x128 output is cross-checked
// against OpenCV and ffmpeg -- those are the third-party readers that caught the
// missing reorder_and_predict (see EXRLoader's RLE comment).
function exrPutCStr(b:ByteArray, v:String):void
{
    var i:int;
    for (i = 0; i < v.length; i++) b.writeByte(v.charCodeAt(i) & 0xFF);
    b.writeByte(0);
}

function exrPutI32(b:ByteArray, v:int):void
{
    // little endian, always: every integer field in an EXR is little endian and
    // the probe's ByteArray defaults to big.
    b.writeByte(v & 0xFF);
    b.writeByte((v >> 8) & 0xFF);
    b.writeByte((v >> 16) & 0xFF);
    b.writeByte((v >> 24) & 0xFF);
}

function exrPutAttr(b:ByteArray, name:String, type:String, payload:ByteArray):void
{
    exrPutCStr(b, name);
    exrPutCStr(b, type);
    exrPutI32(b, payload.length);
    b.writeBytes(payload);
}

// IEEE 754 binary16 encoder (round to nearest even), the same arithmetic
// tools/gen-exr.js uses. Kept here so the probe owns both directions of the trip.
function exrHalfOf(v:Number):int
{
    if (v == 0) return 0;
    var sign:int = (v < 0) ? 0x8000 : 0;
    var a:Number = Math.abs(v);
    var e:int = Math.floor(Math.log(a) / Math.LN2);
    if (e < -14)
    {
        var mDen:int = int(Math.round(a / Math.pow(2.0, -24.0)));
        if (mDen > 1023) mDen = 1023;
        return sign | mDen;
    }
    if (e > 15) return sign | 0x7C00;
    var mant:int = int(Math.round((a / Math.pow(2.0, e) - 1.0) * 1024.0));
    if (mant >= 1024) { mant = 0; e++; }
    if (e > 15) return sign | 0x7C00;
    return sign | ((e + 15) << 10) | mant;
}

function exrHalfBytes(b:ByteArray, v:Number):void
{
    // Only the values this probe uses: exact halves of small positive numbers.
    var h:int = exrHalfOf(v);
    b.writeByte(h & 0xFF);
    b.writeByte((h >> 8) & 0xFF);
}

function exrChlist(includeR:Boolean):ByteArray
{
    var b:ByteArray = new ByteArray();
    var names:Array = includeR ? ["B", "G", "R"] : ["B", "G"];
    var i:int;
    for (i = 0; i < names.length; i++)
    {
        exrPutCStr(b, String(names[i]));
        exrPutI32(b, 1);            // HALF
        b.writeByte(0);             // pLinear
        b.writeByte(0); b.writeByte(0); b.writeByte(0);
        exrPutI32(b, 1);            // xSampling
        exrPutI32(b, 1);            // ySampling
    }
    b.writeByte(0);
    return b;
}

var EXR_W:int = 4;
var EXR_H:int = 2;

// Sizes are recorded so a test can prove the RLE branch was actually taken: a
// 4x2 gradient packs larger than it started and OpenEXR then stores it raw, which
// would make "RLE decodes identically" a vacuous assertion.
var exrLastRawLen:int = 0;
var exrLastBodyLen:int = 0;

function exrPixel(x:int, y:int, flat:Boolean = false):Vector.<Number>
{
    var out:Vector.<Number> = new Vector.<Number>(3, true);
    if (flat)
    {
        out[0] = 0.5; out[1] = 1.0; out[2] = 2.0;
        return out;
    }
    out[0] = (x + 1) / 8.0 + y * 0.25;      // R
    out[1] = (x + 1) / 4.0 + y * 0.5;       // G
    out[2] = (x + 1) / 2.0 + y;             // B
    return out;
}

// Delta + even/odd byte split, i.e. OpenEXRCore's reorder_and_predict().
function exrPredict(src:ByteArray, n:int):ByteArray
{
    var t:ByteArray = new ByteArray();
    t.length = n;
    var a:int = 0;
    var b:int = (n + 1) >> 1;
    var i:int;
    for (i = 0; i < n; i++)
    {
        if ((i & 1) == 0) { t[a] = src[i]; a++; }
        else { t[b] = src[i]; b++; }
    }
    var p:int = t[0] & 0xFF;
    for (i = 1; i < n; i++)
    {
        var cur:int = t[i] & 0xFF;
        t[i] = (cur - p + 128 + 256) & 0xFF;
        p = cur;
    }
    return t;
}

function exrRle(src:ByteArray):ByteArray
{
    var n:int = src.length;
    var out:ByteArray = new ByteArray();
    var i:int = 0;
    while (i < n)
    {
        var run:int = 1;
        while (i + run < n && src[i + run] == src[i] && run < 128) run++;
        if (run >= 3)
        {
            out.writeByte(run - 1);
            out.writeByte(src[i] & 0xFF);
            i += run;
            continue;
        }
        var start:int = i;
        var count:int = 0;
        while (i < n && count < 127)
        {
            var r:int = 1;
            while (i + r < n && src[i + r] == src[i] && r < 3) r++;
            if (r >= 3) break;
            i++;
            count++;
        }
        out.writeByte((256 - count) & 0xFF);
        var k:int;
        for (k = start; k < start + count; k++) out.writeByte(src[k] & 0xFF);
    }
    return out;
}

// compression: 0 = NONE, 1 = RLE. `tiled` / `zip` / `uint` / `noR` bend the
// header so the refusals can be pinned.
function buildExr(compression:int, noR:Boolean = false, uintChannel:Boolean = false,
                  tiled:Boolean = false, flat:Boolean = false):ByteArray
{
    var out:ByteArray = new ByteArray();
    exrPutI32(out, EXRLoader.MAGIC);
    exrPutI32(out, 2 | (tiled ? 0x200 : 0));    // version 2, scanline (or tiled)

    var chl:ByteArray = exrChlist(!noR);
    if (uintChannel)
    {
        // rewrite the first channel's pixelType to UINT (0)
        var at:int = 2;                          // past the "B" name and its terminator
        chl[at] = 0; chl[at + 1] = 0; chl[at + 2] = 0; chl[at + 3] = 0;
    }
    exrPutAttr(out, "channels", "chlist", chl);
    var comp:ByteArray = new ByteArray();
    comp.writeByte(compression);
    exrPutAttr(out, "compression", "compression", comp);
    var dw:ByteArray = new ByteArray();
    exrPutI32(dw, 0); exrPutI32(dw, 0);
    exrPutI32(dw, EXR_W - 1); exrPutI32(dw, EXR_H - 1);
    exrPutAttr(out, "dataWindow", "box2i", dw);
    var lo:ByteArray = new ByteArray();
    lo.writeByte(0);                             // INCREASING_Y
    exrPutAttr(out, "lineOrder", "lineOrder", lo);
    out.writeByte(0);                            // end of header

    // chunk bodies
    var bodies:Array = [];
    var y:int;
    for (y = 0; y < EXR_H; y++)
    {
        var raw:ByteArray = new ByteArray();
        var c:int;
        var order:Array = noR ? [2, 1] : [2, 1, 0];    // B, G, R
        for (c = 0; c < order.length; c++)
        {
            var x:int;
            for (x = 0; x < EXR_W; x++)
            {
                exrHalfBytes(raw, exrPixel(x, y, flat)[int(order[c])]);
            }
        }
        var body:ByteArray = raw;
        if (compression == EXRLoader.COMPRESSION_RLE)
        {
            var packed:ByteArray = exrRle(exrPredict(raw, raw.length));
            // OpenEXR stores the chunk RAW when packing does not shrink it.
            if (packed.length < raw.length) body = packed;
            if (y == 0)
            {
                exrLastRawLen = raw.length;
                exrLastBodyLen = body.length;
            }
        }
        bodies.push(body);
    }

    var headerEnd:int = out.length + EXR_H * 8;
    var at2:int = headerEnd;
    var offsets:Vector.<int> = new Vector.<int>(EXR_H, true);
    for (y = 0; y < EXR_H; y++)
    {
        offsets[y] = at2;
        at2 += 8 + (bodies[y] as ByteArray).length;
    }
    for (y = 0; y < EXR_H; y++)
    {
        // 64-bit offset, high word zero for a small file
        exrPutI32(out, int(offsets[y]));
        exrPutI32(out, 0);
    }
    for (y = 0; y < EXR_H; y++)
    {
        var bb:ByteArray = bodies[y] as ByteArray;
        exrPutI32(out, y);
        exrPutI32(out, bb.length);
        out.writeBytes(bb);
    }
    return out;
}

var exrLoader:EXRLoader = new EXRLoader();
var imgNone:HDRImage = exrLoader.parse(buildExr(EXRLoader.COMPRESSION_NONE));
check("G1 an uncompressed EXR decodes to its dataWindow size",
      imgNone.width == EXR_W && imgNone.height == EXR_H);

var linE:Vector.<Number> = new Vector.<Number>(3, true);
var exrOk:Boolean = true;
var exrMaxErr:Number = 0;
var yy:int;
for (yy = 0; yy < EXR_H; yy++)
{
    var xx:int;
    for (xx = 0; xx < EXR_W; xx++)
    {
        imgNone.linearAt(xx, yy, linE);
        var want:Vector.<Number> = exrPixel(xx, yy);
        var ch:int;
        for (ch = 0; ch < 3; ch++)
        {
            var rel:Number = Math.abs(linE[ch] - want[ch]) / want[ch];
            if (rel > exrMaxErr) exrMaxErr = rel;
            if (rel > 0.01) exrOk = false;
        }
    }
}
check("G2 every EXR texel survives the half -> RGBE trip within 1%" + " (max " + exrMaxErr.toPrecision(3) + ")", exrOk);

// G3: the RLE chunk must decode to the SAME pixels as the flat one. This is the
// assertion that would have caught the missing reorder_and_predict: without it
// the decoder still "works", it just returns noise. Flat pixels are used so the
// chunk really is packed (asserted right below), otherwise OpenEXR's
// "store raw when packing does not help" rule makes this vacuous.
var imgRleBytes:ByteArray = buildExr(EXRLoader.COMPRESSION_RLE, false, false, false, true);
check("G3a the RLE chunk is actually smaller than the scanline ("
      + exrLastBodyLen + " < " + exrLastRawLen + ")", exrLastBodyLen < exrLastRawLen);
var imgRle:HDRImage = exrLoader.parse(imgRleBytes);
var imgFlat:HDRImage = exrLoader.parse(buildExr(EXRLoader.COMPRESSION_NONE, false, false, false, true));
var rleSame:Boolean = imgRle.width == EXR_W && imgRle.height == EXR_H
                      && imgFlat.width == EXR_W && imgFlat.height == EXR_H;
for (yy = 0; yy < EXR_H; yy++)
{
    for (xx = 0; xx < EXR_W; xx++)
    {
        var a1:Vector.<Number> = new Vector.<Number>(3, true);
        var a2:Vector.<Number> = new Vector.<Number>(3, true);
        imgFlat.linearAt(xx, yy, a1);
        imgRle.linearAt(xx, yy, a2);
        if (a1[0] != a2[0] || a1[1] != a2[1] || a1[2] != a2[2]) rleSame = false;
    }
}
check("G3 an RLE chunk (delta predicate + byte split) decodes identically to NONE", rleSame);

// G4: half edge cases the file formats actually rely on.
check("G4 halfToNumber: 1.0, denormal, +Inf and 0",
      near(EXRLoader.halfToNumber(0x3C00), 1.0, 1e-12) &&
      near(EXRLoader.halfToNumber(0x0001), Math.pow(2.0, -24.0), 1e-20) &&
      EXRLoader.halfToNumber(0x7C00) == Number.POSITIVE_INFINITY &&
      EXRLoader.halfToNumber(0) == 0);

// G5/G6/G7/G8: the refusals are part of the contract (D168/D169).
var exrMsg:String = "";
try { exrLoader.parse(buildExr(3)); } catch (err:Error) { exrMsg = err.message; }
check("G5 ZIP compression is refused by name" + " (" + exrMsg + ")",
      exrMsg.indexOf("ZIP") >= 0 && exrMsg.indexOf("code 3") >= 0);

exrMsg = "";
try { exrLoader.parse(buildExr(0, false, true)); } catch (err:Error) { exrMsg = err.message; }
check("G6 a UINT channel is refused as an id/mask, not radiance", exrMsg.indexOf("UINT") >= 0);

exrMsg = "";
try { exrLoader.parse(buildExr(0, false, false, true)); } catch (err:Error) { exrMsg = err.message; }
check("G7 a tiled file is refused by name", exrMsg.indexOf("tiled") >= 0);

exrMsg = "";
try
{
    var junk:ByteArray = new ByteArray();
    exrPutI32(junk, 0x12345678);
    exrPutI32(junk, 2);
    exrLoader.parse(junk);
}
catch (err2:Error) { exrMsg = err2.message; }
check("G8 a wrong magic number is named in the error", exrMsg.indexOf("not an OpenEXR") >= 0);

exrMsg = "";
try { exrLoader.parse(buildExr(0, true)); } catch (err3:Error) { exrMsg = err3.message; }
check("G9 a file without R/G/B channels says which channels it found",
      exrMsg.indexOf("no R/G/B channels") >= 0);

// G10: the RGBE encoder used for EXR samples round-trips to the same tolerance
// the .hdr path does.
var rgbeBuf:ByteArray = new ByteArray();
rgbeBuf.length = 4;
EXRLoader.linearToRGBE(0.25, 1.5, 12.0, rgbeBuf, 0);
var back:Vector.<Number> = new Vector.<Number>(3, true);
HDRImage.rgbeToLinear(rgbeBuf[0] & 0xFF, rgbeBuf[1] & 0xFF, rgbeBuf[2] & 0xFF, rgbeBuf[3] & 0xFF, back);
check("G10 linearToRGBE round-trips within 1/255",
      Math.abs(back[0] - 0.25) < 0.004 && Math.abs(back[1] - 1.5) < 0.01 && Math.abs(back[2] - 12.0) < 0.05);

if (failed == 0) trace("ALL PASS");
else trace("FAILED " + failed);