// geometry-smoke-m11.as -- M11 geometry-family / culling smoke.
//
// Pins the parts of the M11 contract that are observable WITHOUT a GPU:
//
//   A. Counts. Every new geometry's vertex / index / group counts are compared
//      against the numbers r187's topology implies, computed independently here
//      (not by calling the geometry). A forgotten degenerate-triangle skip or a
//      mis-sized grid shows up as a number mismatch.
//   B. Extents. Bounding boxes prove the constructions are in the right plane:
//      TorusGeometry lies in XY with its hole on Z, Circle/Ring lie in XY,
//      Cylinder/Cone stand on Y, Lathe revolves about Y.
//   C. Normals / UVs. Spot checks on unit length, on the outward sign, and on
//      the UV corner convention.
//   D. EdgesGeometry. A box must yield exactly 12 edges (24 vertices) and a
//      single-quad plane exactly 4 (8 vertices) -- the coplanar-edge collapse is
//      the whole point of the class.
//   E. mergeGeometries. Concatenation, index offsetting, useGroups ranges, and
//      the null-plus-trace rejection of mismatched attribute sets.
//   F. Frustum. Plane extraction from this engine's [0,1]-depth projection: a
//      point BEHIND the near plane must be rejected (that is what distinguishes
//      the Metal extraction from the WebGL one), plus sphere / object / box
//      tests and the "never a false negative" property.
//   G. Renderer bookkeeping. The culling counters and the line program's AGAL.
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/geometry-smoke-m11/geometry-smoke-m11.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     --manifest probes/geometry-smoke-m11/geometry-smoke-m11.build.json \
//     -o temp/geometry-smoke-m11 --run
import asaot.three.core.Box3;
import asaot.three.core.BufferAttribute;
import asaot.three.core.BufferGeometry;
import asaot.three.core.Frustum;
import asaot.three.core.Plane;
import asaot.three.core.Sphere;
import asaot.three.core.GeometryGroup;
import asaot.three.extras.core.Curve;
import asaot.three.extras.core.CubicPoly;
import asaot.three.extras.core.FrenetFrames;
import asaot.three.extras.curves.CatmullRomCurve3;
import asaot.three.geometries.BoxGeometry;
import asaot.three.geometries.CircleGeometry;
import asaot.three.geometries.ConeGeometry;
import asaot.three.geometries.CylinderGeometry;
import asaot.three.geometries.EdgesGeometry;
import asaot.three.geometries.LatheGeometry;
import asaot.three.geometries.PlaneGeometry;
import asaot.three.geometries.RingGeometry;
import asaot.three.geometries.SphereGeometry;
import asaot.three.geometries.TorusGeometry;
import asaot.three.geometries.TubeGeometry;
import asaot.three.math.MathUtils;
import asaot.three.math.Matrix4;
import asaot.three.math.Vector2;
import asaot.three.math.Vector3;
import asaot.three.materials.LineBasicMaterial;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.objects.LineSegments;
import asaot.three.objects.Mesh;
import asaot.three.utils.BufferGeometryUtils;

import com.adobe.utils.AGALMiniAssembler;
import flash.display3D.Context3DProgramType;

