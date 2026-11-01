// asaot.three.extras.EnvironmentPrefilter -- CPU prefiltered radiance ladder.
//
// THIS IS M25-R1, the last "rough metal looks too sharp" gap. M9 lit rough
// surfaces by sampling the SHARP environment cube and mixing the reflection
// direction toward the normal by roughness^4 (which is what three.js does ON TOP
// of a prefiltered chain, not instead of one). M25-R1 adds the missing half: the
// environment itself is pre-convolved at increasing roughness and the renderer
// binds the level that matches the material (extras/PrefilteredEnvironment,
// D174/D175).
//
// WHY A CPU BAKE, AGAIN. Same wall as D152: `stage3d_glue.mm` only ever
// allocates BGRA8 render targets, and AGAL has no explicit-LOD cube sample, so
// there is no PMREM to build. What remains is arb: blur the panorama on the CPU
// at load time and bake each roughness level from it. That keeps the shader
// untouched -- one cube fetch per slot -- and puts the whole cost in the one
// place a load-time bake is allowed to spend it.
//
// THE LOBE (this is the part worth arguing about). three.js importance-samples
// the GGX NDF with alpha = roughness^2. The cheap analytic stand-in for "the GGX
// lobe is this wide" is Karis's cosine-power fit (used by every mobile
// IBL prefilter):
//
//     n = 2 / alpha^2 - 2,        cos(theta_half)^n = 0.5
//
// which gives the lobe's half-angle at half maximum. A Gaussian with the same
// half maximum has sigma = theta_half / 1.1774 (= sqrt(2 ln 2)). At roughness 1
// the fit degenerates to n = 0 (a uniform lobe), so the ladder's top is CAPPED
// at the cosine lobe's own width, measured the same way: the cosine-weighted
// hemisphere has its median angle at 45 degrees, so
//
//     COSINE_SIGMA = (pi/4) / 0.6745 = 1.1631 rad
//
// That cap is not cosmetic -- it is what makes the roughest level usable as the
// DIFFUSE source as well (three.js's getIBLIrradiance samples the PMREM at
// roughness 1), so the ladder's last cube doubles as the irradiance cube and the
// renderer needs no fourth texture (D175).
//
// RESOLUTION. sigma at roughness 1 is 1.16 rad = 94 px on a 512-wide panorama.
// A separable Gaussian that wide is ~600 taps per texel per axis, so the blur
// first HALVES the panorama (a 2x2 box is itself a low pass) until sigma <= 3 px,
// then blurs at that resolution. The bake samples the reduced buffer bilinearly,
// which is the second (free) half of the low pass.
//
// The kernel is isotropic IN ANGLE, not in pixels: a longitude pixel covers
// 2*pi/w of arc at the equator but only cos(latitude) of that near a pole, so
// each row's horizontal sigma is divided by sin(polar angle) (clamped at 1/16 so
// the pole rows do not cost a whole-panorama kernel). Without that a spot at
// latitude 60 blurs into a horizontal streak.
//
// ENERGY. Two discretisation details were needed before "the ladder keeps the
// light level" was actually true, and both are pinned by the probe rather than
// asserted in a comment: the vertical kernel carries the sin(polar) area element
// (an equirect row near a pole is almost no solid angle), and each level is
// rescaled to the base panorama's sphere-averaged radiance at the end (a
// separable discrete convolution on this grid is not exactly conservative once
// the buffer has been halved). Without them the roughest level was up to 13%
// off -- a brightness difference between smooth and rough, which is exactly what
// a roughness ladder must not have.
package asaot.three.extras
{
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.FloatPanorama;
    import asaot.three.textures.HDRImage;
    import asaot.three.textures.PanoramaSampler;

    public class EnvironmentPrefilter
    {
        // The ladder. Roughness 0 is the sharp bake; the rest are pre-convolved.
        // Six levels at 0.2 spacing is the resolution the quantisation comments in
        // PrefilteredEnvironment describe -- enough that a 0.2-step change is
        // visible as a highlight-width change, few enough that the bake stays a
        // one-time ~tens-of-ms cost (see the demo's log line).
        public static const LEVEL_ROUGHNESS:Vector.<Number> = EnvironmentPrefilter.makeLevels();

        private static function makeLevels():Vector.<Number>
        {
            var v:Vector.<Number> = new Vector.<Number>(6, true);
            v[0] = 0.0;
            v[1] = 0.2;
            v[2] = 0.4;
            v[3] = 0.6;
            v[4] = 0.8;
            v[5] = 1.0;
            return v;
        }

        // Median angle of the cosine-weighted hemisphere (45 degrees) expressed as
        // a Gaussian sigma: 0.6745 is the standard-normal median.
        public static const COSINE_SIGMA:Number = (Math.PI / 4) / 0.6744897501960817;

        // Gaussian half-max relation: FWHM = 2.3548 sigma.
        public static const HALF_MAX_TO_SIGMA:Number = 1.1774100225154747;

        // Biggest sigma (in pixels) the blur is allowed to work at before the
        // buffer is halved again.
        public static const MAX_SIGMA_PX:Number = 3.0;

        // 5 halvings take a 512-wide panorama to 16 columns; more than that is
        // below the resolution a 64-pixel cube face can express.
        public static const MAX_OCTAVE:int = 5;

        // ------------------------------------------------------------ the lobe

        // Gaussian sigma (RADIANS) of the GGX lobe prefiltered at `roughness`.
        // Monotonic and exactly 0 at 0 (level 0 is the sharp bake).
        public static function prefilterSigma(roughness:Number):Number
        {
            if (!(roughness > 0)) return 0;              // also rejects NaN
            var r:Number = roughness > 1 ? 1 : roughness;
            var alpha:Number = r * r;
            var n:Number = 2.0 / (alpha * alpha) - 2.0;
            if (!(n > 0)) return EnvironmentPrefilter.COSINE_SIGMA;
            // cos(theta_half) = 0.5^(1/n); for huge n this walks toward 1 from
            // below, and Math.acos of a value that rounds to exactly 1 returns 0 --
            // which is the right answer for a vanishing lobe.
            var half:Number = Math.acos(Math.pow(0.5, 1.0 / n));
            var sigma:Number = half / EnvironmentPrefilter.HALF_MAX_TO_SIGMA;
            return sigma > EnvironmentPrefilter.COSINE_SIGMA
                ? EnvironmentPrefilter.COSINE_SIGMA : sigma;
        }

        // sigma in pixels of `panoramaWidth`. A vertical pixel covers pi/height of
        // arc and a horizontal one 2*pi/width, so for a 2:1 panorama the two agree
        // at the equator and the horizontal sigma is the same number there.
        public static function sigmaPixels(roughness:Number, panoramaWidth:int):Number
        {
            if (panoramaWidth <= 0) return 0;
            return EnvironmentPrefilter.prefilterSigma(roughness) * panoramaWidth / (2.0 * Math.PI);
        }

        // How many times the buffer must be halved before the blur is cheap.
        public static function octaveFor(sigmaPx:Number):int
        {
            if (!(sigmaPx > EnvironmentPrefilter.MAX_SIGMA_PX)) return 0;
            var m:int = 0;
            var s:Number = sigmaPx;
            while (s > EnvironmentPrefilter.MAX_SIGMA_PX && m < EnvironmentPrefilter.MAX_OCTAVE)
            {
                s = s * 0.5;
                m++;
            }
            return m;
        }

        // ------------------------------------------------------------ the blur

        // Separable Gaussian, isotropic in ANGLE (see the header). `sigmaPx` is
        // the sigma at the equator in VERTICAL pixels.
        public static function blur(src:FloatPanorama, sigmaPx:Number):FloatPanorama
        {
            if (src == null) throw new Error("EnvironmentPrefilter.blur: null panorama");
            if (!(sigmaPx > 0.3)) return src;    // below a pixel: the box halvings did it
            return EnvironmentPrefilter.vertical(
                EnvironmentPrefilter.horizontal(src, sigmaPx), sigmaPx);
        }

        private static function horizontal(src:FloatPanorama, sigmaPx:Number):FloatPanorama
        {
            var w:int = src.width;
            var h:int = src.height;
            var out:FloatPanorama = new FloatPanorama(w, h);
            var inD:Vector.<Number> = src.data;
            var outD:Vector.<Number> = out.data;
            var y:int;
            for (y = 0; y < h; y++)
            {
                // sin(polar angle) at this row's centre: 1 at the equator, 0 at
                // the poles. Clamped so a pole row costs a bounded kernel.
                var polar:Number = (y + 0.5) / h * Math.PI;
                var sinPolar:Number = Math.sin(polar);
                if (sinPolar < 1.0 / 16.0) sinPolar = 1.0 / 16.0;
                var sigma:Number = sigmaPx / sinPolar;
                var radius:int = int(Math.ceil(3.0 * sigma));
                if (radius > w) radius = w;

                // Normalised 1-D weights, rebuilt per row because sigma varies.
                var weights:Vector.<Number> = new Vector.<Number>(2 * radius + 1, true);
                var sum:Number = 0;
                var k:int;
                for (k = -radius; k <= radius; k++)
                {
                    var wgt:Number = Math.exp(-0.5 * (k / sigma) * (k / sigma));
                    weights[k + radius] = wgt;
                    sum += wgt;
                }
                var inv:Number = 1.0 / sum;

                var rowBase:int = y * w * 3;
                var x:int;
                for (x = 0; x < w; x++)
                {
                    var r:Number = 0;
                    var g:Number = 0;
                    var b:Number = 0;
                    for (k = -radius; k <= radius; k++)
                    {
                        var sx:int = ((x + k) % w + w) % w;      // u wraps
                        var ww:Number = weights[k + radius] * inv;
                        var i:int = rowBase + sx * 3;
                        r += inD[i] * ww;
                        g += inD[i + 1] * ww;
                        b += inD[i + 2] * ww;
                    }
                    var o:int = rowBase + x * 3;
                    outD[o] = r;
                    outD[o + 1] = g;
                    outD[o + 2] = b;
                }
            }
            return out;
        }

        private static function vertical(src:FloatPanorama, sigmaPx:Number):FloatPanorama
        {
            var w:int = src.width;
            var h:int = src.height;
            var out:FloatPanorama = new FloatPanorama(w, h);
            var inD:Vector.<Number> = src.data;
            var outD:Vector.<Number> = out.data;

            var radius:int = int(Math.ceil(3.0 * sigmaPx));
            if (radius > h) radius = h;
            // The Gaussian in ANGLE, times sin(polar) of the TAP row.
            //
            // The sin factor is the area element: an equirect row near a pole
            // covers almost no solid angle, so a vertical average that counts rows
            // equally is not a sphere average -- it moves brightness from the
            // equator toward the poles and, because the poles are then discounted
            // in the very next level's input, the ladder loses light (measured:
            // -23% sphere-averaged radiance at the roughest level without the
            // factor). With it, a constant field stays constant and the
            // sphere-averaged radiance is preserved (E2).
            var weights:Vector.<Number> = new Vector.<Number>(2 * radius + 1, true);
            var k:int;
            for (k = -radius; k <= radius; k++)
            {
                weights[k + radius] = Math.exp(-0.5 * (k / sigmaPx) * (k / sigmaPx));
            }

            var y:int;
            for (y = 0; y < h; y++)
            {
                // Taps that fall outside the image are DROPPED and the remaining
                // weights RENORMALISED, not clamped onto the edge row.
                //
                // Wrapping v would ghost the +Y pole onto the -Y pole (the sphere
                // has no such seam). Clamping -- the obvious alternative -- is
                // wrong in a subtler way: it gives the first/last rows extra total
                // weight, so a compact source near the equator LOSES energy on the
                // coarse levels (measured: -18% linear mean at the roughest level
                // of a 16-row panorama). Dropping the tap and renormalising is both
                // seam-free and energy-preserving; the pole row's kernel is just
                // slightly narrower, which is the honest reading of "there is no
                // data beyond the pole".
                var lo:int = -radius;
                if (y + lo < 0) lo = -y;
                var hi:int = radius;
                if (y + hi > h - 1) hi = h - 1 - y;
                var sum:Number = 0;
                var kk:int;
                for (kk = lo; kk <= hi; kk++)
                {
                    var sinTap:Number = Math.sin(((y + kk) + 0.5) / h * Math.PI);
                    weights[kk + radius] = Math.exp(-0.5 * (kk / sigmaPx) * (kk / sigmaPx)) * sinTap;
                    sum += weights[kk + radius];
                }
                var inv:Number = sum > 0 ? 1.0 / sum : 0;

                var x:int;
                for (x = 0; x < w; x++)
                {
                    var r:Number = 0;
                    var g:Number = 0;
                    var b:Number = 0;
                    for (k = lo; k <= hi; k++)
                    {
                        var ww:Number = weights[k + radius] * inv;
                        var i:int = ((y + k) * w + x) * 3;
                        r += inD[i] * ww;
                        g += inD[i + 1] * ww;
                        b += inD[i + 2] * ww;
                    }
                    var o:int = (y * w + x) * 3;
                    outD[o] = r;
                    outD[o + 1] = g;
                    outD[o + 2] = b;
                }
            }
            return out;
        }

        // ------------------------------------------------------------ the bake

        // The panorama at `roughness`, reduced and blurred. Split out so the probe
        // can check the intermediate buffer (energy, isotropy, seam behaviour)
        // without a bitmap backend.
        public static function blurFor(base:FloatPanorama, roughness:Number):FloatPanorama
        {
            var sigmaPx:Number = EnvironmentPrefilter.sigmaPixels(roughness, base.width);
            if (!(sigmaPx > 0.3)) return base;
            var m:int = EnvironmentPrefilter.octaveFor(sigmaPx);
            var src:FloatPanorama = base;
            var k:int;
            for (k = 0; k < m; k++) src = src.downsample();
            var out:FloatPanorama = EnvironmentPrefilter.blur(src, sigmaPx / (1 << m));
            // Conserve the light level BY CONSTRUCTION.
            //
            // A separable discrete convolution on an equirect grid is not exactly
            // conservative once the buffer has been halved a few times: the pole
            // rows hold almost no solid angle, the kernel gets truncated by the
            // image edge, and the two errors do not cancel. Measured on a compact
            // equatorial source: the roughest level came out up to 13% off in
            // sphere-averaged radiance. That is a systematic brightness difference
            // between a smooth and a rough surface, which is precisely what a
            // roughness ladder must not have, so the level is rescaled to the
            // base's sphere mean explicitly instead of hoping the truncation
            // error stays small (E2 pins it at 1e-9).
            var target:Number = EnvironmentPrefilter.sphereMean(base);
            var got:Number = EnvironmentPrefilter.sphereMean(out);
            if (got > 0 && target > 0 && got != target)
            {
                var g:Number = target / got;
                var d:Vector.<Number> = out.data;
                var i:int;
                for (i = 0; i < d.length; i++) d[i] *= g;
            }
            return out;
        }

        // Solid-angle-averaged radiance: sum(f * sin(polar)) / sum(sin(polar)).
        // The plain data mean is NOT this -- an equirect row near a pole covers
        // almost no solid angle, so a "the ladder keeps the brightness" claim made
        // against the pixel mean is measuring the wrong quantity.
        public static function sphereMean(p:FloatPanorama):Number
        {
            if (p == null) return 0;
            var num:Number = 0;
            var den:Number = 0;
            var w3:int = p.width * 3;
            var y:int;
            var x:int;
            for (y = 0; y < p.height; y++)
            {
                var sinPolar:Number = Math.sin((y + 0.5) / p.height * Math.PI);
                var rowSum:Number = 0;
                var base:int = y * w3;
                for (x = 0; x < w3; x++) rowSum += p.data[base + x];
                num += rowSum * sinPolar;
                den += w3 * sinPolar;
            }
            return den > 0 ? num / den : 0;
        }

        // Panorama -> ladder. `scale` <= 0 asks for EquirectangularToCube.autoScale
        // (one divisor for the whole ladder, see PrefilteredEnvironment.hdrScale).
        public static function bake(img:HDRImage, faceSize:int, scale:Number = 0):PrefilteredEnvironment
        {
            if (img == null) throw new Error("EnvironmentPrefilter.bake: null HDRImage");
            if (faceSize <= 0) throw new Error("EnvironmentPrefilter.bake: faceSize must be > 0");
            var s:Number = scale > 0 ? scale : EquirectangularToCube.autoScale(img);
            return EnvironmentPrefilter.bakeFromPanorama(FloatPanorama.fromHDRImage(img),
                                                         LEVEL_ROUGHNESS, faceSize, s);
        }

        public static function bakeFromPanorama(base:FloatPanorama, levels:Vector.<Number>,
                                                faceSize:int, scale:Number):PrefilteredEnvironment
        {
            if (base == null) throw new Error("EnvironmentPrefilter.bakeFromPanorama: null panorama");
            if (levels == null || levels.length == 0)
                throw new Error("EnvironmentPrefilter.bakeFromPanorama: no levels");
            var s:Number = scale > 0 ? scale : 1.0;

            var n:int = levels.length;
            var cubes:Vector.<CubeTexture> = new Vector.<CubeTexture>(n, true);
            var rough:Vector.<Number> = new Vector.<Number>(n, true);
            var i:int;
            for (i = 0; i < n; i++)
            {
                var r:Number = levels[i];
                rough[i] = r;
                var src:PanoramaSampler = EnvironmentPrefilter.blurFor(base, r);
                cubes[i] = EquirectangularToCube.decorate(new CubeTexture(
                    EquirectangularToCube.bakeBitmapsSampled(src, faceSize, s)), s);
            }
            return new PrefilteredEnvironment(cubes, rough, s, faceSize);
        }
    }
}