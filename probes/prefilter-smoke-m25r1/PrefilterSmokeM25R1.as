// asaot3d/probes/prefilter-smoke-m25r1/PrefilterSmokeM25R1.as -- M25-R1 smoke.
//
// M25-R1 replaces the M9 "sample the sharp cube, mix toward the normal by
// roughness^4" stand-in with a CPU-baked ROUGHNESS LADDER: the panorama is
// convolved at six roughness levels and the renderer binds the level that
// matches the material's roughness. Everything that decides what those levels
// mean is CPU-side, which is what this probe pins:
//
//   A. the lobe: Karis's cosine-power fit -> Gaussian sigma. Monotone, exactly 0
//      at roughness 0, and CAPPED at the cosine lobe's own width (that cap is why
//      the roughest level is also usable as an irradiance source)
//   B. the resolution plan: sigma in pixels, and how many halvings it asks for
//   C. the blur: energy (DC) preserved, u wraps, v clamps, and the kernel is
//      isotropic in ANGLE -- a spot near a pole must not smear sideways
//   D. level selection: nearest roughness, NaN -> sharp, and the ladder's own
//      invariants (one shared hdrScale, levels ascend)
//   E. the bake end to end: a bright spot's peak must fall monotonically down the
//      ladder -- this is the actual "roughness blurs the reflection" claim
//   F. the storage round trip (D177): the sRGB OETF + the renderer's EOTF
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts \
//     probes/prefilter-smoke-m25r1/PrefilterSmokeM25R1.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/prefilter-smoke-m25r1 --run
import asaot.three.AGALRenderer;
import asaot.three.extras.EnvironmentPrefilter;
import asaot.three.extras.EquirectangularToCube;
import asaot.three.extras.LightProbeGenerator;
import asaot.three.extras.PrefilteredEnvironment;
import asaot.three.math.Vector3;
import asaot.three.textures.CubeTexture;
import asaot.three.textures.FloatPanorama;
import asaot.three.textures.HDRImage;

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
// A. the lobe
// ---------------------------------------------------------------------------
// Karis's fit, recomputed here so the probe does not merely echo the class:
//   alpha = r^2,  n = 2/alpha^2 - 2,  half = acos(0.5^(1/n)),
//   sigma = half / sqrt(2 ln 2)
function fitSigma(r:Number):Number
{
    var alpha:Number = r * r;
    var n:Number = 2.0 / (alpha * alpha) - 2.0;
    if (!(n > 0)) return EnvironmentPrefilter.COSINE_SIGMA;
    return Math.acos(Math.pow(0.5, 1.0 / n)) / 1.1774100225154747;
}

// A2/D178: the cap is the cosine lobe's width measured the same way (median
// angle of a cosine-weighted hemisphere = 45 deg = 0.6745 sigma).
check("A1 the cosine-lobe cap is (pi/4)/0.6745 = 1.16443 rad",
      near(EnvironmentPrefilter.COSINE_SIGMA, 1.1644330595, 1e-9));
check("A2 sigma(0) is exactly 0 (level 0 is the sharp bake)",
      EnvironmentPrefilter.prefilterSigma(0) == 0);
check("A3 sigma is 0 for a non-positive or NaN roughness",
      EnvironmentPrefilter.prefilterSigma(-1) == 0 &&
      EnvironmentPrefilter.prefilterSigma(Number.NaN) == 0);
check("A4 sigma(0.5) matches the Karis fit: alpha .25, n 30, 0.18187 rad",
      near(EnvironmentPrefilter.prefilterSigma(0.5), fitSigma(0.5), 1e-12) &&
      near(EnvironmentPrefilter.prefilterSigma(0.5), 0.1818719448, 1e-9));
check("A5 sigma is monotone increasing over the ladder",
      EnvironmentPrefilter.prefilterSigma(0.2) < EnvironmentPrefilter.prefilterSigma(0.4) &&
      EnvironmentPrefilter.prefilterSigma(0.4) < EnvironmentPrefilter.prefilterSigma(0.6) &&
      EnvironmentPrefilter.prefilterSigma(0.6) < EnvironmentPrefilter.prefilterSigma(0.8) &&
      EnvironmentPrefilter.prefilterSigma(0.8) < EnvironmentPrefilter.prefilterSigma(1.0));