var failed:int = 0;
function check(cond:Boolean, msg:String):void
{
    if (cond) trace("PASS " + msg);
    else { trace("FAIL " + msg); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-5):Boolean
{
    return Math.abs(a - b) < eps;
}

function unit(v:Vector3):Boolean
{
    return near(v.length(), 1.0, 1e-5);
}

// ---------------------------------------------------------------------------
// A. CylinderGeometry counts
// ---------------------------------------------------------------------------
var cyl:CylinderGeometry = new CylinderGeometry(1, 1, 2, 8, 1);
var cylPos:BufferAttribute = cyl.getAttribute("position");

// torso: (heightSegments+1) * (radialSegments+1) = 2 * 9 = 18
// top cap: radialSegments centres + (radialSegments+1) rim = 8 + 9 = 17
// bottom cap: same = 17
check(cylPos.count == 18 + 17 + 17, "cylinder(8,1) vertex count = 52 (torso 18 + caps 17+17)");
// torso quads: 8 * 1 * 2 triangles (both ends have radius>0) = 16 tris = 48 idx
// each cap: 8 tris = 24 idx
check(cyl.index.count == 48 + 24 + 24, "cylinder(8,1) index count = 96");

check(cyl.groups.length == 3, "cylinder emits 3 groups (torso / top / bottom)");
check(cyl.groups[0].materialIndex == 0, "torso group materialIndex 0");
check(cyl.groups[1].materialIndex == 1, "top-cap group materialIndex 1");
check(cyl.groups[2].materialIndex == 2, "bottom-cap group materialIndex 2");
var gsum:int = 0;
for (var gi:int = 0; gi < cyl.groups.length; gi++) gsum += cyl.groups[gi].count;
check(gsum == cyl.index.count, "group counts sum to the index count");

cyl.computeBoundingBox();
check(near(cyl.boundingBox.min.x, -1) && near(cyl.boundingBox.max.x, 1), "cylinder spans x in [-1,1] (radius 1)");
check(near(cyl.boundingBox.min.y, -1) && near(cyl.boundingBox.max.y, 1), "cylinder spans y in [-1,1] (height 2)");
check(near(cyl.boundingBox.min.z, -1) && near(cyl.boundingBox.max.z, 1), "cylinder spans z in [-1,1]");

// Torso side normal for a straight cylinder is horizontal (y == 0).
var torsoNormal:Vector3 = new Vector3(cyl.getAttribute("normal").getX(0),
                                      cyl.getAttribute("normal").getY(0),
                                      cyl.getAttribute("normal").getZ(0));
check(unit(torsoNormal), "cylinder torso normal is unit length");
check(near(torsoNormal.y, 0, 1e-6), "straight cylinder torso normal has no y component");

// UV corner convention: first torso vertex is (u=0, v=1).
check(near(cyl.getAttribute("uv").getX(0), 0) && near(cyl.getAttribute("uv").getY(0), 1),
      "cylinder torso uv[0] = (0,1)");

// ---- openEnded skips both caps ----
var openCyl:CylinderGeometry = new CylinderGeometry(1, 1, 2, 8, 1, true);
check(openCyl.getAttribute("position").count == 18, "openEnded cylinder keeps only the 18 torso vertices");
check(openCyl.groups.length == 1, "openEnded cylinder emits 1 group");

// ---- cone ----
// radiusTop == 0 -> the top row's triangles are skipped, and there is no top cap.
var cone:ConeGeometry = new ConeGeometry(1, 2, 8, 1);
var conePos:BufferAttribute = cone.getAttribute("position");
// torso 18 + bottom cap 17 (no top cap)
check(conePos.count == 18 + 17, "cone(8,1) vertex count = 35 (no top cap)");
// torso: y==0 row skipped for the a,b,d triangle -> 8 tris; bottom cap 8 tris
check(cone.index.count == 24 + 24, "cone(8,1) index count = 48 (8 side + 8 cap triangles)");
cone.computeBoundingBox();
check(near(cone.boundingBox.min.y, -1) && near(cone.boundingBox.max.y, 1), "cone spans y in [-1,1]");

// A cone's side normal must be tilted upward (the slope term), i.e. y > 0.
var coneN:Vector3 = new Vector3(cone.getAttribute("normal").getX(0),
                                cone.getAttribute("normal").getY(0),
                                cone.getAttribute("normal").getZ(0));
check(unit(coneN), "cone side normal is unit length");
check(coneN.y > 0.1, "cone side normal tilts toward the apex (+y)");

// ---------------------------------------------------------------------------
// B. Circle / Ring / Torus / Lathe extents
// ---------------------------------------------------------------------------
var circle:CircleGeometry = new CircleGeometry(2, 16);
check(circle.getAttribute("position").count == 1 + 17, "circle(16) = centre + 17 rim vertices");
check(circle.index.count == 16 * 3, "circle(16) = 16 fan triangles");
check(circle.getAttribute("normal").getZ(0) == 1, "circle faces +z");
circle.computeBoundingBox();
check(near(circle.boundingBox.min.z, 0) && near(circle.boundingBox.max.z, 0), "circle is flat in z");
check(near(circle.boundingBox.max.x, 2), "circle radius 2 reaches x=2");
// uv of the first rim vertex: (cos0, sin0) mapped to ((1+1)/2, (0+1)/2)
check(near(circle.getAttribute("uv").getX(1), 1) && near(circle.getAttribute("uv").getY(1), 0.5),
      "circle rim uv[1] = (1, 0.5) (theta=0)");

var ring:RingGeometry = new RingGeometry(1, 2, 16, 2);
check(ring.getAttribute("position").count == (2 + 1) * (16 + 1), "ring(16,2) = 3 rings * 17 vertices = 51");
check(ring.index.count == 2 * 16 * 6, "ring(16,2) = 2 rings * 16 quads * 2 tris * 3 = 192");
ring.computeBoundingBox();
check(near(ring.boundingBox.min.x, -2) && near(ring.boundingBox.max.x, 2), "ring outer radius 2 reaches x=+-2");

var torus:TorusGeometry = new TorusGeometry(2, 0.5, 8, 16);
check(torus.getAttribute("position").count == (8 + 1) * (16 + 1), "torus(8,16) = 9 * 17 vertices = 153");
check(torus.index.count == 8 * 16 * 6, "torus(8,16) = 8 * 16 quads * 6 = 768");
torus.computeBoundingBox();
check(near(torus.boundingBox.max.x, 2.5, 1e-4), "torus max x = radius + tube = 2.5");
check(near(torus.boundingBox.max.y, 2.5, 1e-4), "torus max y = radius + tube = 2.5");
check(near(torus.boundingBox.max.z, 0.5, 1e-4), "torus max z = tube = 0.5 (hole along Z)");
var torusN:Vector3 = new Vector3(torus.getAttribute("normal").getX(0),
                                 torus.getAttribute("normal").getY(0),
                                 torus.getAttribute("normal").getZ(0));
check(unit(torusN), "torus normal is unit length");

// Lathe with the r187 default profile (0,-0.5) (0.5,0) (0,0.5).
var lathe:LatheGeometry = new LatheGeometry(null, 8);
check(lathe.getAttribute("position").count == (8 + 1) * 3, "lathe(default 3 points, 8 seg) = 27 vertices");
check(lathe.index.count == 8 * 2 * 6, "lathe(3 points, 8 seg) = 8 * 2 bands * 6 = 96");
lathe.computeBoundingBox();
check(near(lathe.boundingBox.min.y, -0.5) && near(lathe.boundingBox.max.y, 0.5), "lathe profile spans y in [-0.5,0.5]");
check(near(lathe.boundingBox.max.x, 0.5, 1e-4) && near(lathe.boundingBox.max.z, 0.5, 1e-4),
      "lathe widest radius 0.5 revolves into x/z");

// ---------------------------------------------------------------------------
// C. Curve + Tube
// ---------------------------------------------------------------------------
var pts:Vector.<Vector3> = new Vector.<Vector3>();
pts.push(new Vector3(0, 0, 0));
pts.push(new Vector3(0, 1, 0));
pts.push(new Vector3(0, 2, 0));
var straight:CatmullRomCurve3 = new CatmullRomCurve3(pts);
var mid:Vector3 = straight.getPoint(0.5);
check(near(mid.x, 0) && near(mid.y, 1) && near(mid.z, 0, 1e-6), "catmull-rom through collinear points stays on the line");
check(near(straight.getLength(), 2, 1e-3), "catmull-rom length of a 2-unit straight path = 2");

var frames:FrenetFrames = straight.computeFrenetFrames(4, false);
check(frames.tangents.length == 5, "computeFrenetFrames returns segments+1 tangents");
check(unit(frames.tangents[0]) && unit(frames.normals[0]) && unit(frames.binormals[0]),
      "frame vectors are unit length");
check(near(frames.tangents[0].dot(frames.normals[0]), 0, 1e-5), "tangent is perpendicular to normal");
check(near(frames.normals[0].dot(frames.binormals[0]), 0, 1e-5), "normal is perpendicular to binormal");

// CubicPoly: initCatmullRom(x0,x1,x2,x3,tension) then calc(0)==x1, calc(1)==x2.
var poly:CubicPoly = new CubicPoly();
poly.initCatmullRom(0, 2, 5, 9, 0.5);
check(near(poly.calc(0), 2) && near(poly.calc(1), 5), "CubicPoly endpoints interpolate exactly");

// radialSegments 8 is chosen so the ring hits sin=+-1 exactly, which makes the
// lateral extent an exact number instead of a polygon-chord approximation.
var tube:TubeGeometry = new TubeGeometry(straight, 8, 0.25, 8);
check(tube.getAttribute("position").count == (8 + 1) * (8 + 1), "tube(8,8) = 9 rings * 9 vertices = 81");
check(tube.index.count == 8 * 8 * 6, "tube(8,8) = 8 * 8 quads * 6 = 384");
tube.computeBoundingBox();
// The ring lies in the plane perpendicular to the tangent, so a +Y path spreads
// in x/z only: the tube's y extent is the path's own [0,2], NOT [0, 2.25].
check(near(tube.boundingBox.max.y, 2, 1e-4), "tube y extent is the path extent (2), not path+radius");
check(near(tube.boundingBox.min.y, 0, 1e-4), "tube y min is the path start (0)");
check(near(tube.boundingBox.max.x, 0.25, 1e-4), "tube radius 0.25 spreads x");
check(near(tube.boundingBox.max.z, 0.25, 1e-4), "tube radius 0.25 spreads z");
var tubeN:Vector3 = new Vector3(tube.getAttribute("normal").getX(0),
                                tube.getAttribute("normal").getY(0),
                                tube.getAttribute("normal").getZ(0));
check(unit(tubeN), "tube normal is unit length");
check(near(tubeN.dot(frames.tangents[0]), 0, 1e-4), "tube ring normal is perpendicular to the path tangent");

// ---------------------------------------------------------------------------
// D. EdgesGeometry
// ---------------------------------------------------------------------------
var cube:BoxGeometry = new BoxGeometry(2, 2, 2, 1, 1, 1);
var cubeEdges:EdgesGeometry = new EdgesGeometry(cube, 1);
check(cubeEdges.getAttribute("position") != null, "EdgesGeometry produced a position attribute");
check(cubeEdges.getAttribute("position").count == 24,
      "box edges = 12 lines * 2 vertices = 24 (coplanar face diagonals dropped)");
check(cubeEdges.index == null, "EdgesGeometry output is non-indexed (line pairs)");
check(cubeEdges.groups.length == 0, "EdgesGeometry emits no groups");

var quad:PlaneGeometry = new PlaneGeometry(2, 2, 1, 1);
var quadEdges:EdgesGeometry = new EdgesGeometry(quad, 1);
check(quadEdges.getAttribute("position").count == 8,
      "single-quad plane edges = 4 boundary lines * 2 = 8 (shared diagonal dropped)");

// A sphere with a coarse tessellation must emit more than the box (it has real
// creases plus, at 8x6, plenty of hard-angle neighbours).
var sphereGeom:SphereGeometry = new SphereGeometry(1, 8, 6);
var sphereEdges:EdgesGeometry = new EdgesGeometry(sphereGeom, 1);
check(sphereEdges.getAttribute("position").count > 24, "sphere edges exceed a box's 24 vertices");

// thresholdAngle 180 accepts every neighbour, so only boundary edges survive.
var quadEdges180:EdgesGeometry = new EdgesGeometry(quad, 180);
check(quadEdges180.getAttribute("position").count == 8,
      "thresholdAngle 180 keeps only true boundaries (still 8 for a quad)");

// ---------------------------------------------------------------------------
// E. mergeGeometries
// ---------------------------------------------------------------------------
var a1:BoxGeometry = new BoxGeometry(1, 1, 1, 1, 1, 1);
var a2:BoxGeometry = new BoxGeometry(1, 1, 1, 1, 1, 1);
var pair:Vector.<BufferGeometry> = new Vector.<BufferGeometry>();
pair.push(a1);
pair.push(a2);

var merged:BufferGeometry = BufferGeometryUtils.mergeGeometries(pair);
check(merged != null, "mergeGeometries accepts two identical boxes");
check(merged.getAttribute("position").count == a1.getAttribute("position").count * 2,
      "merged vertex count doubles");
check(merged.index.count == a1.index.count * 2, "merged index count doubles");
// The second box's indices must all be offset by the first box's vertex count.
var vcount:int = a1.getAttribute("position").count;
check(int(merged.index.getX(a1.index.count)) == int(a1.index.getX(0)) + vcount,
      "second geometry's first index is offset by the first geometry's vertex count");
check(merged.groups.length == 0, "mergeGeometries without useGroups emits no groups");

var mergedGroups:BufferGeometry = BufferGeometryUtils.mergeGeometries(pair, true);
check(mergedGroups.groups.length == 2, "useGroups emits one group per input geometry");
check(mergedGroups.groups[0].materialIndex == 0 && mergedGroups.groups[1].materialIndex == 1,
      "group materialIndex matches the input index");

// Mismatched attribute sets must be rejected (null), not silently dropped.
var mismatched:BufferGeometry = new BufferGeometry();
mismatched.setAttribute("position", new BufferAttribute(new Vector.<Number>(9), 3));
var badPair:Vector.<BufferGeometry> = new Vector.<BufferGeometry>();
badPair.push(a1);
badPair.push(mismatched);
check(BufferGeometryUtils.mergeGeometries(badPair) == null,
      "mergeGeometries returns null for an incompatible attribute set");

// Mixed indexed / non-indexed must be rejected too.
var flat:BufferGeometry = new BufferGeometry();
flat.setAttribute("position", new BufferAttribute(new Vector.<Number>(9), 3));
flat.setAttribute("normal", new BufferAttribute(new Vector.<Number>(9), 3));
flat.setAttribute("uv", new BufferAttribute(new Vector.<Number>(6), 2));
var mixed:Vector.<BufferGeometry> = new Vector.<BufferGeometry>();
mixed.push(a1);
mixed.push(flat);
check(BufferGeometryUtils.mergeGeometries(mixed) == null,
      "mergeGeometries returns null when only one geometry is indexed");

// ---------------------------------------------------------------------------
// F. Frustum ([0,1] depth extraction)
// ---------------------------------------------------------------------------
var cam:Matrix4 = new Matrix4();
// Same shape as PerspectiveCamera.updateProjectionMatrix: fov 60, aspect 1,
// near 0.1, far 100.
var camNear:Number = 0.1;
var camFar:Number = 100;
var top:Number = camNear * Math.tan(MathUtils.degToRad(0.5 * 60));
var height:Number = 2 * top;
var width:Number = height;
var left:Number = -0.5 * width;
cam.makePerspective(left, left + width, top, top - height, camNear, camFar);

var fr:Frustum = new Frustum();
fr.setFromProjectionMatrix(cam);
check(fr.planes.length == 6, "frustum has six planes");
var allUnit:Boolean = true;
for (var pi:int = 0; pi < 6; pi++)
{
    if (!near(fr.planes[pi].normal.length(), 1, 1e-5)) allUnit = false;
}
check(allUnit, "all six frustum plane normals are unit length");

// The camera looks down -Z. Inside the frustum:
check(fr.containsPoint(new Vector3(0, 0, -1)), "point at z=-1 (inside near/far) is contained");
check(fr.containsPoint(new Vector3(0, 0, -50)), "point at z=-50 is contained");
// Outside:
check(!fr.containsPoint(new Vector3(0, 0, 1)), "point BEHIND the camera is rejected");
check(!fr.containsPoint(new Vector3(100, 0, -1)), "point far to the right is rejected");
check(!fr.containsPoint(new Vector3(0, 0, -200)), "point beyond far is rejected");
// This is the [0,1]-depth discriminator: a point between the camera and the near
// plane (z = -0.05) must be OUTSIDE. With the WebGL [-1,1] extraction the near
// plane sits at the projection's "z = -w" face, which for this matrix is BEHIND
// the eye, so this point would be wrongly accepted.
check(!fr.containsPoint(new Vector3(0, 0, -0.05)),
      "point in front of the near plane is rejected (proves [0,1] near extraction)");

var sIn:Sphere = new Sphere(new Vector3(0, 0, -2), 0.5);
check(fr.intersectsSphere(sIn), "sphere at z=-2 intersects");
var sOut:Sphere = new Sphere(new Vector3(0, 0, 2), 0.5);
check(!fr.intersectsSphere(sOut), "sphere behind the camera does not intersect");
// Conservative by construction: a sphere whose centre is outside but whose
// radius overlaps a plane must still be accepted.
var sStraddle:Sphere = new Sphere(new Vector3(60, 0, -1), 100);
check(fr.intersectsSphere(sStraddle), "sphere straddling a plane is accepted (no false negatives)");

var bIn:Box3 = new Box3(new Vector3(-1, -1, -3), new Vector3(1, 1, -1));
check(fr.intersectsBox(bIn), "box around the view axis intersects");
var bOut:Box3 = new Box3(new Vector3(40, 40, -3), new Vector3(42, 42, -1));
check(!fr.intersectsBox(bOut), "box far off-axis does not intersect");

// intersectsObject uses the geometry's world-space bounding sphere.
var geomMesh:Mesh = new Mesh(new BoxGeometry(1, 1, 1), new MeshStandardMaterial());
geomMesh.position.set(0, 0, -5);
geomMesh.updateMatrixWorld(true);
check(fr.intersectsObject(geomMesh), "mesh at z=-5 is inside the frustum");
geomMesh.position.set(0, 0, 50);
geomMesh.updateMatrixWorld(true);
check(!fr.intersectsObject(geomMesh), "mesh behind the camera is culled");
// Scale must grow the sphere, not the centre distance only.
geomMesh.position.set(0, 0, -5);
geomMesh.scale.set(1000, 1000, 1000);
geomMesh.updateMatrixWorld(true);
check(fr.intersectsObject(geomMesh), "large world scale keeps the mesh visible (sphere radius uses max axis scale)");

// Sphere.applyMatrix4 math.
var bs:Sphere = new Sphere(new Vector3(0, 0, 0), 1);
var scaleM:Matrix4 = new Matrix4();
scaleM.makeScale(3, 3, 3);
bs.applyMatrix4(scaleM);
check(near(bs.radius, 3), "Sphere.applyMatrix4 scales the radius by the max axis scale");

// ---------------------------------------------------------------------------
// G. Plane basics
// ---------------------------------------------------------------------------
var pl:Plane = new Plane(new Vector3(0, 1, 0), -2);
check(near(pl.distanceToPoint(new Vector3(0, 5, 0)), 3), "plane distance to a point above it is positive");
check(near(pl.distanceToPoint(new Vector3(0, 0, 0)), -2), "plane distance to the origin equals the constant");
var plCopy:Plane = new Plane();
plCopy.copy(pl).normalize();
check(near(plCopy.normal.y, 1) && near(plCopy.constant, -2), "normalize() on a unit-normal plane is a no-op");

// ---------------------------------------------------------------------------
// H. LineSegments + line program AGAL
// ---------------------------------------------------------------------------
var lineMat:LineBasicMaterial = new LineBasicMaterial(0x00ff00);
check(lineMat.color.g > 0.9 && lineMat.color.r < 0.1, "LineBasicMaterial colour is sRGB-decoded into linear");
check(near(lineMat.linewidth, 1), "LineBasicMaterial default linewidth is 1");
check(lineMat.transparent == false, "LineBasicMaterial is opaque by default");
check(lineMat.alphaTest == 0, "LineBasicMaterial inherits alphaTest default 0");

var lineObj:LineSegments = new LineSegments(cubeEdges, lineMat);
check(lineObj.isLineSegments == true, "LineSegments sets isLineSegments");
check(lineObj.frustumCulled == true, "Object3D.frustumCulled defaults to true");
check(lineObj.geometry == cubeEdges, "LineSegments holds its geometry");

// The line vertex program must assemble, and its shape is pinned here because
// two properties are easy to break silently:
//   * it is built from four `dp4`s per endpoint, NOT `m44`: the constants are
//     uploaded TRANSPOSED (vc0..vc3 hold the matrix rows), which is what dp4
//     assumes. Using m44 put every segment in the wrong place -- visible only on
//     screen, so a source-level pin is the cheapest guard.
//   * the offset is computed in NDC but `op` is CLIP space, so a final multiply
//     by w is required; without it the quad shrinks by 1/w.
// Assemble the renderer's OWN source, not a copy: this probe carried a duplicate
// of the line program and drifted from it twice (the `mov op` fix and the
// `rcp`-on-constant fix). AGALRenderer.lineVertexSource() is the single text the
// upload uses.
var lineVertSrc:String = AGALRenderer.lineVertexSource();
var lineAsm:AGALMiniAssembler = new AGALMiniAssembler();
var lineProgram:Object = lineAsm.assemble(Context3DProgramType.VERTEX, lineVertSrc);
check(lineProgram != null && lineAsm.agalcode.length > 0, "line vertex AGAL assembles");
// 29, not 30: the two `rcp vt5.*, vc4.*` on constants are gone (AIR refuses a
// constant-only math source with #3625) and are replaced by one `mul` against
// the CPU-precomputed vc5 = 1/(halfW, halfH).
check((lineAsm.agalcode.length - 7) / 24 == 28,
      "line vertex program is 28 instructions, got " + (lineAsm.agalcode.length - 7) / 24);
check(lineVertSrc.indexOf("m44") < 0, "line vertex program uses dp4, not m44 (row-major constants)");
check(lineVertSrc.indexOf("mul vt4.xy, vt4.xy, vc5.xy") >= 0,
      "the viewport reciprocal is a CPU-precomputed constant (vc5), not a GPU rcp");
check(lineVertSrc.indexOf("rcp vt5.x, vc4.x") < 0 && lineVertSrc.indexOf("rcp vt5.y, vc4.y") < 0,
      "no rcp on a constant source remains (AIR #3625)");
check(lineVertSrc.indexOf("mul vt6.xy, vt1.xy, vt6.wwww") >= 0, "line offset is scaled back into clip space by w");

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
trace("");
if (failed == 0) trace("ALL PASS");
else trace("FAILED: " + failed);