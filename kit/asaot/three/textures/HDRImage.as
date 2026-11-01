// asaot.three.textures.HDRImage -- decoded Radiance RGBE pixels, three.js style.
//
// Borrows the DATA SHAPE of three.js src/loaders/RGBELoader.js (r187) rather
// than its DataTexture wrapper: three.js hands the decoded floats to a
// `DataTexture` with `type = HalfFloatType`. The panorama cannot do that here
// because the DEFAULT build reports `baselineExtended`, whose format set has no
// usable float format (createTexture('rgbaHalfFloat') answers #3759), and more
// importantly because a float CUBE is not available at any rung: a
// `rgbaHalfFloat` cube accepts the upload but stores the same 8-bit bytes
// (measured, `probes/fmt-vtf-m28` A5). The opt-in `standard` rung
// (ASC_S3D_HALF_TEXTURES) does allocate RGBA_HALF_FLOAT 2D textures and render
// targets and preserves values above 1.0 -- but that only helps a 2D HDR
// offscreen pass, never the environment cube, so the panorama stays on the CPU
// and is baked into 8-bit cube faces (EquirectangularToCube). That is the M25
// decision D152 in three-api-design.md 30; the measurement table is 36.
//
// Storage is the RGBe quadruple as read from the file (one byte per channel,
// i.e. four bytes per texel), NOT floats: a 2048x1024 panorama is 2M texels, and
// `Vector.<Number>` would cost 48 MB before any conversion. `linearAt` decodes on
// demand -- the only consumer is the one-time cube bake.
//
// Row 0 is the TOP of the panorama (`-Y` resolution scans top-down; a `+Y` file
// is flipped at decode). That is the orientation EquirectangularToCube assumes
// and the probes pin (`probes/hdr-smoke-m25`).
package asaot.three.textures
{
    import flash.utils.ByteArray;

    public class HDRImage implements PanoramaSampler
    {
        public var width:int;
        public var height:int;

        // width * height * 4 bytes, RGBe quadruples, row 0 = top, x ascending.
        public var rgbe:ByteArray;

        // Radiance `EXPOSURE=` header value (RGBELoader.js keeps it as `header`
        // metadata and divides by it); 1.0 when the file does not say.
        public var exposure:Number;

        public function HDRImage(width:int, height:int)
        {
            this.width = width;
            this.height = height;
            this.rgbe = new ByteArray();
            this.rgbe.length = width * height * 4;
            this.exposure = 1.0;
        }

        public function get isHDRImage():Boolean
        {
            return true;
        }

        // Radiance RGBE -> linear RGB. Same arithmetic as three.js's
        // RGBELoader.js `RGBEByteToRGBFloat`:
        //
        //   scale = 2^(e - 128) / 255
        //   rgb   = (r, g, b) * scale
        //
        // (Radiance's own `colr_color` uses 2^(e-136), i.e. /256; the 0.4%
        // difference is three.js's, and matching the reference numbers matters
        // more than matching Radiance's rounding.) `e == 0` means "black" in the
        // Radiance convention -- the mantissa is meaningless there, so it is not
        // decoded as 2^-128.
        public static function rgbeToLinear(r:int, g:int, b:int, e:int, out:Vector.<Number>):void
        {
            if (e <= 0)
            {
                out[0] = 0;
                out[1] = 0;
                out[2] = 0;
                return;
            }
            var scale:Number = Math.pow(2.0, e - 128.0) / 255.0;
            out[0] = r * scale;
            out[1] = g * scale;
            out[2] = b * scale;
        }

        // Decode one texel into out[0..2]. `exposure` is applied as a divisor so
        // a file that says EXPOSURE=2 (Radiance: "the image is 2x brighter than
        // it looks") lands back on its intended radiance.
        public function linearAt(x:int, y:int, out:Vector.<Number>):void
        {
            var i:int = (y * this.width + x) * 4;
            var bytes:ByteArray = this.rgbe;
            HDRImage.rgbeToLinear(bytes[i] & 0xFF, bytes[i + 1] & 0xFF,
                                  bytes[i + 2] & 0xFF, bytes[i + 3] & 0xFF, out);
            if (this.exposure != 1.0)
            {
                out[0] = out[0] / this.exposure;
                out[1] = out[1] / this.exposure;
                out[2] = out[2] / this.exposure;
            }
        }

        // Bilinear sample at an equirect uv: `u` wraps (the panorama is cyclic in
        // longitude), `v` clamps. uv convention is the one EquirectangularToCube
        // publishes: u = 0.5 + atan2(z, x)/2pi, v = 0.5 - asin(y)/pi, so v = 0 is
        // the +Y pole (row 0) and v = 1 the -Y pole.
        //
        // The taps are decoded individually rather than from a cached float row
        // because the bake reads each panorama texel about 1.6 times (cube area
        // vs panorama area) -- a float cache would cost 48 MB to save 0.6 decodes.
        public function sampleBilinear(u:Number, v:Number, out:Vector.<Number>):void
        {
            var w:int = this.width;
            var h:int = this.height;

            // Wrap u into [0,1) -- a panorama's left and right edges are the same
            // meridian, so the filter wraps instead of clamping (three.js's
            // EquirectangularReflectionMapping relies on RepeatWrapping here).
            u = u - Math.floor(u);

            var fx:Number = u * w - 0.5;
            var fy:Number = v * h - 0.5;
            var x0:int = Math.floor(fx);
            var y0:int = Math.floor(fy);
            var tx:Number = fx - x0;
            var ty:Number = fy - y0;

            var x1:int = x0 + 1;
            x0 = ((x0 % w) + w) % w;
            x1 = ((x1 % w) + w) % w;
            var yA:int = y0 < 0 ? 0 : (y0 > h - 1 ? h - 1 : y0);
            var yB:int = (y0 + 1) < 0 ? 0 : ((y0 + 1) > h - 1 ? h - 1 : (y0 + 1));

            var t:Vector.<Number> = HDRImage._taps;
            this._tap(x0, yA, 0, t);
            this._tap(x1, yA, 3, t);
            this._tap(x0, yB, 6, t);
            this._tap(x1, yB, 9, t);

            var w00:Number = (1 - tx) * (1 - ty);
            var w10:Number = tx * (1 - ty);
            var w01:Number = (1 - tx) * ty;
            var w11:Number = tx * ty;
            out[0] = t[0] * w00 + t[3] * w10 + t[6] * w01 + t[9] * w11;
            out[1] = t[1] * w00 + t[4] * w10 + t[7] * w01 + t[10] * w11;
            out[2] = t[2] * w00 + t[5] * w10 + t[8] * w01 + t[11] * w11;
        }

        private static const _taps:Vector.<Number> = new Vector.<Number>(12, true);

        // Encode one texel with the declared exposure divisor already applied.
        private function _tap(x:int, y:int, at:int, out:Vector.<Number>):void
        {
            var i:int = (y * this.width + x) * 4;
            var bytes:ByteArray = this.rgbe;
            HDRImage.rgbeToLinear(bytes[i] & 0xFF, bytes[i + 1] & 0xFF,
                                  bytes[i + 2] & 0xFF, bytes[i + 3] & 0xFF, HDRImage._scratch);
            var inv:Number = this.exposure != 1.0 ? 1.0 / this.exposure : 1.0;
            out[at] = HDRImage._scratch[0] * inv;
            out[at + 1] = HDRImage._scratch[1] * inv;
            out[at + 2] = HDRImage._scratch[2] * inv;
        }

        private static const _scratch:Vector.<Number> = new Vector.<Number>(3, true);
    }
}