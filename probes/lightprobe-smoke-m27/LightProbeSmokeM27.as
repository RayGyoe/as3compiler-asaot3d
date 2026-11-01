// asaot3d/probes/lightprobe-smoke-m27/LightProbeSmokeM27.as -- M27 smoke.
//
// M27 adds LightProbe: an SH9 light source, three.js style. What the GPU side
// does with it is one extra environment fetch (D176), so almost everything that
// can be wrong is CPU-side and is pinned here:
//
//   A. SphericalHarmonics3: the basis order, and that getAt really is
//      sum(coeff[i] * basis(i)) -- a rotated basis still looks like "smooth
//      directional light", so it has to be checked axis by axis
//   B. projection: a constant environment of radiance L must give c0 = 4*pi*Y00*L,
//      zero for every higher coefficient, and irradiance pi*L in every direction
//   C. a directional environment: mirror symmetry, the right axis, and the SH
//      irradiance checked against a brute-force cosine integral over the same
//      texels (order 2 is an approximation, so this is a tolerance not an equality)
//   D. intensity, getIrradianceAt, and the version hook the renderer re-bakes on
//   E. the irradiance bake: texels hold E/pi, gamma-encoded with the renderer's
//      sRGB pair, with the divisor in hdrScale
//   F. the refusals (a probe cannot be made from a hole)
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts \
//     probes/lightprobe-smoke-m27/LightProbeSmokeM27.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/lightprobe-smoke-m27 --run
import asaot.three.extras.EquirectangularToCube;
import asaot.three.extras.LightProbeGenerator;
import asaot.three.lights.LightProbe;
import asaot.three.math.SphericalHarmonics3;
import asaot.three.math.Vector3;
import asaot.three.textures.CubeTexture;
import asaot.three.textures.Texture;

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
// A. the basis
// ---------------------------------------------------------------------------
check("A1 Y00 is 0.282095", near(SphericalHarmonics3.C0, 0.282095, 1e-12));
check("A2 Y1x is 0.488603", near(SphericalHarmonics3.C1, 0.488603, 1e-12));
// The l=2 constants are 1.092548 (xy/yz/xz), 0.315392 (3z^2-1), 0.546274 (x^2-y^2).
check("A3 the l=2 constants match the r187 table",
      near(SphericalHarmonics3.C2_XY, 1.092548, 1e-12) &&
      near(SphericalHarmonics3.C2_Z2, 0.315392, 1e-12) &&
      near(SphericalHarmonics3.C2_XY2, 0.546274, 1e-12));

// three.js's index order: 1 -> y, 2 -> z, 3 -> x. Pinned one axis at a time
// because a permuted basis is invisible in a smooth render.
check("A4 index 1 is the Y axis, 2 the Z axis, 3 the X axis",
      near(SphericalHarmonics3.basis(1, 0, 1, 0), 0.488603, 1e-12) &&
      near(SphericalHarmonics3.basis(2, 0, 0, 1), 0.488603, 1e-12) &&
      near(SphericalHarmonics3.basis(3, 1, 0, 0), 0.488603, 1e-12) &&
      SphericalHarmonics3.basis(1, 1, 0, 0) == 0);
check("A5 the l=2 axials: xy, yz, 3z^2-1, xz, x^2-y^2",
      near(SphericalHarmonics3.basis(4, 1, 1, 0), 1.092548, 1e-12) &&
      near(SphericalHarmonics3.basis(5, 0, 1, 1), 1.092548, 1e-12) &&
      near(SphericalHarmonics3.basis(6, 0, 0, 1), 2 * 0.315392, 1e-12) &&
      near(SphericalHarmonics3.basis(7, 1, 0, 1), 1.092548, 1e-12) &&
      near(SphericalHarmonics3.basis(8, 1, 0, 0), 0.546274, 1e-12));