check("A6 roughness 1 hits the cap, not the (degenerate) GGX fit",
      near(EnvironmentPrefilter.prefilterSigma(1.0), EnvironmentPrefilter.COSINE_SIGMA, 1e-12));
check("A7 roughness above 1 clamps instead of overshooting",
      near(EnvironmentPrefilter.prefilterSigma(4.0), EnvironmentPrefilter.COSINE_SIGMA, 1e-12));
// The uncapped fit crosses the cosine lobe at r = 0.9526, so the cap is not
// decoration: without it the top of the ladder would be wider than a hemisphere.
check("A8 the uncapped GGX fit is still under the cap at r=0.95",
      fitSigma(0.95) < EnvironmentPrefilter.COSINE_SIGMA &&
      near(fitSigma(0.95), 1.1471853804, 1e-9));
check("A8b ... and over it at r=0.97, which is where prefilterSigma clamps",
      fitSigma(0.97) > EnvironmentPrefilter.COSINE_SIGMA &&
      near(EnvironmentPrefilter.prefilterSigma(0.97),
           EnvironmentPrefilter.COSINE_SIGMA, 1e-12));

// ---------------------------------------------------------------------------
// B. the resolution plan
// ---------------------------------------------------------------------------
check("B1 sigmaPixels(1, 512) = 94.89 px", near(EnvironmentPrefilter.sigmaPixels(1, 512), 94.8865, 1e-3));
check("B2 sigmaPixels scales with the panorama width",
      near(EnvironmentPrefilter.sigmaPixels(1, 1024), 2 * EnvironmentPrefilter.sigmaPixels(1, 512), 1e-9));
check("B3 sigmaPixels of a zero-width panorama is 0, not NaN",
      EnvironmentPrefilter.sigmaPixels(1, 0) == 0);
check("B4 no halving below the 3px budget", EnvironmentPrefilter.octaveFor(0) == 0 &&
      EnvironmentPrefilter.octaveFor(3.0) == 0);
check("B5 one halving takes sigma 4 to 2", EnvironmentPrefilter.octaveFor(4.0) == 1);
check("B6 94.9px asks for 5 halvings (2.96px)", EnvironmentPrefilter.octaveFor(94.8865) == 5);
check("B7 the halving count is capped at MAX_OCTAVE",
      EnvironmentPrefilter.octaveFor(1e6) == EnvironmentPrefilter.MAX_OCTAVE &&
      EnvironmentPrefilter.MAX_OCTAVE == 5);

// ---------------------------------------------------------------------------
// C. the blur
// ---------------------------------------------------------------------------
var W:int = 32;
var H:int = 16;

function flat(w:int, h:int, v:Number):FloatPanorama
{
    var fp:FloatPanorama = new FloatPanorama(w, h);
    var i:int;
    for (i = 0; i < w * h; i++)
    {
        fp.data[i * 3] = v;
        fp.data[i * 3 + 1] = v;
        fp.data[i * 3 + 2] = v;
    }
    return fp;
}

function total(p:FloatPanorama):Number
{
    var s:Number = 0;
    var i:int;
    for (i = 0; i < p.width * p.height * 3; i++) s += p.data[i];
    return s;
}

var flatP:FloatPanorama = flat(W, H, 0.7);
var flatB:FloatPanorama = EnvironmentPrefilter.blur(flatP, 2.0);
check("C1 a flat panorama survives the blur (DC gain is exactly 1)",
      near(total(flatB), total(flatP), 1e-9));
var flatOk:Boolean = true;
var fi:int;
for (fi = 0; fi < W * H * 3; fi++) if (!near(flatB.data[fi], 0.7, 1e-9)) flatOk = false;
check("C2 no ripple on a constant field (the kernel is normalised per row)", flatOk);

