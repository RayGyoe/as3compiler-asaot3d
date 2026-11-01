// asaot.three.textures.FloatPanorama -- an equirect panorama as linear floats.
//
// M25-R1 needs to BLUR a panorama, and neither storage the kit already has can
// be blurred in place:
//
//   * HDRImage holds RGBe BYTES. Averaging bytes is averaging an encoded
//     quantity (one exponent byte per texel), which is not a physical average at
//     all.
//   * the baked CubeTexture is 8-bit gamma-encoded, and it is the *output* of
//     the bake, not an input to it.
//
// So the prefilter decodes once into this float buffer, blurs (and repeatedly
// halves) it, and bakes every roughness level from the result
// (extras/EnvironmentPrefilter). 512x256 costs 393k doubles = 3 MB -- allocated
// once per bake, not per frame, and dropped when the bake returns.
//
// Row 0 is the TOP of the panorama (+Y pole), the same orientation HDRImage uses,
// so the two samplers are interchangeable at the bake seam (PanoramaSampler).
//
// Two sampling rules, both pinned by probes/hdr-smoke-m25:
//   * `sampleBilinear`  wraps u, clamps v  -- the cube bake's convention
//   * `sampleClamped`   clamps BOTH      -- the vertical blur pass, where
//     wrapping a pole row around to the other pole would be a visible ghost
package asaot.three.textures
{
    public class FloatPanorama implements PanoramaSampler
    {
        public var width:int;
        public var height:int;

        // width * height * 3 linear RGB, row-major, row 0 = top.
        public var data:Vector.<Number>;

        public function FloatPanorama(width:int, height:int)
        {
            if (width <= 0 || height <= 0) throw new Error("FloatPanorama: size must be positive");
            this.width = width;
            this.height = height;
            this.data = new Vector.<Number>(width * height * 3, true);
        }

        // Decode an RGBe panorama (exposure divisor applied exactly like
        // HDRImage.linearAt does, so the float copy and the byte source agree
        // texel for texel -- the probe pins that).
        public static function fromHDRImage(img:HDRImage):FloatPanorama
        {
            if (img == null) throw new Error("FloatPanorama.fromHDRImage: null HDRImage");
            var out:FloatPanorama = new FloatPanorama(img.width, img.height);
            var px:Vector.<Number> = new Vector.<Number>(3, true);
            var d:Vector.<Number> = out.data;
            var w:int = img.width;
            var h:int = img.height;
            var y:int;
            for (y = 0; y < h; y++)
            {
                var row:int = y * w * 3;
                var x:int;
                for (x = 0; x < w; x++)
                {
                    img.linearAt(x, y, px);
                    var i:int = row + x * 3;
                    d[i] = px[0];
                    d[i + 1] = px[1];
                    d[i + 2] = px[2];
                }
            }
            return out;
        }

        public function sampleBilinear(u:Number, v:Number, out:Vector.<Number>):void
        {
            this._bilinear(u, v, out, true);
        }

        public function sampleClamped(u:Number, v:Number, out:Vector.<Number>):void
        {
            this._bilinear(u, v, out, false);
        }

        private function _bilinear(u:Number, v:Number, out:Vector.<Number>, wrapX:Boolean):void
        {
            var w:int = this.width;
            var h:int = this.height;

            if (wrapX) u = u - Math.floor(u);
            else u = u < 0 ? 0 : (u > 1 ? 1 : u);
            if (v < 0) v = 0; else if (v > 1) v = 1;

            var fx:Number = u * w - 0.5;
            var fy:Number = v * h - 0.5;
            var x0:int = Math.floor(fx);
            var y0:int = Math.floor(fy);
            var tx:Number = fx - x0;
            var ty:Number = fy - y0;

            var x1:int = x0 + 1;
            if (wrapX)
            {
                x0 = ((x0 % w) + w) % w;
                x1 = ((x1 % w) + w) % w;
            }
            else
            {
                if (x0 < 0) x0 = 0; else if (x0 > w - 1) x0 = w - 1;
                if (x1 < 0) x1 = 0; else if (x1 > w - 1) x1 = w - 1;
            }
            var yA:int = y0 < 0 ? 0 : (y0 > h - 1 ? h - 1 : y0);
            var yB:int = yA + 1 > h - 1 ? h - 1 : yA + 1;

            var d:Vector.<Number> = this.data;
            var i00:int = (yA * w + x0) * 3;
            var i10:int = (yA * w + x1) * 3;
            var i01:int = (yB * w + x0) * 3;
            var i11:int = (yB * w + x1) * 3;

            var c:int;
            for (c = 0; c < 3; c++)
            {
                var top:Number = d[i00 + c] + (d[i10 + c] - d[i00 + c]) * tx;
                var bottom:Number = d[i01 + c] + (d[i11 + c] - d[i01 + c]) * tx;
                out[c] = top + (bottom - top) * ty;
            }
        }

        // 2x2 box average (with the u axis wrapping), i.e. one octave down. The
        // box is itself a mild low pass, which is why the prefilter reduces
        // resolution before blurring instead of blurring a 512x256 buffer with a
        // 94-pixel Gaussian.
        public function downsample():FloatPanorama
        {
            var nw:int = this.width > 1 ? this.width >> 1 : 1;
            var nh:int = this.height > 1 ? this.height >> 1 : 1;
            var out:FloatPanorama = new FloatPanorama(nw, nh);
            var src:Vector.<Number> = this.data;
            var dst:Vector.<Number> = out.data;
            var w:int = this.width;
            var h:int = this.height;
            var x:int;
            var y:int;
            for (y = 0; y < nh; y++)
            {
                var y0:int = y * 2;
                var y1:int = y0 + 1 > h - 1 ? h - 1 : y0 + 1;
                for (x = 0; x < nw; x++)
                {
                    var x0:int = x * 2;
                    var x1:int = (x0 + 1) % w;
                    var i00:int = (y0 * w + x0) * 3;
                    var i10:int = (y0 * w + x1) * 3;
                    var i01:int = (y1 * w + x0) * 3;
                    var i11:int = (y1 * w + x1) * 3;
                    var o:int = (y * nw + x) * 3;
                    var c:int;
                    for (c = 0; c < 3; c++)
                    {
                        dst[o + c] = 0.25 * (src[i00 + c] + src[i10 + c] + src[i01 + c] + src[i11 + c]);
                    }
                }
            }
            return out;
        }
    }
}