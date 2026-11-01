// asaot.three.extras.EquirectangularToCube -- CPU equirect panorama -> cubemap.
//
// three.js does this on the GPU: WebGLCubeRenderTarget.fromEquirectangularTexture
// renders a box from the inside with the `equirect` shader chunk and lets the
// cube framebuffer's mip chain stand in for a PMREM. Here the conversion runs on
// the CPU at load time and the result is a plain 6-face CubeTexture. The reason
// is the CUBE, not float support: a cube texture has no float storage at any
// profile rung -- `rgbaHalfFloat` cubes are accepted and then store 8-bit bytes
// (measured, three-api-design.md §36.2) -- and per-roughness mip levels cannot
// be uploaded either (uploadFromBitmapData drops miplevel > 0, §36.3), so the
// GPU path three.js uses has no destination here. That is the same split the kit
// already uses for CPU skinning (M12/D84) and CPU mip chains (M17).
//
// TWO CONVENTIONS HAVE TO MATCH THE SAMPLER, so they are published here and
// pinned by probes/hdr-smoke-m25 rather than buried:
//
//   * face direction: the D3D/Metal cube convention (the one Stage3D and this
//     backend's `tex <cube>` actually sample with). With u,v in [0,1] and v
//     measured DOWNWARD from the face's top row:
//        +X (1, 1-2v, 2u-1)     -X (-1, 1-2v, 1-2u)
//        +Y (2u-1, 1, 2v-1)     -Y (2u-1, -1, 1-2v)
//        +Z (2u-1, 1-2v, 1)     -Z (1-2u, 1-2v, -1)
//     Face index order is CubeTexture's (+X,-X,+Y,-Y,+Z,-Z), which is also the
//     Stage3D side index, so no re-ordering happens at upload.
//
//   * equirect uv (three.js's equirectUv, WEBGL shader chunk):
//        u = 0.5 + atan2(z, x) / 2pi        (longitude, wraps)
//        v = 0.5 - asin(y) / pi             (latitude, v=0 at +Y)
//     HDRImage stores row 0 at +Y, so v maps straight onto row index.
//
// ENCODING (D154, revised by D177). The cube faces are 8-bit BGRA because that
// is the only texture format this backend has, and 8-bit LINEAR would band the
// darks of a night sky into nothing. So the bake encodes
//
//     texel = srgbOetf(clamp(lin / scale, 0, 1)) * 255
//
// and the cube declares `colorSpace = SRGBColorSpace`, with
// `CubeTexture.hdrScale = scale` multiplying the radiance back up. `scale` is a
// power of two >= 1 (autoScale), which makes the round trip exact apart from the
// 8-bit quantisation itself.
//
// D177: the exponent is the sRGB OETF (12.92x below the knee, then
// 1.055*x^(1/2.4) - 0.055), NOT pow(x, 1/2.2). Every decoder in the renderer
// goes through the exact sRGB EOTF since D170 (the IBL slot via
// srgbDecodeBlock, the HDR background program likewise), so a 1/2.2 encode left
// a systematic ~1.7% darkening at mid tones. The two halves of a transfer
// function are ONE decision.
package asaot.three.extras
{
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.HDRImage;
    import asaot.three.textures.PanoramaSampler;
    import asaot.three.textures.Texture;
    import flash.display.BitmapData;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;

    public class EquirectangularToCube
    {
        // ------------------------------------------------------------ geometry

        // Direction sampled by cube face `face` at face uv (u right, v DOWN).
        public static function faceDirection(face:int, u:Number, v:Number, out:Vector3):void
        {
            var s:Number = u * 2 - 1;    // -1 .. 1, right
            var t:Number = v * 2 - 1;    // -1 .. 1, down
            switch (face)
            {
                case 0: out.set(1, -t, s); break;      // +X
                case 1: out.set(-1, -t, -s); break;    // -X
                case 2: out.set(s, 1, t); break;       // +Y
                case 3: out.set(s, -1, -t); break;     // -Y
                case 4: out.set(s, -t, 1); break;      // +Z
                default: out.set(-s, -t, -1); break;   // -Z
            }
            out.normalize();
        }

        // Equirect uv of a direction (three.js's equirectUv).
        public static function equirectUv(dir:Vector3, out:Vector2):void
        {
            out.x = 0.5 + Math.atan2(dir.z, dir.x) / (2 * Math.PI);
            out.y = 0.5 - Math.asin(dir.y > 1 ? 1 : (dir.y < -1 ? -1 : dir.y)) / Math.PI;
        }

        // ------------------------------------------------------------ scale

        // The radiance divisor that fits the panorama into 8 bits. A power of two
        // (so encode/decode is exact) chosen from the 99.5th percentile of the
        // luminance histogram: the top 0.5% -- a sun disc, a lamp -- is allowed to
        // clip, because a global divisor that kept the sun unobstructed would push
        // the sky into a handful of code values.
        public static function autoScale(img:HDRImage):Number
        {
            if (img == null) return 1.0;
            var bins:int = 256;
            var hist:Vector.<int> = new Vector.<int>(bins, true);
            var total:int = img.width * img.height;
            var px:Vector.<Number> = new Vector.<Number>(3, true);
            var i:int;
            var step:int = total > 262144 ? 4 : 1;   // sample at most ~65k texels
            for (i = 0; i < total; i += step)
            {
                var x:int = i % img.width;
                var y:int = int(i / img.width);
                img.linearAt(x, y, px);
                var lum:Number = 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2];
                var b:int = int(Math.sqrt(lum) * 16);   // sqrt bins: resolution is logarithmic where it matters
                if (b < 0) b = 0;
                if (b > 255) b = 255;
                hist[b]++;
            }
            var samples:int = int(total / step) + ((total % step) != 0 ? 1 : 0);
            var want:int = int(samples * 0.995);
            var acc:int = 0;
            var cut:int = bins - 1;
            for (i = 0; i < bins; i++)
            {
                acc += hist[i];
                if (acc >= want) { cut = i; break; }
            }
            var p:Number = (cut / 16);
            var pctl:Number = p * p;   // undo the sqrt bin
            if (!(pctl > 1.0)) return 1.0;
            // Round UP to a power of two.
            var e:int = int(Math.ceil(Math.log(pctl) / Math.LN2));
            return Math.pow(2, e);
        }

        // ------------------------------------------------------------ bake

        // Raw ARGB texels per face (index = face order, +X first). Kept separate
        // from bakeBitmaps so the whole conversion is testable without a bitmap
        // backend (the probe suite runs without Skia on some harnesses).
        public static function bakeTexels(img:HDRImage, faceSize:int, scale:Number):Vector.<Vector.<uint>>
        {
            if (img == null) throw new Error("EquirectangularToCube.bakeTexels: null HDRImage");
            return EquirectangularToCube.bakeTexelsSampled(img, faceSize, scale);
        }

        // The bake loop itself, against ANY panorama sampler (M25-R1). HDRImage
        // (RGBe bytes) and FloatPanorama (blurred linear floats, the prefilter
        // ladder) both implement PanoramaSampler, so the six-face direction math
        // and the D154 encode exist exactly once.
        public static function bakeTexelsSampled(src:PanoramaSampler, faceSize:int,
                                                 scale:Number):Vector.<Vector.<uint>>
        {
            if (src == null) throw new Error("EquirectangularToCube.bakeTexelsSampled: null sampler");
            if (faceSize <= 0) throw new Error("EquirectangularToCube.bakeTexelsSampled: faceSize must be > 0");
            if (!(scale > 0)) scale = 1.0;

            var faces:Vector.<Vector.<uint>> = new Vector.<Vector.<uint>>(6, true);
            var dir:Vector3 = new Vector3();
            var uv:Vector2 = new Vector2();
            var px:Vector.<Number> = new Vector.<Number>(3, true);
            var invScale:Number = 1.0 / scale;

            var face:int;
            for (face = 0; face < 6; face++)
            {
                var texels:Vector.<uint> = new Vector.<uint>(faceSize * faceSize, true);
                var y:int;
                for (y = 0; y < faceSize; y++)
                {
                    var v:Number = (y + 0.5) / faceSize;
                    var x:int;
                    for (x = 0; x < faceSize; x++)
                    {
                        var u:Number = (x + 0.5) / faceSize;
                        EquirectangularToCube.faceDirection(face, u, v, dir);
                        EquirectangularToCube.equirectUv(dir, uv);
                        src.sampleBilinear(uv.x, uv.y, px);
                        texels[y * faceSize + x] = EquirectangularToCube.encode(px, invScale);
                    }
                }
                faces[face] = texels;
            }
            return faces;
        }

        // The sRGB OETF (IEC 61966-2-1), the exact inverse of the shader's
        // `srgbDecodeBlock` (fc41/fc42 constants):
        //   x <= 0.0031308 -> 12.92 x
        //   else           -> 1.055 x^(1/2.4) - 0.055
        public static function srgbOetf(x:Number):Number
        {
            if (x <= 0) return 0;
            if (x >= 1) return 1;
            return x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055;
        }

        // One texel: radiance -> 8-bit sRGB-encoded ARGB (D154/D177).
        public static function encode(lin:Vector.<Number>, invScale:Number):uint
        {
            var r:Number = lin[0] * invScale;
            var g:Number = lin[1] * invScale;
            var b:Number = lin[2] * invScale;
            r = r <= 0 ? 0 : (r >= 1 ? 1 : EquirectangularToCube.srgbOetf(r));
            g = g <= 0 ? 0 : (g >= 1 ? 1 : EquirectangularToCube.srgbOetf(g));
            b = b <= 0 ? 0 : (b >= 1 ? 1 : EquirectangularToCube.srgbOetf(b));
            var ri:int = int(r * 255 + 0.5);
            var gi:int = int(g * 255 + 0.5);
            var bi:int = int(b * 255 + 0.5);
            if (ri > 255) ri = 255;
            if (gi > 255) gi = 255;
            if (bi > 255) bi = 255;
            return uint(0xFF000000) | (uint(ri) << 16) | (uint(gi) << 8) | uint(bi);
        }

        public static function bakeBitmaps(img:HDRImage, faceSize:int, scale:Number):Vector.<BitmapData>
        {
            var texels:Vector.<Vector.<uint>> = EquirectangularToCube.bakeTexels(img, faceSize, scale);
            return EquirectangularToCube.bitmapsFromTexels(texels, faceSize);
        }

        // Same, from any panorama sampler (M25-R1's prefilter ladder bakes each
        // roughness level from a blurred FloatPanorama).
        public static function bakeBitmapsSampled(src:PanoramaSampler, faceSize:int,
                                                  scale:Number):Vector.<BitmapData>
        {
            return EquirectangularToCube.bitmapsFromTexels(
                EquirectangularToCube.bakeTexelsSampled(src, faceSize, scale), faceSize);
        }

        // ARGB words -> one BitmapData per face.
        public static function bitmapsFromTexels(texels:Vector.<Vector.<uint>>,
                                                 faceSize:int):Vector.<BitmapData>
        {
            var out:Vector.<BitmapData> = new Vector.<BitmapData>(6, true);
            var rect:Rectangle = new Rectangle(0, 0, faceSize, faceSize);
            var px:ByteArray = new ByteArray();
            var face:int;
            for (face = 0; face < 6; face++)
            {
                var bd:BitmapData = new BitmapData(faceSize, faceSize, false, 0xFF000000);
                // setPixels reads 32-bit words off a ByteArray whose CURSOR drives
                // them, in A,R,G,B byte order for the default big endian (see
                // BitmapData_setPixels). Handing it anything else is not a short
                // copy, it is #2030 -- so the pack below is explicit.
                var t:Vector.<uint> = texels[face];
                px.length = 0;
                px.position = 0;
                var k:int;
                var n:int = t.length;
                for (k = 0; k < n; k++)
                {
                    var v:uint = t[k];
                    px.writeByte((v >> 24) & 0xFF);
                    px.writeByte((v >> 16) & 0xFF);
                    px.writeByte((v >> 8) & 0xFF);
                    px.writeByte(v & 0xFF);
                }
                px.position = 0;
                bd.setPixels(rect, px);
                out[face] = bd;
            }
            return out;
        }

        // D154: mark a baked cube as gamma-encoded LINEAR radiance (not sRGB
        // colour), carrying the radiance divisor in hdrScale. Split out from
        // bakeCube so the probe can pin it without a bitmap backend.
        public static function decorate(cube:CubeTexture, scale:Number):CubeTexture
        {
            cube.colorSpace = Texture.SRGBColorSpace;
            cube.hdrScale = scale > 0 ? scale : 1.0;
            cube.needsUpdate = true;
            return cube;
        }

        // Convenience: panorama -> ready-to-bind environment cube. `scale` <= 0
        // asks for autoScale.
        public static function bakeCube(img:HDRImage, faceSize:int, scale:Number = 0):CubeTexture
        {
            var s:Number = scale > 0 ? scale : EquirectangularToCube.autoScale(img);
            return EquirectangularToCube.decorate(
                new CubeTexture(EquirectangularToCube.bakeBitmaps(img, faceSize, s)), s);
        }
    }
}