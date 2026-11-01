// asaot3d/probes/uv-smoke-m18/UVSmokeM18.as -- M18 uv-transform smoke.
//
// Before M18 a Texture carried no uv transform at all, so `texture.repeat`,
// `offset`, `rotation`, `center` and `matrix` did not exist and the only way to
// tile a map was to scale the geometry's uv attribute by hand. three.js instead
// multiplies every map's uv by its own mat3 in the vertex shader
// (uv_vertex.glsl.js: `vMapUv = (mapTransform * vec3(uv,1)).xy`), where the
// matrix is built by Texture.updateMatrix() -> Matrix3.setUvTransform() and
// refreshed per draw while matrixAutoUpdate is true
// (WebGLMaterials.js:13-22 refreshTransformUniform).
//
// This probe pins the half that needs no GPU:
//
//   A. Matrix3.setUvTransform -- the r187 formula, including rotation about
//      `center` and the fact that a 2*PI rotation is the identity.
//   B. Texture.updateMatrix() -- offset/repeat/rotation/center folded into
//      `matrix`, and matrixAutoUpdate's contract (refresh while true, otherwise
//      the authored matrix is used as-is).
//   C. AGALRenderer.uvRowsInto -- the two (u,v,0,1) rows a `dp4` pair needs, and
//      the identity they have to reproduce for an untransformed texture.
//   D. The dot-product rows must equal three.js's mat3 * (u,v,1) for every
//      sample. This is the check that actually protects the shader: the AGAL
//      side is 2 dp4s against (u,v,0,1), which is only correct if the packing
//      puts m20/m21 in .w and the u/v coefficients in .x/.y.
//   E. uvVaryingOf -- the six slot -> varying map (each slot must read its OWN
//      pair; two slots sharing one pair would be the pre-M18 single-uv bug).
//   F. uvTransformBlock -- 16 instructions, vc40..vc51 in sequence, writes
//      v2/v3/v6/v7. Regression guard: an earlier version of this helper spelled
//      `return` on its own line, which AS3's automatic semicolon insertion
//      turned into `return undefined` -- the block became a literal "null" line
//      in the vertex source and every draw failed pipeline linking.
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/uv-smoke-m18/UVSmokeM18.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/uv-smoke-m18 --run
import asaot.three.AGALRenderer;
import asaot.three.math.Matrix3;
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

// Number of non-overlapping occurrences of `needle` in `hay` (AS3 String has no
// count API, and the probe must not add helpers to the renderer just for this).
function countOf(hay:String, needle:String):int
{
    var n:int = 0;
    var at:int = hay.indexOf(needle);
    while (at >= 0)
    {
        n++;
        at = hay.indexOf(needle, at + needle.length);
    }
    return n;
}

// three.js applies the mat3 to vec3(uv, 1): uv' = (m00 u + m01 v + m02,
// m10 u + m11 v + m12). Matrix3 is column-major, so e[0]=m00, e[3]=m01,
// e[6]=m02, e[1]=m10, e[4]=m11, e[7]=m12.
function uvX(m:Matrix3, u:Number, v:Number):Number
{
    var e:Vector.<Number> = m.elements;
    return e[0] * u + e[3] * v + e[6];
}

function uvY(m:Matrix3, u:Number, v:Number):Number
{
    var e:Vector.<Number> = m.elements;
    return e[1] * u + e[4] * v + e[7];
}

// ---------------------------------------------------------------------------
// A. Matrix3.setUvTransform
// ---------------------------------------------------------------------------
var m:Matrix3 = new Matrix3();
m.setUvTransform(0, 0, 1, 1, 0, 0, 0);
check("A1 default transform is identity",
      m.elements[0] == 1 && m.elements[1] == 0 && m.elements[2] == 0 &&
      m.elements[3] == 0 && m.elements[4] == 1 && m.elements[5] == 0 &&
      m.elements[6] == 0 && m.elements[7] == 0 && m.elements[8] == 1);

m.setUvTransform(0, 0, 2, 3, 0, 0, 0);
check("A2 repeat scales the diagonal and nothing else",
      near(m.elements[0], 2) && near(m.elements[4], 3) &&
      near(m.elements[3], 0) && near(m.elements[1], 0) &&
      near(m.elements[6], 0) && near(m.elements[7], 0));

m.setUvTransform(0.5, 0.25, 1, 1, 0, 0, 0);
check("A3 offset lands in the translation column",
      near(m.elements[6], 0.5) && near(m.elements[7], 0.25) &&
      near(m.elements[0], 1) && near(m.elements[4], 1));

// 90 degrees about (0,0): u' = v, v' = -u.
m.setUvTransform(0, 0, 1, 1, Math.PI / 2, 0, 0);
check("A4 rotation 90deg maps (1,0) to (0,-1)",
      near(uvX(m, 1, 0), 0, 1e-12) && near(uvY(m, 1, 0), -1, 1e-12));
