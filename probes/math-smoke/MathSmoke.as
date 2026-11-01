// asaot3d/probes/math-smoke/MathSmoke.as -- assertion smoke test for the math kit.
//
// Compiles the whole math/ package against known values and round-trips, so a
// silent numerical drift in Vector3/Matrix4/Quaternion/Euler/Color fails loudly.
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/math-smoke/MathSmoke.as \
//        $(find kit -name '*.as') -o temp/math-smoke.exe --run
//
// The kit glob (not math/*.as) is deliberate: M14's Ray.as types
// intersectsSphere(Sphere) and intersectsPlane(Plane), so math/ alone no longer
// compiles -- the probe only ever asserts math/, but it must be built with the
// types math/ refers to.
import asaot.three.math.Color;
import asaot.three.math.Euler;
import asaot.three.math.MathUtils;
import asaot.three.math.Matrix4;
import asaot.three.math.Quaternion;
import asaot.three.math.Vector3;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-5):Boolean
{
    return Math.abs(a - b) < eps;
}

function v3near(v:Vector3, x:Number, y:Number, z:Number):Boolean
{
    return near(v.x, x) && near(v.y, y) && near(v.z, z);
}

// ---- MathUtils (pure scalars) ----
check("MathUtils.lerp", near(MathUtils.lerp(0, 10, 0.5), 5));
check("MathUtils.clamp", MathUtils.clamp(5, 0, 3) == 3);
check("MathUtils.degToRad", near(MathUtils.degToRad(180), Math.PI));
check("MathUtils.radToDeg", near(MathUtils.radToDeg(Math.PI), 180));
check("MathUtils.isPowerOfTwo", MathUtils.isPowerOfTwo(1024) && !MathUtils.isPowerOfTwo(1000));

// ---- Vector3 ----
check("Vector3.add", v3near(new Vector3(1, 2, 3).add(new Vector3(4, 5, 6)), 5, 7, 9));
check("Vector3.sub", v3near(new Vector3(5, 5, 5).sub(new Vector3(2, 3, 4)), 3, 2, 1));
check("Vector3.dot", new Vector3(1, 2, 3).dot(new Vector3(4, 5, 6)) == 32);
check("Vector3.cross", v3near(new Vector3(1, 0, 0).cross(new Vector3(0, 1, 0)), 0, 0, 1));
check("Vector3.length", near(new Vector3(3, 4, 0).length(), 5));
check("Vector3.normalize", near(new Vector3(3, 0, 0).normalize().x, 1));
check("Vector3.lerp", v3near(new Vector3(0, 0, 0).lerp(new Vector3(10, 10, 10), 0.25), 2.5, 2.5, 2.5));

// ---- Color ----
check("Color.setHex", new Color(0xff0000).getHex() == 0xff0000);
// D30 color management: setHex decodes sRGB -> linear; 0x808080's 0.502 sRGB
// channel lands at ~0.216 linear, and getHex round-trips the hex back exactly.
check("Color.setHex decode", new Color(0x808080).r < 0.5);
check("Color hex round-trip", new Color(0x808080).getHex() == 0x808080);

// ---- Quaternion: 90deg around +Y rotates +X to -Z (right-handed) ----
var q:Quaternion = new Quaternion().setFromEuler(new Euler(0, Math.PI / 2, 0));
var xv:Vector3 = new Vector3(1, 0, 0).applyQuaternion(q);
check("Quaternion.Y90 X->-Z", near(xv.x, 0) && near(xv.y, 0) && near(xv.z, -1));

// ---- Matrix4.makePerspective known values ----
var p:Matrix4 = new Matrix4().makePerspective(-1, 1, 1, -1, 1, 100);
check("perspective[0]", near(p.elements[0], 1));
check("perspective[5]", near(p.elements[5], 1));
check("perspective[10]", near(p.elements[10], -100.0 / 99.0));
check("perspective[11]", near(p.elements[11], -1));
check("perspective[14]", near(p.elements[14], -100.0 / 99.0));

// ---- Matrix4 multiply by identity is a no-op ----
var m:Matrix4 = new Matrix4().set(
    1, 2, 3, 4,
    5, 6, 7, 8,
    9, 10, 11, 12,
    13, 14, 15, 16);
check("Matrix4.identity-multiply", new Matrix4().multiply(m).equals(m));

// ---- compose / decompose round-trip ----
var pos:Vector3 = new Vector3(1, 2, 3);
var scl:Vector3 = new Vector3(2, 3, 4);
var q2:Quaternion = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0).normalize(), 0.7);
var comp:Matrix4 = new Matrix4().compose(pos, q2, scl);
var dpos:Vector3 = new Vector3();
var dq:Quaternion = new Quaternion();
var dscl:Vector3 = new Vector3();
comp.decompose(dpos, dq, dscl);
check("decompose.position", v3near(dpos, 1, 2, 3));
check("decompose.scale", v3near(dscl, 2, 3, 4));
check("decompose.quat", Math.abs(dq.dot(q2)) > 0.9999);

// ---- Euler <-> Quaternion round-trip ----
var e0:Euler = new Euler(0.5, -0.3, 0.2);
var q3:Quaternion = new Quaternion().setFromEuler(e0);
var e1:Euler = new Euler().setFromQuaternion(q3);
check("Euler.roundtrip.x", near(e1.x, e0.x));
check("Euler.roundtrip.y", near(e1.y, e0.y));
check("Euler.roundtrip.z", near(e1.z, e0.z));

// ---- Matrix4 invert: M * M^-1 = I (approx; float round-trip 3*(1/3) != 1 exactly) ----
var m2:Matrix4 = new Matrix4().set(
    1, 0, 0, 5,
    0, 2, 0, -3,
    0, 0, 3, 7,
    0, 0, 0, 1);
var minv:Matrix4 = m2.clone().invert();
var prod:Matrix4 = new Matrix4().multiplyMatrices(m2, minv);
var id:Matrix4 = new Matrix4();
var invertOk:Boolean = true;
var i:int = 0;
while (i < 16)
{
    if (!near(prod.elements[i], id.elements[i])) invertOk = false;
    i++;
}
check("Matrix4.invert", invertOk);

trace(failed == 0 ? "RESULT: PASS" : "RESULT: FAIL (" + failed + ")");