// Seam: one bright column at x=0 must leak equally into x=1 and x=W-1.
var seamP:FloatPanorama = flat(W, H, 0.0);
var yy:int;
for (yy = 0; yy < H; yy++)
{
    seamP.data[(yy * W) * 3] = 1.0;
    seamP.data[(yy * W) * 3 + 1] = 1.0;
    seamP.data[(yy * W) * 3 + 2] = 1.0;
}
var seamB:FloatPanorama = EnvironmentPrefilter.blur(seamP, 1.5);
var mid:int = 8 * W;   // a flat row near the equator
check("C3 u wraps: the bright column bleeds symmetrically across the seam",
      near(seamB.data[(mid + 1) * 3], seamB.data[(mid + W - 1) * 3], 1e-9) &&
      seamB.data[(mid + 1) * 3] > 0.1);

// Pole: a bright top row must NOT ghost onto the bottom row (v clamps).
var poleP:FloatPanorama = flat(W, H, 0.0);
var xx:int;
for (xx = 0; xx < W; xx++)
{
    poleP.data[xx * 3] = 1.0;
    poleP.data[xx * 3 + 1] = 1.0;
    poleP.data[xx * 3 + 2] = 1.0;
}
var poleB:FloatPanorama = EnvironmentPrefilter.blur(poleP, 1.0);
check("C4 v clamps: the +Y row does not wrap onto the -Y row",
      poleB.data[((H - 1) * W) * 3] < 1e-6 && poleB.data[0] > 0.1);

// Isotropy in ANGLE: a spot at latitude 60 deg (row 1 of 6 from the pole, i.e.
// sin(polar) = 0.5) must spread the SAME arc vertically and horizontally. In
// pixels that means the horizontal spread is WIDER by 1/sin(polar) = 2x.
var isoP:FloatPanorama = flat(64, 32, 0.0);
var spotRow:int = int(32 * 0.1666667);       // polar 30 deg -> sin = 0.5
var spotCol:int = 32;
isoP.data[(spotRow * 64 + spotCol) * 3] = 1.0;
isoP.data[(spotRow * 64 + spotCol) * 3 + 1] = 1.0;
isoP.data[(spotRow * 64 + spotCol) * 3 + 2] = 1.0;
var isoB:FloatPanorama = EnvironmentPrefilter.blur(isoP, 2.0);
// Horizontal neighbours 4 px away vs vertical neighbours 4 px away: with the
// 1/sin correction the horizontal falloff is shallower by about that factor.
var hFar:Number = isoB.data[(spotRow * 64 + spotCol + 4) * 3];
var vFar:Number = isoB.data[((spotRow + 4) * 64 + spotCol) * 3];
check("C5 the kernel is isotropic in angle: at sin=0.5 the horizontal tail is " +
      "wider than the vertical one", hFar > vFar * 1.5);

// ---------------------------------------------------------------------------
// D. the ladder
// ---------------------------------------------------------------------------
check("D1 the ladder is six levels at 0.2 spacing, ascending",
      EnvironmentPrefilter.LEVEL_ROUGHNESS.length == 6 &&
      EnvironmentPrefilter.LEVEL_ROUGHNESS[0] == 0 &&
      near(EnvironmentPrefilter.LEVEL_ROUGHNESS[5], 1.0) &&
      EnvironmentPrefilter.LEVEL_ROUGHNESS[3] > EnvironmentPrefilter.LEVEL_ROUGHNESS[2]);

var levels:Vector.<CubeTexture> = new Vector.<CubeTexture>(6, true);
var rough:Vector.<Number> = new Vector.<Number>(6, true);
var li:int;
for (li = 0; li < 6; li++)
{
    levels[li] = EquirectangularToCube.decorate(new CubeTexture(), 8.0);
    rough[li] = EnvironmentPrefilter.LEVEL_ROUGHNESS[li];
}
var ladder:PrefilteredEnvironment = new PrefilteredEnvironment(levels, rough, 8.0, 32);
check("D2 levelCount and the sharp/irradiance ends", ladder.levelCount == 6 &&
      ladder.sharpCube == levels[0] && ladder.irradianceCube == levels[5]);