check("A5 rotation 90deg maps (0,1) to (1,0)",
      near(uvX(m, 0, 1), 1, 1e-12) && near(uvY(m, 0, 1), 0, 1e-12));

// Rotating about the centre must fix the centre: this is what makes a rotated
// tile stay on its quad instead of swinging off it.
m.setUvTransform(0, 0, 1, 1, 0.7, 0.5, 0.5);
check("A6 rotation about center(0.5,0.5) keeps the centre fixed",
      near(uvX(m, 0.5, 0.5), 0.5, 1e-12) && near(uvY(m, 0.5, 0.5), 0.5, 1e-12));

m.setUvTransform(0, 0, 1, 1, Math.PI * 2, 0.25, 0.75);
check("A7 rotation 2*PI is the identity",
      near(uvX(m, 0.3, 0.8), 0.3, 1e-12) && near(uvY(m, 0.3, 0.8), 0.8, 1e-12));

// setUvTransform must keep the bottom row (0,0,1), or `matrix` is not affine
// any more and a future mat3 multiply would produce garbage.
check("A8 bottom row stays (0,0,1)",
      near(m.elements[2], 0) && near(m.elements[5], 0) && near(m.elements[8], 1));

// ---------------------------------------------------------------------------
// B. Texture fields -> matrix
// ---------------------------------------------------------------------------
var t:Texture = new Texture(null);
check("B1 matrixAutoUpdate defaults to true", t.matrixAutoUpdate);
check("B2 new Texture is the identity transform", AGALRenderer.uvIsIdentity(t));
check("B3 repeat defaults to (1,1)", t.repeat.x == 1 && t.repeat.y == 1);
check("B4 offset defaults to (0,0)", t.offset.x == 0 && t.offset.y == 0);
check("B5 center defaults to (0,0)", t.center.x == 0 && t.center.y == 0);

t.repeat.set(4, 4);
t.updateMatrix();
check("B6 updateMatrix folds repeat into the matrix",
      near(t.matrix.elements[0], 4) && near(t.matrix.elements[4], 4));
check("B7 a tiled texture is not the identity transform", !AGALRenderer.uvIsIdentity(t));

t.offset.set(0.5, -0.25);
t.updateMatrix();
check("B8 updateMatrix folds offset into the matrix",
      near(t.matrix.elements[6], 0.5) && near(t.matrix.elements[7], -0.25));

// WebGLMaterials.refreshTransformUniform refreshes while matrixAutoUpdate is
// true and otherwise uses the matrix verbatim.
var auto:Texture = new Texture(null);
auto.repeat.set(2, 2);
AGALRenderer.uvMatrixOf(auto);
check("B9 autoUpdate refreshes the matrix on demand",
      near(auto.matrix.elements[0], 2));
auto.repeat.set(3, 3);
AGALRenderer.uvMatrixOf(auto);
check("B10 autoUpdate picks up a later repeat change",
      near(auto.matrix.elements[0], 3));

var manual:Texture = new Texture(null);
manual.matrixAutoUpdate = false;
manual.matrix.setUvTransform(0, 0, -1, 1, 0, 0, 0);
manual.repeat.set(7, 7);
AGALRenderer.uvMatrixOf(manual);
check("B11 matrixAutoUpdate=false keeps the authored matrix",
      near(manual.matrix.elements[0], -1));
check("B12 uvMatrixOf(null) is null (identity slot)", AGALRenderer.uvMatrixOf(null) == null);
check("B13 uvIsIdentity(null) is true", AGALRenderer.uvIsIdentity(null));

// ---------------------------------------------------------------------------
// C. Constant packing (the two dp4 rows)
// ---------------------------------------------------------------------------
var rows:Vector.<Number> = new Vector.<Number>(8);
AGALRenderer.uvRowsInto(rows, 0, null);
check("C1 null matrix packs identity rows",
      rows[0] == 1 && rows[1] == 0 && rows[2] == 0 && rows[3] == 0 &&
      rows[4] == 0 && rows[5] == 1 && rows[6] == 0 && rows[7] == 0);

var mm:Matrix3 = new Matrix3();
mm.setUvTransform(0.5, 0.25, 2, 3, 0, 0, 0);
AGALRenderer.uvRowsInto(rows, 0, mm);
check("C2 repeat(2,3) + offset(0.5,0.25) packs (2,0,0,0.5)/(0,3,0,0.25)",
      near(rows[0], 2) && near(rows[1], 0) && near(rows[2], 0) && near(rows[3], 0.5) &&
      near(rows[4], 0) && near(rows[5], 3) && near(rows[6], 0) && near(rows[7], 0.25));

// The .z slot of each row is multiplied by va2.z, which Stage3D supplies as 0
// for a FLOAT_2 attribute; it must stay 0 so a stray value cannot leak in.
check("C3 the z coefficient is pinned to 0", rows[2] == 0 && rows[6] == 0);