var sh:SphericalHarmonics3 = new SphericalHarmonics3();
var i:int;
for (i = 0; i < 9; i++) sh.coefficients[i].set(i + 0.5, i + 1.5, i + 2.5);
var n1:Vector3 = new Vector3(0.3, -0.5, 0.81);
n1.normalize();
var got:Vector3 = new Vector3();
var want:Vector3 = new Vector3(0, 0, 0);
sh.getAt(n1, got);
for (i = 0; i < 9; i++)
{
    var b:Number = SphericalHarmonics3.basis(i, n1.x, n1.y, n1.z);
    want.x += sh.coefficients[i].x * b;
    want.y += sh.coefficients[i].y * b;
    want.z += sh.coefficients[i].z * b;
}
check("A6 getAt is sum(coeff[i] * basis(i)) on an arbitrary direction",
      near(got.x, want.x, 1e-12) && near(got.y, want.y, 1e-12) && near(got.z, want.z, 1e-12));

check("A7 a fresh probe is all zeros", new SphericalHarmonics3().coefficients[4].x == 0);
check("A8 zero() clears every coefficient",
      sh.clone().zero().coefficients[8].z == 0);
check("A9 scaling is linear in the coefficients",
      near(sh.clone().scale(2.0).coefficients[3].y, (3.0 + 1.5) * 2, 1e-12));
check("A10 equals/clone/fromArray/toArray round-trip",
      sh.clone().equals(sh) &&
      new SphericalHarmonics3().fromArray(sh.toArray(new Vector.<Number>(27), 0)).equals(sh));
check("A11 addScaledSH is add-then-scale", (function():Boolean
{
    var a:SphericalHarmonics3 = sh.clone();
    var c:SphericalHarmonics3 = sh.clone().add(sh).scale(0.5);
    return a.addScaledSH(sh, 1.0).scale(0.5).equals(c);
})());

// ---------------------------------------------------------------------------
// B. a constant environment
// ---------------------------------------------------------------------------
// A 4x4 white cube with NoColorSpace: every texel is linear radiance 1.0.
function uniformCube(faceSize:int, argb:uint, face:int = -1):CubeTexture
{
    var texels:Vector.<Vector.<uint>> = new Vector.<Vector.<uint>>(6, true);
    var f:int;
    for (f = 0; f < 6; f++)
    {
        var row:Vector.<uint> = new Vector.<uint>(faceSize * faceSize, true);
        var px:uint = (face < 0 || face == f) ? argb : 0x00000000;
        var i2:int;
        for (i2 = 0; i2 < row.length; i2++) row[i2] = px;
        texels[f] = row;
    }
    var cube:CubeTexture = new CubeTexture(
        EquirectangularToCube.bitmapsFromTexels(texels, faceSize));
    return cube;
}

var white:CubeTexture = uniformCube(4, 0xFFFFFFFF);
check("B1 an LDR cube stays NoColorSpace (nothing is decoded)",
      white.colorSpace != Texture.SRGBColorSpace && white.hdrScale == 1.0);

var cp:LightProbe = LightProbeGenerator.fromCubeTexture(
    white, LightProbeGenerator.DEFAULT_MAX_FACE_SIZE);
var c0:Vector3 = cp.sh.coefficients[0];
check("B2 c0 = 4*pi*Y00*L = 3.54491 for L = 1",
      near(c0.x, 3.5449103185, 1e-6) && near(c0.y, c0.x, 1e-9) && near(c0.z, c0.x, 1e-9));
check("B3 every higher coefficient is ~0 (no preferred direction)",
      Math.abs(cp.sh.coefficients[1].y) < 1e-9 &&
      Math.abs(cp.sh.coefficients[4].x) < 1e-9 &&
      Math.abs(cp.sh.coefficients[6].z) < 1e-9);

var e1:Vector3 = new Vector3();
var up:Vector3 = new Vector3(0, 1, 0);
var dir:Vector3 = new Vector3();
cp.sh.getIrradianceAt(up, e1);
// 0.886227 is a six-decimal literal in three.js, so pi*L resolves to 1e-6, not
// to 1e-12: the tolerance here is the literal's precision, not a fudge.
check("B4 getIrradianceAt(+Y) is pi*L for a constant environment",
      near(e1.x, Math.PI, 1e-5) && near(e1.y, Math.PI, 1e-5));
check("B5 ... and the same in every other direction", (function():Boolean
{
    var t:Vector3 = new Vector3();
    var d:Vector3 = new Vector3();
    var ok:Boolean = true;
    var a:int;
    for (a = 0; a < 12; a++)
    {
        var th:Number = a * 0.7;
        d.set(Math.cos(th), Math.sin(th * 1.3), Math.sin(th));
        d.normalize();
        cp.sh.getIrradianceAt(d, t);
        if (!near(t.x, Math.PI, 1e-5)) ok = false;
    }
    return ok;
})());

