// asaot.three.extras.LightProbeGenerator -- cube/panorama -> SH9 light probe.
//
// three.js r187 moved this out of src/ (it lived in
// examples/jsm/lights/LightProbeGenerator.js), so "borrow src/..." is not
// available here. The math it ran is standard and is reproduced exactly rather
// than approximated:
//
//     c_lm = integral over the sphere of  L(w) * Y_lm(w)  dw
//
// i.e. the projection of the environment's radiance onto the nine real-SH basis
// functions, which is what SphericalHarmonics3 stores and getIrradianceAt
// consumes. The basis is evaluated by the SAME code the reconstruction uses
// (SphericalHarmonics3.basis), so projection and evaluation cannot drift apart.
//
// WHERE THIS DEVERSION DIFFERS FROM THE EXAMPLE SCRIPT, deliberately:
//
//   * SOLID ANGLE. The example weights every texel by 1/(n*n) and normalises by
//     the face count -- a flat average over the cube's six parameter squares.
//     Here each sample carries its true solid angle (or the sum of the texels a
//     strided sample stands for), and the total is normalised to exactly 4*pi.
//     For a constant environment both give the same answer; for a sun disc the
//     exact version does not under-weight it near a face centre.
//   * STRIDE. A 512-texel face is 1.5M texels over six faces, which is ~10s of
//     AS3. `maxFaceSize` bounds the work; the solid-angle sum stays exact
//     because the samples are rescaled to 4*pi regardless of stride.
//
// WHY A CPU BAKE, NOT SH IN THE SHADER (D176). A faithful SH9 evaluation is ~40
// AGAL instructions and the standard fragment program has ~90 left with M25-R1
// already asking for its share. Instead `toIrradianceCube` bakes the probe's
// irradiance into a small cube face set (default 16x16 per face) and the
// shader samples it at the shading normal -- one `tex`, the same fetch it
// already performs for `scene.environment`. The result is the SAME FUNCTION of
// the normal, evaluated on the CPU at 1536 directions instead of per pixel.
package asaot.three.extras
{
    import asaot.three.lights.LightProbe;
    import asaot.three.math.SphericalHarmonics3;
    import asaot.three.math.Vector3;
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.Texture;
    import flash.display.BitmapData;

    public class LightProbeGenerator
    {
        // Texels per face the integration will touch at most (see the STRIDE
        // note above). 64 keeps a full bake under ~300k samples.
        public static const DEFAULT_MAX_FACE_SIZE:int = 64;

        // Face size of the baked irradiance cube. Irradiance is a 3rd-order
        // polynomial in the normal, so 16 texels of bilinear sampling is well
        // inside a code value of error.
        public static const IRRADIANCE_FACE_SIZE:int = 16;

        // ------------------------------------------------------------ integration

        // SH9 of a cube map. `cube` needs all six faces; a missing face is an
        // error rather than a silent black hemisphere (the impulses in the
        // atmosphere of a probe are the whole point of the probe).
        public static function fromCubeTexture(cube:CubeTexture,
                                               maxFaceSize:int = DEFAULT_MAX_FACE_SIZE):LightProbe
        {
            if (cube == null) throw new Error("LightProbeGenerator: null cube texture");
            var n:int = cube.faceSize();
            if (n <= 0) throw new Error("LightProbeGenerator: cube has no faces");
            var face:int;
            for (face = 0; face < 6; face++)
            {
                if (cube.images.length <= face || cube.images[face] == null)
                    throw new Error("LightProbeGenerator: cube is missing face " + face);
            }

            var stride:int = 1;
            if (maxFaceSize > 0 && n > maxFaceSize)
            {
                stride = int(Math.ceil(n / Number(maxFaceSize)));
            }

            var decodeSrgb:Boolean = (cube.colorSpace == Texture.SRGBColorSpace);
            var radianceScale:Number = cube.hdrScale > 0 ? cube.hdrScale : 1.0;

            var sh:SphericalHarmonics3 = new SphericalHarmonics3();
            var coeff:Vector.<Vector3> = sh.coefficients;
            var dir:Vector3 = new Vector3();
            var col:Vector.<Number> = new Vector.<Number>(3, true);

            var cellArea:Number = (2.0 * stride / n) * (2.0 * stride / n);
            var totalWeight:Number = 0;

            var f:int;
            for (f = 0; f < 6; f++)
            {
                var bmp:BitmapData = cube.images[f];
                var y:int;
                for (y = 0; y < n; y += stride)
                {
                    // Cell centres, not texel corners: the sample stands for the
                    // whole stride x stride block.
                    var v:Number = (y + stride * 0.5) / n;
                    var x:int;
                    for (x = 0; x < n; x += stride)
                    {
                        var u:Number = (x + stride * 0.5) / n;
                        EquirectangularToCube.faceDirection(f, u, v, dir);

                        // Solid angle of that block: the face parameter square
                        // (2/N)^2 projected onto the sphere, sec^3 factor.
                        var s:Number = u * 2.0 - 1.0;
                        var t:Number = v * 2.0 - 1.0;
                        var g:Number = 1.0 + s * s + t * t;
                        var omega:Number = cellArea / (g * Math.sqrt(g));
                        totalWeight += omega;

                        LightProbeGenerator.texel(cube.images[f], x, y, decodeSrgb,
                                                  radianceScale, col);
                        var i:int;
                        for (i = 0; i < 9; i++)
                        {
                            var b:Number = SphericalHarmonics3.basis(i, dir.x, dir.y, dir.z) * omega;
                            var c:Vector3 = coeff[i];
                            c.x += col[0] * b;
                            c.y += col[1] * b;
                            c.z += col[2] * b;
                        }
                    }
                }
            }

            // The mid-point rule slightly UNDER-counts the sphere (the sec^3
            // weight is convex), and a stride makes that bias bigger. Rescaling to
            // exactly 4*pi makes "constant environment L -> irradiance pi*L" hold
            // to machine precision instead of to the discretisation.
            if (totalWeight > 0)
            {
                var k:Number = 4.0 * Math.PI / totalWeight;
                var j:int;
                for (j = 0; j < 9; j++) coeff[j].multiplyScalar(k);
            }

            return new LightProbe(sh, 1.0);
        }

        // Same, from an equirect panorama (HDR or LDR) via the cube path -- the
        // sampler-level projection is identical, so there is one implementation.
        public static function fromHDRPanorama(img:asaot.three.textures.HDRImage,
                                               faceSize:int = 32,
                                               scale:Number = 0):LightProbe
        {
            var cube:CubeTexture = EquirectangularToCube.bakeCube(img, faceSize, scale);
            return LightProbeGenerator.fromCubeTexture(cube, faceSize);
        }

        // One texel as linear radiance, in `out`.
        private static function texel(bmp:BitmapData, x:int, y:int, decodeSrgb:Boolean,
                                      radianceScale:Number, out:Vector.<Number>):void
        {
            var argb:uint = bmp.getPixel32(x, y);
            var r:Number = ((argb >> 16) & 0xFF) / 255.0;
            var g:Number = ((argb >> 8) & 0xFF) / 255.0;
            var b:Number = (argb & 0xFF) / 255.0;
            if (decodeSrgb)
            {
                r = LightProbeGenerator.srgbEotf(r);
                g = LightProbeGenerator.srgbEotf(g);
                b = LightProbeGenerator.srgbEotf(b);
            }
            r *= radianceScale;
            g *= radianceScale;
            b *= radianceScale;
            out[0] = r;
            out[1] = g;
            out[2] = b;
        }

        // The EOTF the renderer's fc41/fc42 pair implements -- the probe must
        // decode a cube exactly the way the shader would, or a probe made from a
        // scene's own environment would disagree with that environment.
        public static function srgbEotf(c:Number):Number
        {
            if (c <= 0) return 0;
            return Math.pow((c + 0.055) / 1.055, 2.4);
        }

        // ------------------------------------------------------------ the bake

        // SH -> small irradiance cube. Texels hold E/pi (the shader's
        // environment term multiplies by pi), gamma-encoded with the renderer's
        // sRGB pair, and `hdrScale` carries the divisor back.
        //
        // A single probe of a bright sky has E up to a few units, so the divisor
        // matters: 8-bit encoding of a linear 0..3.2 range would quantise the
        // darks away. Unlike the M25 bake this does NOT have to be a power of two
        // -- the shader multiplies by whatever scalar the renderer uploads.
        public static function toIrradianceCube(probe:LightProbe,
                                                faceSize:int = IRRADIANCE_FACE_SIZE):CubeTexture
        {
            if (probe == null) throw new Error("LightProbeGenerator: null probe");
            if (faceSize <= 0) throw new Error("LightProbeGenerator: faceSize must be > 0");
            var sh:SphericalHarmonics3 = probe.sh;
            var intensity:Number = probe.intensity;

            var dir:Vector3 = new Vector3();
            var e:Vector3 = new Vector3();
            var lin:Vector.<Number> = new Vector.<Number>(3, true);

            // Pass 1: peak irradiance -> divisor.
            var peak:Number = 0;
            var face:int;
            var y:int;
            var x:int;
            for (face = 0; face < 6; face++)
            {
                for (y = 0; y < faceSize; y++)
                {
                    for (x = 0; x < faceSize; x++)
                    {
                        EquirectangularToCube.faceDirection(face, (x + 0.5) / faceSize,
                                                           (y + 0.5) / faceSize, dir);
                        sh.getIrradianceAt(dir, e);
                        var m:Number = Math.max(Math.max(e.x, e.y), e.z) * intensity;
                        if (m > peak) peak = m;
                    }
                }
            }
            var scale:Number = peak > 0 ? peak : 1.0;

            // Pass 2: encode.
            var texels:Vector.<Vector.<uint>> = new Vector.<Vector.<uint>>(6, true);
            for (face = 0; face < 6; face++)
            {
                var row:Vector.<uint> = new Vector.<uint>(faceSize * faceSize, true);
                for (y = 0; y < faceSize; y++)
                {
                    for (x = 0; x < faceSize; x++)
                    {
                        EquirectangularToCube.faceDirection(face, (x + 0.5) / faceSize,
                                                           (y + 0.5) / faceSize, dir);
                        sh.getIrradianceAt(dir, e);
                        // E / pi is what the shader's "radiance" fetch must see.
                        lin[0] = e.x * intensity / Math.PI;
                        lin[1] = e.y * intensity / Math.PI;
                        lin[2] = e.z * intensity / Math.PI;
                        row[y * faceSize + x] =
                            EquirectangularToCube.encode(lin, 1.0 / (scale / Math.PI));
                    }
                }
                texels[face] = row;
            }

            var cube:CubeTexture = new CubeTexture(
                EquirectangularToCube.bitmapsFromTexels(texels, faceSize));
            return EquirectangularToCube.decorate(cube, scale / Math.PI);
        }
    }
}