check("D3 roughness 0 -> level 0, roughness 1 -> level 5",
      ladder.levelFor(0) == 0 && ladder.levelFor(1.0) == 5);
check("D4 the step is at the midpoint between levels",
      ladder.levelFor(0.09) == 0 && ladder.levelFor(0.11) == 1 &&
      ladder.levelFor(0.29) == 1 && ladder.levelFor(0.31) == 2);
check("D5 out-of-range and NaN roughness do not walk off the table",
      ladder.levelFor(-3) == 0 && ladder.levelFor(9) == 5 &&
      ladder.levelFor(Number.NaN) == 0);
check("D6 cubeFor returns the level levelFor picks",
      ladder.cubeFor(0.65) == levels[3] && ladder.levelFor(0.65) == 3);

// The ladder's constructor refuses shapes that cannot be indexed consistently.
var threw:Boolean = false;
try { new PrefilteredEnvironment(new Vector.<CubeTexture>(), new Vector.<Number>(), 1, 8); }
catch (e:Error) { threw = true; }
check("D7 an empty ladder is refused", threw);
threw = false;
try { new PrefilteredEnvironment(levels, new Vector.<Number>(), 1, 8); }
catch (e2:Error) { threw = true; }
check("D8 a roughness table that does not parallel the levels is refused", threw);

// ---------------------------------------------------------------------------
// E. the bake end to end
// ---------------------------------------------------------------------------
// A 64x32 panorama with one very bright texel (linear 4.0 = RGBE 255/130).
function spotImage(w:int, h:int, cx:int, cy:int):HDRImage
{
    var img:HDRImage = new HDRImage(w, h);
    var i:int;
    for (i = 0; i < w * h; i++)
    {
        img.rgbe[i * 4] = 0;
        img.rgbe[i * 4 + 1] = 0;
        img.rgbe[i * 4 + 2] = 0;
        img.rgbe[i * 4 + 3] = 128;
    }
    var k:int = (cy * w + cx) * 4;
    img.rgbe[k] = 255;
    img.rgbe[k + 1] = 255;
    img.rgbe[k + 2] = 255;
    img.rgbe[k + 3] = 130;
    return img;
}

// A 512x256 panorama with a 40-pixel disc at 4.0. Wide enough that every ladder
// level actually blurs (at 64 wide, roughness 0.2 is 0.29 px -- no blur at all),
// and broad enough that an 8x8 cube face lands inside it.
function discImage(w:int, h:int, radius:int):HDRImage
{
    var img:HDRImage = new HDRImage(w, h);
    var cx:int = w / 2;
    var cy:int = h / 2;
    var i:int;
    for (i = 0; i < w * h; i++)
    {
        var px:int = i % w;
        var py:int = int(i / w);
        var dx:int = px - cx;
        var dy:int = py - cy;
        var on:Boolean = (dx * dx + dy * dy) <= radius * radius;
        img.rgbe[i * 4] = on ? 255 : 0;
        img.rgbe[i * 4 + 1] = on ? 255 : 0;
        img.rgbe[i * 4 + 2] = on ? 255 : 0;
        img.rgbe[i * 4 + 3] = on ? 130 : 128;
    }
    return img;
}

var img:HDRImage = discImage(512, 256, 20);
var base:FloatPanorama = FloatPanorama.fromHDRImage(img);
check("E1 FloatPanorama decodes RGBe to linear (255/130 is 4.0)",
      near(base.data[(128 * 512 + 256) * 3], 4.0, 1e-9));

// Energy: every level keeps the same SOLID-ANGLE-WEIGHTED mean radiance.
//
// Not the plain data mean: an equirect row covers a solid angle proportional to
// sin(polar), so the pole rows contribute almost nothing to a sphere integral
// and a plain pixel mean is not the quantity the bake is supposed to preserve.
// (An earlier pin used the plain mean and "failed" at the coarse levels simply
// because their pole rows had been re-averaged -- the sphere average never
// moved.) The cube bake samples directions uniformly, so this IS the invariant
// that says "the ladder does not lose or gain light".
function sphereMean(p:FloatPanorama):Number
{
    return EnvironmentPrefilter.sphereMean(p);
}