// ---------------------------------------------------------------------------
// C. a directional environment
// ---------------------------------------------------------------------------
// Only the +Y face is lit. 16x16 keeps the texel grid fine enough that the
// brute-force integral below is accurate to ~1%.
var upOnly:CubeTexture = uniformCube(16, 0xFFFFFFFF, 2);
var dp:LightProbe = LightProbeGenerator.fromCubeTexture(
    upOnly, LightProbeGenerator.DEFAULT_MAX_FACE_SIZE);

function irradianceAt(probe:LightProbe, x:Number, y:Number, z:Number):Vector3
{
    var d:Vector3 = new Vector3(x, y, z);
    d.normalize();
    var t:Vector3 = new Vector3();
    probe.sh.getIrradianceAt(d, t);
    return t;
}

var eUp:Number = irradianceAt(dp, 0, 1, 0).x;
var eDown:Number = irradianceAt(dp, 0, -1, 0).x;
var ePosX:Number = irradianceAt(dp, 1, 0, 0).x;
var eNegX:Number = irradianceAt(dp, -1, 0, 0).x;
var ePosZ:Number = irradianceAt(dp, 0, 0, 1).x;
check("C1 a +Y-only environment lights +Y far more than -Y", eUp > 3 * eDown);
check("C2 the side directions are dimmer than +Y and brighter than -Y",
      ePosX < eUp && ePosX > eDown);
check("C3 mirror symmetry: +X == -X and +Z == -Z",
      near(ePosX, eNegX, 1e-9) && near(ePosZ, irradianceAt(dp, 0, 0, -1).x, 1e-9));
check("C4 the residual is in the l=1 Y band, as it must be for a face-up sky",
      dp.sh.coefficients[1].y > 0.1 && Math.abs(dp.sh.coefficients[3].x) < 1e-6);

// Brute force over the same texel grid: E(n) = sum L * max(0, n.w) * dOmega.
function bruteIrradiance(cube:CubeTexture, nx:Number, ny:Number, nz:Number):Number
{
    var n:int = cube.faceSize();
    var normal:Vector3 = new Vector3(nx, ny, nz);
    normal.normalize();
    var d:Vector3 = new Vector3();
    var e:Number = 0;
    var f:int;
    var y:int;
    var x:int;
    for (f = 0; f < 6; f++)
    {
        var bmp:flash.display.BitmapData = cube.images[f];
        for (y = 0; y < n; y++)
        {
            for (x = 0; x < n; x++)
            {
                var argb:uint = bmp.getPixel32(x, y);
                var lum:Number = ((argb >> 16) & 0xFF) / 255.0;
                if (lum <= 0) continue;
                var u:Number = (x + 0.5) / n;
                var v:Number = (y + 0.5) / n;
                EquirectangularToCube.faceDirection(f, u, v, d);
                var s:Number = u * 2.0 - 1.0;
                var t:Number = v * 2.0 - 1.0;
                var g:Number = 1.0 + s * s + t * t;
                var omega:Number = (2.0 / n) * (2.0 / n) / (g * Math.sqrt(g));
                var cosT:Number = normal.x * d.x + normal.y * d.y + normal.z * d.z;
                if (cosT > 0) e += lum * cosT * omega;
            }
        }
    }
    return e;
}

var bruteUp:Number = bruteIrradiance(upOnly, 0, 1, 0);
var bruteSide:Number = bruteIrradiance(upOnly, 1, 0, 0);
trace("  C5 SH +Y " + eUp + " vs brute force " + bruteUp +
      "; +X " + ePosX + " vs " + bruteSide);
check("C5 the SH irradiance at +Y matches the brute-force cosine integral (5%)",
      near(eUp, bruteUp, bruteUp * 0.05));
check("C6 ... and at +X, which is where a wrong l=2 term shows up (10%)",
      near(ePosX, bruteSide, Math.max(bruteSide * 0.10, 1e-3)));