// ---------------------------------------------------------------------------
// D. dot((u,v,0,1), row) == three.js mat3 * (u,v,1)
// ---------------------------------------------------------------------------
var probeM:Matrix3 = new Matrix3();
probeM.setUvTransform(0.125, -0.375, 2.5, 0.75, 1.1, 0.4, 0.6);
AGALRenderer.uvRowsInto(rows, 0, probeM);
var okD:Boolean = true;
var us:Vector.<Number> = new Vector.<Number>(4);
us[0] = 0; us[1] = 0.25; us[2] = 0.5; us[3] = 1;
var ci:int;
for (ci = 0; ci < 4; ci++)
{
    var u:Number = us[ci];
    var v:Number = us[3 - ci];
    // dp4 against (u, v, 0, 1)
    var sx:Number = u * rows[0] + v * rows[1] + 0 * rows[2] + 1 * rows[3];
    var sy:Number = u * rows[4] + v * rows[5] + 0 * rows[6] + 1 * rows[7];
    if (!near(sx, uvX(probeM, u, v), 1e-12)) okD = false;
    if (!near(sy, uvY(probeM, u, v), 1e-12)) okD = false;
}
check("D1 packed rows reproduce mat3 * (u,v,1) for every sample", okD);

// A translate-only matrix is the sharpest test of the `.w = 1` assumption: if
// the hardware supplied w = 0 instead, the offset would vanish and the sampled
// texel would not move.
var trans:Matrix3 = new Matrix3();
trans.setUvTransform(0.5, 0.5, 1, 1, 0, 0, 0);
AGALRenderer.uvRowsInto(rows, 0, trans);
var dotU:Number = 0 * rows[0] + 0 * rows[1] + 0 * rows[2] + 1 * rows[3];
check("D2 a pure offset survives the dot product", near(dotU, 0.5));

// ---------------------------------------------------------------------------
// E. Slot -> varying map
// ---------------------------------------------------------------------------
var map:String = "";
var si:int;
for (si = 0; si < AGALRenderer.UV_SLOTS; si++)
{
    if (si > 0) map += ",";
    map += AGALRenderer.uvVaryingOf(si);
}
check("E1 six slots", AGALRenderer.UV_SLOTS == 6);
check("E2 the six slots read six distinct pairs, in slot order",
      map == "v2.xy,v2.zw,v6.xy,v6.zw,v7.xy,v7.zw");
check("E3 map slot is v2.xy", AGALRenderer.uvVaryingOf(AGALRenderer.UV_MAP) == "v2.xy");
check("E4 normal slot is v2.zw (the derivative pair lives in .zw)",
      AGALRenderer.uvVaryingOf(AGALRenderer.UV_NORMAL) == "v2.zw");
check("E5 roughness/metalness share v6",
      AGALRenderer.uvVaryingOf(AGALRenderer.UV_ROUGHNESS) == "v6.xy" &&
      AGALRenderer.uvVaryingOf(AGALRenderer.UV_METALNESS) == "v6.zw");
check("E6 emissive/ao share v7",
      AGALRenderer.uvVaryingOf(AGALRenderer.UV_EMISSIVE) == "v7.xy" &&
      AGALRenderer.uvVaryingOf(AGALRenderer.UV_AO) == "v7.zw");

// ---------------------------------------------------------------------------
// F. The emitted vertex block
// ---------------------------------------------------------------------------
var block:String = AGALRenderer.uvTransformBlock();
check("F1 uvTransformBlock is not null (AS3 return-ASI trap)", block != null);
if (block == null) block = "";
var lines:Array = block.split("\n");
var count:int = 0;
var li:int;
for (li = 0; li < lines.length; li++)
{
    if (lines[li].length > 0) count++;
}
check("F2 the block is 16 instructions", count == 16);
check("F3 twelve dp4 + four mov",
      countOf(block, "dp4 ") == 12 && countOf(block, "mov ") == 4);

var allConsts:Boolean = true;
var k:int;
for (k = 0; k < 12; k++)
{
    if (block.indexOf("vc" + (AGALRenderer.UV_CONST_BASE + k) + "\n") < 0) allConsts = false;
}
check("F4 every vc40..vc51 row is referenced", allConsts);
check("F5 the last constant is below AIR's 128 vertex registers",
      AGALRenderer.UV_CONST_BASE + 11 < 128);
check("F6 the block writes v2, v3, v6 and v7",
      block.indexOf("mov v2, vt3") >= 0 && block.indexOf("mov v3, vt3") >= 0 &&
      block.indexOf("mov v6, vt4") >= 0 && block.indexOf("mov v7, vt4") >= 0);
check("F7 no stray null/empty line slipped in", block.indexOf("null") < 0);

// ---------------------------------------------------------------------------
trace(failed == 0 ? "ALL PASS" : ("FAILED " + failed));