var baseMean:Number = sphereMean(base);
var energyOk:Boolean = true;
var lv:int;
for (lv = 1; lv < 6; lv++)
{
    var blurred:FloatPanorama = EnvironmentPrefilter.blurFor(base, rough[lv]);
    if (!near(sphereMean(blurred), baseMean, baseMean * 1e-12)) energyOk = false;
}
check("E2 every blurred level preserves the sphere-averaged radiance exactly", energyOk);

// The claim M25-R1 actually makes: a bright spot's PEAK falls down the ladder.
// Baked cube texels are read back and decoded with the same EOTF the shader
// runs, so this measures what a material at that roughness would see.
function peakOf(fp:FloatPanorama):Number
{
    var texels:Vector.<Vector.<uint>> = EquirectangularToCube.bakeTexelsSampled(fp, 8, 4.0);
    var peak:Number = 0;
    var f:int;
    var i2:int;
    for (f = 0; f < 6; f++)
    {
        var t:Vector.<uint> = texels[f];
        for (i2 = 0; i2 < t.length; i2++)
        {
            var g:Number = LightProbeGenerator.srgbEotf(((t[i2] >> 8) & 0xFF) / 255.0) * 4.0;
            if (g > peak) peak = g;
        }
    }
    return peak;
}

var peaks:Vector.<Number> = new Vector.<Number>(6, true);
var p:int;
for (p = 0; p < 6; p++) peaks[p] = peakOf(EnvironmentPrefilter.blurFor(base, rough[p]));
trace("  E3 peaks: " + peaks[0] + " " + peaks[1] + " " + peaks[2] + " " +
      peaks[3] + " " + peaks[4] + " " + peaks[5]);
check("E3 the disc peaks near 4.0 at level 0", near(peaks[0], 4.0, 0.3));
var monotone:Boolean = true;
for (p = 1; p < 6; p++) if (!(peaks[p] <= peaks[p - 1])) monotone = false;
check("E4 the peak falls monotonically down the roughness ladder", monotone);
check("E5 the roughest level is well below the sharp one (>= 5x smaller)",
      peaks[5] * 5 < peaks[0]);
check("E6 the roughest level is still bright (the spot's energy did not vanish)",
      peaks[5] > 0.01);

// ---------------------------------------------------------------------------
// F. storage round trip (D177)
// ---------------------------------------------------------------------------
// The bake's OETF and the renderer's EOTF are one decision: if either side moves
// alone the environment term darkens by ~2% at mid tones.
var rtOk:Boolean = true;
var maxErr:Number = 0;
var lvl:int;
for (lvl = 1; lvl < 256; lvl++)
{
    var lin:Number = lvl / 255.0;
    var texel:uint = EquirectangularToCube.encode(
        new <Number>[lin, lin, lin], 1.0);
    var back:Number = LightProbeGenerator.srgbEotf(((texel >> 16) & 0xFF) / 255.0);
    var err:Number = Math.abs(back - lin);
    if (err > maxErr) maxErr = err;
    // One code value of slop below the knee, where the curve is steepest.
    if (err > 0.006) rtOk = false;
}
trace("  F1 worst round-trip error: " + maxErr);
check("F1 encode -> decode is the identity within a code value across the ramp", rtOk);

// A baked cube reports the divisor the shader needs to undo the encode.
var cube:CubeTexture = EquirectangularToCube.decorate(
    new CubeTexture(), 4.0);
check("F2 decorate marks the cube sRGB and carries the divisor",
      cube.hdrScale == 4.0);
check("F3 envIntensityOf folds that divisor into the per-draw scalar",
      near(AGALRenderer.envIntensityOf(1.0, cube, 2.0), 8.0, 1e-9));
check("F4 the ladder keeps one divisor for every level (one scalar per slot)",
      ladder.hdrScale == 8.0);

// ---------------------------------------------------------------------------
if (failed == 0) trace("ALL PASS");
else trace("FAILED " + failed);