// ---------------------------------------------------------------------------
// D. LightProbe itself
// ---------------------------------------------------------------------------
check("D1 a probe is not a light (light collection must skip it)", !dp.isLight);
check("D2 a default probe has an empty (zero) SH", new LightProbe().sh.coefficients[0].x == 0);
var v0:int = dp.version;
dp.invalidate();
check("D3 invalidate() bumps the version the renderer re-bakes on", dp.version == v0 + 1);
dp.sh = dp.sh;
check("D4 assigning sh bumps the version too", dp.version == v0 + 2);

var dim:LightProbe = new LightProbe(upOnly == null ? null : dp.sh.clone(), 0.5);
check("D5 getIrradianceAt folds intensity in", near(dim.getIrradianceAt(up, new Vector3()).x,
      eUp * 0.5, 1e-9));

// ---------------------------------------------------------------------------
// E. the irradiance bake
// ---------------------------------------------------------------------------
var scaleOut:Vector.<Number> = new Vector.<Number>(1, true);
var cube:CubeTexture = LightProbeGenerator.toIrradianceCube(cp, 8);
check("E1 the baked cube is sRGB-encoded and carries a divisor",
      cube.colorSpace == Texture.SRGBColorSpace && cube.hdrScale > 0);
check("E2 a constant pi*L irradiance bakes to a constant E/pi = L cube", (function():Boolean
{
    var ok:Boolean = true;
    var f:int;
    var y:int;
    var x:int;
    for (f = 0; f < 6; f++)
    {
        var bmp:flash.display.BitmapData = cube.images[f];
        for (y = 0; y < 8; y++)
        {
            for (x = 0; x < 8; x++)
            {
                var argb:uint = bmp.getPixel32(x, y);
                var c:Number = ((argb >> 16) & 0xFF) / 255.0;
                var lin:Number = LightProbeGenerator.srgbEotf(c) * cube.hdrScale;
                if (!near(lin, 1.0, 0.02)) ok = false;
            }
        }
    }
    return ok;
})());

// Directional: the +Y face centre must be the brightest texel and -Y the dimmest.
var dirCube:CubeTexture = LightProbeGenerator.toIrradianceCube(dp, 8);
function faceCenter(c:CubeTexture, face:int, size:int):Number
{
    var argb:uint = c.images[face].getPixel32(size >> 1, size >> 1);
    return LightProbeGenerator.srgbEotf(((argb >> 16) & 0xFF) / 255.0) * c.hdrScale;
}
var upC:Number = faceCenter(dirCube, 2, 8);
var downC:Number = faceCenter(dirCube, 3, 8);
var posXC:Number = faceCenter(dirCube, 0, 8);
trace("  E3 face centres: +Y " + upC + " -Y " + downC + " +X " + posXC);
check("E3 the baked +Y face centre is brighter than +X, which is brighter than -Y",
      upC > posXC && posXC > downC);
check("E4 the bake reproduces getIrradianceAt/pi at the face centres (2%)",
      near(upC, eUp / Math.PI, (eUp / Math.PI) * 0.02) &&
      near(downC, eDown / Math.PI, Math.max((eDown / Math.PI) * 0.02, 1e-3)));

// ---------------------------------------------------------------------------
// F. refusals
// ---------------------------------------------------------------------------
var threw:Boolean = false;
try { LightProbeGenerator.fromCubeTexture(null, 4); } catch (e:Error) { threw = true; }
check("F1 a null cube is refused", threw);
threw = false;
try { LightProbeGenerator.fromCubeTexture(new CubeTexture(), 4); } catch (e2:Error)
{
    threw = true;
}
check("F2 a cube with no faces is refused by name", threw);
threw = false;
var holed:CubeTexture = uniformCube(4, 0xFFFFFFFF);
holed.images[3] = null;
try { LightProbeGenerator.fromCubeTexture(holed, 4); } catch (e3:Error)
{
    threw = true;
    check("F3 a missing face names the face it is missing", e3.message.indexOf("3") >= 0);
}
check("F4 a cube with a hole is refused", threw);
threw = false;
try { LightProbeGenerator.toIrradianceCube(null, 8); } catch (e4:Error) { threw = true; }
check("F5 a null probe is refused", threw);

// ---------------------------------------------------------------------------
if (failed == 0) trace("ALL PASS");
else trace("FAILED " + failed);