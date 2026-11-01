// asaot3d/probes/interaction-smoke-m14/InteractionSmokeM14.as -- M14 interaction smoke.
//
// Pins the parts of the M14 contract that are observable WITHOUT a GPU:
//
//   A. Ray: at/recast, the two distance queries, and the intersection primitives
//      (triangle -- including the watertight shared-edge case, sphere with the
//      "origin inside" branch, plane, box). These are the arithmetic underneath
//      picking; if one of them returns a point behind the origin, a click lands
//      on geometry that is BEHIND the camera.
//   B. Raycaster.setFromCamera / setFromPointer: the NDC conversion between AIR
//      stage pixels (top-left, y down) and three.js NDC (centre, y up), the
//      perspective branch (origin at the camera, direction through the unprojected
//      point) and the orthographic branch (origin on the camera plane, direction =
//      camera forward).
//   C. Mesh.raycast: FrontSide/DoubleSide/BackSide winding, near/far window,
//      world-space hit point and distance, interpolated uv/normal, face normals,
//      barycentric weights, recursive vs non-recursive traversal, distance sort,
//      drawRange, non-indexed geometry and object transforms.
//   D. OrbitControls: the r187 spherical update (rotate/zoom/pan), the polar and
//      azimuth clamps, distance clamps, damping convergence, autoRotate, and
//      saveState/reset -- plus the AIR event bridge itself, driven by real
//      MouseEvents dispatched at a Sprite (down -> move -> up, and a wheel).
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/interaction-smoke-m14/InteractionSmokeM14.as \
//     $(find kit -name '*.as') -o temp/interaction-smoke-m14 --run
import asaot.three.cameras.OrthographicCamera;
import asaot.three.cameras.PerspectiveCamera;
import asaot.three.controls.OrbitControls;
import asaot.three.core.BufferAttribute;
import asaot.three.core.BufferGeometry;
import asaot.three.math.Matrix4;
import asaot.three.core.Intersection;
import asaot.three.core.Object3D;
import asaot.three.core.Plane;
import asaot.three.core.Pointer;
import asaot.three.core.Raycaster;
import asaot.three.core.Sphere;
import asaot.three.geometries.BoxGeometry;
import asaot.three.geometries.PlaneGeometry;
import asaot.three.materials.MeshBasicMaterial;
import asaot.three.math.Box3;
import asaot.three.math.Ray;
import asaot.three.math.Spherical;
import asaot.three.math.Triangle;
import asaot.three.math.Vector2;
import asaot.three.math.Vector3;
import asaot.three.objects.Group;
import asaot.three.objects.Mesh;

import flash.display.Sprite;
import flash.events.MouseEvent;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-6):Boolean
{
    return Math.abs(a - b) < eps;
}

function vecNear(v:Vector3, x:Number, y:Number, z:Number, eps:Number = 1e-6):Boolean
{
    return near(v.x, x, eps) && near(v.y, y, eps) && near(v.z, z, eps);
}

function look(camera:PerspectiveCamera, px:Number, py:Number, pz:Number):void
{
    camera.position.set(px, py, pz);
    camera.lookAt(0, 0, 0);
    camera.updateMatrixWorld(true);
}

// ---------------------------------------------------------------------------
// A. Ray primitives.
// ---------------------------------------------------------------------------
var r:Ray = new Ray();
check("A1 default direction is -Z", vecNear(r.direction, 0, 0, -1));
check("A2 at(2) walks the direction", vecNear(r.at(2, new Vector3()), 0, 0, -2));

var r2:Ray = new Ray(new Vector3(0, 0, 0), new Vector3(0, 0, -1));
r2.recast(3);
check("A3 recast moves the origin", vecNear(r2.origin, 0, 0, -3));

var p1:Ray = new Ray(new Vector3(0, 0, 0), new Vector3(1, 0, 0));
check("A4 distanceSqToPoint measures perpendicular distance", near(p1.distanceSqToPoint(new Vector3(5, 3, 4)), 25));
check("A5 a point behind the origin measures to the origin",
      near(p1.distanceSqToPoint(new Vector3(-2, 0, 0)), 4));

// Triangle at z = -5, wound counter-clockwise seen from +Z (front facing +Z).
var triA:Vector3 = new Vector3(-1, -1, -5);
var triB:Vector3 = new Vector3(1, -1, -5);
var triC:Vector3 = new Vector3(0, 1, -5);
var rayZ:Ray = new Ray(new Vector3(0, 0, 0), new Vector3(0, 0, -1));
var triHit:Vector3 = rayZ.intersectTriangle(triA, triB, triC, true, new Vector3());
check("A6 ray hits a front-facing triangle", triHit != null && vecNear(triHit, 0, 0, -5));
check("A7 backfaceCulling rejects the back side",
      rayZ.intersectTriangle(triC, triB, triA, true, new Vector3()) == null);
check("A8 without culling the back side still hits",
      rayZ.intersectTriangle(triC, triB, triA, false, new Vector3()) != null);

// Watertight shared-edge: a ray exactly on the shared edge of two adjacent
// triangles must hit BOTH (this is the failure three.js's algorithm is designed
// to avoid -- see Ray.js:538).
// Two triangles sharing the edge x=0, both wound toward +Z. The ray runs
// EXACTLY along that shared edge; a non-watertight test would fall between the
// two in floating point and report nothing.
var q1:Vector3 = new Vector3(-2, -1, -5);
var q2:Vector3 = new Vector3(0, -1, -5);
var q3:Vector3 = new Vector3(0, 1, -5);
var q4:Vector3 = new Vector3(-2, 1, -5);
// (-1, 0) is the midpoint of the shared edge q1(-2,-1) -> q3(0,1).
var edgeRay:Ray = new Ray(new Vector3(-1, 0, 0), new Vector3(0, 0, -1));
var e1:Vector3 = edgeRay.intersectTriangle(q1, q2, q3, true, new Vector3());
var e2:Vector3 = edgeRay.intersectTriangle(q1, q3, q4, true, new Vector3());
check("A9 shared edge hits both triangles (watertight)",
      e1 != null && e2 != null && near(e1.z, e2.z));

// applyMatrix4: rotate 90 degrees about +Y, so -Z becomes -X.
var rot:Matrix4 = new Matrix4();
rot.makeRotationFromEuler(new asaot.three.math.Euler(0, Math.PI / 2, 0));
var r3:Ray = new Ray(new Vector3(0, 0, 5), new Vector3(0, 0, -1));
r3.applyMatrix4(rot);
check("A10 applyMatrix4 rotates the direction", vecNear(r3.direction, -1, 0, 0, 1e-6));
check("A11 applyMatrix4 moves the origin", vecNear(r3.origin, 5, 0, 0, 1e-6));

var sph:Sphere = new Sphere(new Vector3(0, 0, -10), 1);
var rS:Ray = new Ray(new Vector3(0, 0, 0), new Vector3(0, 0, -1));
check("A12 sphere entry point is the near surface", vecNear(rS.intersectSphere(sph, new Vector3()), 0, 0, -9));
var inside:Ray = new Ray(new Vector3(0, 0, -10), new Vector3(0, 0, -1));
check("A13 ray inside the sphere returns the EXIT point", vecNear(inside.intersectSphere(sph, new Vector3()), 0, 0, -11));
var emptySph:Sphere = new Sphere(new Vector3(), -1);
check("A14 empty sphere never intersects", rS.intersectSphere(emptySph, new Vector3()) == null);
check("A15 sphere behind the ray misses", rS.intersectSphere(new Sphere(new Vector3(0, 0, 5), 1), new Vector3()) == null);
check("A16 side miss on the sphere", new Ray(new Vector3(3, 0, 0), new Vector3(0, 0, -1)).intersectSphere(sph, new Vector3()) == null);

var pl:Plane = new Plane(new Vector3(0, 0, 1), 10); // z = -10
check("A17 plane distance", near(rS.distanceToPlane(pl), 10));
var parallelT:Number = new Ray(new Vector3(0, 0, 0), new Vector3(1, 0, 0)).distanceToPlane(pl);
check("A18 a parallel ray reports no distance (NaN stand-in for null)", parallelT != parallelT);
check("A19 plane intersection point", vecNear(rS.intersectPlane(pl, new Vector3()), 0, 0, -10));

var box:Box3 = new Box3(new Vector3(-1, -1, -11), new Vector3(1, 1, -9));
check("A20 box entry point", vecNear(rS.intersectBox(box, new Vector3()), 0, 0, -9));
check("A21 box behind the origin misses",
      rS.intersectBox(new Box3(new Vector3(-1, -1, 1), new Vector3(1, 1, 3)), new Vector3()) == null);
check("A22 intersectsBox agrees with intersectBox", rS.intersectsBox(box));

// ---------------------------------------------------------------------------
// B. Raycaster.setFromCamera / setFromPointer (the Stage3D bridge).
// ---------------------------------------------------------------------------
var cam:PerspectiveCamera = new PerspectiveCamera(60, 1.5, 0.1, 100);
look(cam, 0, 0, 5);

var ndc:Vector2 = new Vector2();
Pointer.toNDC(320, 240, 640, 480, ndc);
check("B1 viewport centre maps to NDC (0,0)", near(ndc.x, 0) && near(ndc.y, 0));
Pointer.toNDC(0, 0, 640, 480, ndc);
check("B2 stage top-left maps to NDC (-1,+1)", near(ndc.x, -1) && near(ndc.y, 1));
Pointer.toNDC(640, 480, 640, 480, ndc);
check("B3 stage bottom-right maps to NDC (+1,-1)", near(ndc.x, 1) && near(ndc.y, -1));
Pointer.toNDC(100, 100, 0, 0, ndc);
check("B4 a zero-sized viewport still yields finite NDC", ndc.x == ndc.x && ndc.y == ndc.y);
check("B5 isInside accepts the centre and rejects outside",
      Pointer.isInside(10, 10, 640, 480) && !Pointer.isInside(-1, 10, 640, 480) && !Pointer.isInside(10, 480, 640, 480));

var rc:Raycaster = new Raycaster();
check("B6 near/far defaults", near(rc.near, 0) && rc.far == Infinity);
rc.setFromPointer(320, 240, 640, 480, cam);
check("B7 perspective ray starts at the camera", vecNear(rc.ray.origin, 0, 0, 5));
check("B8 centre ray looks down the camera axis", vecNear(rc.ray.direction, 0, 0, -1, 1e-6));
check("B9 the camera is recorded", rc.camera == cam);

rc.setFromPointer(640, 240, 640, 480, cam);
check("B10 a right-side pointer tilts the ray +X", rc.ray.direction.x > 0.4 && rc.ray.direction.z < 0);
rc.setFromPointer(320, 0, 640, 480, cam);
check("B11 a top-side pointer tilts the ray +Y (y up in NDC)", rc.ray.direction.y > 0.4);

var orthoCam:OrthographicCamera = new OrthographicCamera(-4, 4, 3, -3, 0.1, 100);
orthoCam.position.set(0, 0, 10);
orthoCam.lookAt(0, 0, 0);
orthoCam.updateMatrixWorld(true);
rc.setFromPointer(320, 240, 640, 480, orthoCam);
check("B12 ortho ray direction is the camera forward axis", vecNear(rc.ray.direction, 0, 0, -1, 1e-6));
check("B13 ortho ray origin is on the camera plane (z=10)", near(rc.ray.origin.z, 10, 1e-6));
check("B14 ortho centre origin is on the axis", near(rc.ray.origin.x, 0, 1e-6) && near(rc.ray.origin.y, 0, 1e-6));
rc.setFromPointer(0, 0, 640, 480, orthoCam);
check("B15 ortho origin follows NDC x/y", rc.ray.origin.x < -3 && rc.ray.origin.y > 2);

// ---------------------------------------------------------------------------
// C. Mesh.raycast.
// ---------------------------------------------------------------------------
var boxGeo:BoxGeometry = new BoxGeometry(2, 2, 2);
var mat:MeshBasicMaterial = new MeshBasicMaterial();
var mesh:Mesh = new Mesh(boxGeo, mat);
mesh.updateMatrixWorld(true);

// The ray is deliberately OFF the box's diagonal: a ray straight through the
// centre runs along the shared edge of the two face triangles and hits BOTH
// (three.js documents exactly this, Raycaster.js:intersectObject). C19 pins that
// separate case; every other check here wants an unambiguous single hit.
var pick:Raycaster = new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1));
var hits:Vector.<Intersection> = pick.intersectObject(mesh, true);
check("C1 FrontSide box: exactly the near face is hit (" + hits.length + ")", hits.length == 1);
check("C2 hit distance is 4", near(hits[0].distance, 4, 1e-6));
check("C3 hit point is on the near face", vecNear(hits[0].point, 0.3, 0.2, 1, 1e-6));
check("C4 hit object is the mesh", hits[0].object == mesh);
check("C5 face normal points at the ray", vecNear(hits[0].face.normal, 0, 0, 1, 1e-6));
check("C6 uv is interpolated and inside the quad",
      hits[0].uv != null && hits[0].uv.x >= -1e-9 && hits[0].uv.x <= 1 + 1e-9 &&
      hits[0].uv.y >= -1e-9 && hits[0].uv.y <= 1 + 1e-9);
check("C7 interpolated normal faces the ray", hits[0].normal != null && hits[0].normal.dot(pick.ray.direction) < 0);
check("C8 barycentric weights sum to 1",
      hits[0].barycoord != null && near(hits[0].barycoord.x + hits[0].barycoord.y + hits[0].barycoord.z, 1, 1e-6));
check("C9 face indices are distinct vertices",
      hits[0].face.a != hits[0].face.b && hits[0].face.b != hits[0].face.c && hits[0].face.a != hits[0].face.c);
check("C10 faceIndex is a valid triangle number", hits[0].faceIndex >= 0 && hits[0].faceIndex < 12);
var corner:Vector3 = mesh.getVertexPosition(hits[0].face.a, new Vector3());
check("C11 getVertexPosition returns a unit-box corner (|x|=|y|=|z|=1)",
      near(Math.abs(corner.x), 1, 1e-6) && near(Math.abs(corner.y), 1, 1e-6) && near(Math.abs(corner.z), 1, 1e-6));

mat.side = MeshBasicMaterial.DoubleSide;
var both:Vector.<Intersection> = new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1)).intersectObject(mesh, true);
check("C12 DoubleSide hits front and back (" + both.length + ")", both.length == 2);
check("C13 DoubleSide results are sorted near to far", both[0].distance < both[1].distance);
check("C14 the far hit is the back face", near(both[1].distance, 6, 1e-6));
mat.side = MeshBasicMaterial.FrontSide;

var miss:Vector.<Intersection> = new Raycaster(new Vector3(5, 5, 5), new Vector3(0, 0, -1)).intersectObject(mesh, true);
check("C15 a missing ray returns no hits", miss.length == 0);

var windowed:Raycaster = new Raycaster(new Vector3(0, 0, 5), new Vector3(0, 0, -1));
windowed.far = 3;
check("C16 far clips the hit away", windowed.intersectObject(mesh, true).length == 0);
windowed.far = Infinity;
windowed.near = 5;
check("C17 near clips a hit that is too close", windowed.intersectObject(mesh, true).length == 0);

// BackSide: from OUTSIDE a box the near face must be rejected and the far
// (inside) face accepted -- this is what makes an "inside a room" pick work.
mat.side = MeshBasicMaterial.BackSide;
var backHits:Vector.<Intersection> = new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1)).intersectObject(mesh, true);
check("C18 BackSide picks the far face (" + backHits.length + ")", backHits.length == 1 && near(backHits[0].distance, 6, 1e-6));
mat.side = MeshBasicMaterial.FrontSide;

// Documented r187 behaviour: a ray along a shared edge reports BOTH triangles.
var centreHits:Vector.<Intersection> = new Raycaster(new Vector3(0, 0, 5), new Vector3(0, 0, -1)).intersectObject(mesh, true);
check("C19 a centre ray on the face diagonal hits both triangles (" + centreHits.length + ")",
      centreHits.length == 2 && near(centreHits[0].distance, centreHits[1].distance, 1e-9));

// Transform: a moved + scaled mesh reports a WORLD hit point.
var moved:Mesh = new Mesh(new BoxGeometry(2, 2, 2), new MeshBasicMaterial());
moved.position.set(0, 3, 0);
moved.scale.set(2, 2, 2);
moved.updateMatrixWorld(true);
var movedHits:Vector.<Intersection> = new Raycaster(new Vector3(0, 3, 10), new Vector3(0, 0, -1)).intersectObject(moved, true);
check("C20 the hit follows the mesh translation", movedHits.length > 0 && near(movedHits[0].point.y, 3, 1e-6));
check("C21 the hit follows the mesh scale", movedHits.length > 0 && near(movedHits[0].distance, 8, 1e-6));

// Hierarchy: recursive picks children, non-recursive does not.
var group:Group = new Group();
var child:Mesh = new Mesh(new BoxGeometry(2, 2, 2), new MeshBasicMaterial());
child.position.set(0, 0, 0);
group.add(child);
group.updateMatrixWorld(true);
var downRay:Raycaster = new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1));
check("C22 recursive traversal reaches a child", downRay.intersectObject(group, true).length == 1);
check("C23 recursive=false stops at the group", downRay.intersectObject(group, false).length == 0);

// Two coincident meshes: equal distances, traversal order preserved (stable sort).
var twinA:Mesh = new Mesh(new BoxGeometry(2, 2, 2), new MeshBasicMaterial());
var twinB:Mesh = new Mesh(new BoxGeometry(2, 2, 2), new MeshBasicMaterial());
var pair:Vector.<Object3D> = new Vector.<Object3D>();
twinA.updateMatrixWorld(true);
twinB.updateMatrixWorld(true);
pair.push(twinA);
pair.push(twinB);
var pairHits:Vector.<Intersection> = downRay.intersectObjects(pair, false);
check("C24 two meshes produce two hits", pairHits.length == 2);
check("C25 equal distances keep traversal order (stable)", pairHits[0].object == twinA && pairHits[1].object == twinB);
var sortedOK:Boolean = true;
var k:int = 1;
while (k < pairHits.length)
{
    if (pairHits[k].distance < pairHits[k - 1].distance) sortedOK = false;
    k++;
}
check("C26 the result vector is sorted ascending", sortedOK);

// drawRange: a range that excludes the near (+Z) face must not hit it. BoxGeometry
// emits six faces of two triangles each in +X,-X,+Y,-Y,+Z,-Z order, so the first
// four indices cover only the +X face.
var ranged:Mesh = new Mesh(new BoxGeometry(2, 2, 2), new MeshBasicMaterial());
ranged.updateMatrixWorld(true);
check("C27 the default drawRange sentinel is -1 (to the end)",
      new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1)).intersectObject(ranged, true).length == 1);
ranged.geometry.drawRange.start = 0;
ranged.geometry.drawRange.count = 0;
check("C28 drawRange count 0 hits nothing", new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1)).intersectObject(ranged, true).length == 0);
ranged.geometry.drawRange.count = 2;
check("C29 a partial drawRange only covers its own face",
      new Raycaster(new Vector3(0.3, 0.2, 5), new Vector3(0, 0, -1)).intersectObject(ranged, true).length == 0);
ranged.geometry.drawRange.count = -1;

// Non-indexed geometry: one explicit triangle.
var triGeo:BufferGeometry = new BufferGeometry();
var pos:Vector.<Number> = new Vector.<Number>();
pos.push(-1, -1, 0, 1, -1, 0, 0, 1, 0);
triGeo.setAttribute("position", new BufferAttribute(pos, 3));
triGeo.computeBoundingSphere();
var triMesh:Mesh = new Mesh(triGeo, new MeshBasicMaterial());
triMesh.updateMatrixWorld(true);
var triHits:Vector.<Intersection> = new Raycaster(new Vector3(0, 0, 5), new Vector3(0, 0, -1)).intersectObject(triMesh, true);
check("C30 non-indexed geometry is pickable", triHits.length == 1 && vecNear(triHits[0].point, 0, 0, 0, 1e-6));
check("C31 non-indexed Face indices are vertex offsets", triHits[0].face.a == 0 && triHits[0].face.b == 1 && triHits[0].face.c == 2);
check("C32 no uv attribute means no uv in the hit", triHits[0].uv == null);
check("C33 no normal attribute means no interpolated normal", triHits[0].normal == null);
check("C34 the geometric face normal is still reported", vecNear(triHits[0].face.normal, 0, 0, 1, 1e-6));

// Mesh.raycast reports "propagate" so traversal continues into children.
check("C35 raycast returns true to keep propagating", mesh.raycast(new Raycaster(), new Vector.<Intersection>()) == true);

// A plane geometry is pickable from its front side only (single-sided quads are
// the usual "shadow catcher" surface, so picking one must not work from below).
var ground:Mesh = new Mesh(new PlaneGeometry(10, 10), new MeshBasicMaterial());
ground.rotation.x = -Math.PI / 2;
ground.updateMatrixWorld(true);
var fromAbove:Vector.<Intersection> = new Raycaster(new Vector3(1, 5, 0.3), new Vector3(0, -1, 0)).intersectObject(ground, true);
check("C36 a rotated plane is picked from above", fromAbove.length == 1 && near(fromAbove[0].point.y, 0, 1e-6));
var fromBelow:Vector.<Intersection> = new Raycaster(new Vector3(1, -5, 0.3), new Vector3(0, 1, 0)).intersectObject(ground, true);
check("C37 the same plane is invisible from below (FrontSide)", fromBelow.length == 0);

// ---------------------------------------------------------------------------
// D. OrbitControls.
// ---------------------------------------------------------------------------
var oCam:PerspectiveCamera = new PerspectiveCamera(60, 1.5, 0.1, 100);
oCam.position.set(0, 0, 5);
oCam.lookAt(0, 0, 0);
oCam.updateMatrixWorld(true);

var controls:OrbitControls = new OrbitControls(oCam);
controls.setSize(640, 480);
check("D1 construction keeps the camera and finds the target", near(controls.getDistance(), 5));
check("D2 the initial polar angle is 90 degrees", near(controls.getPolarAngle(), Math.PI / 2, 1e-6));

controls.rotateLeft(Math.PI / 2);
check("D3 rotateLeft orbits in azimuth", near(controls.getAzimuthalAngle(), -Math.PI / 2, 1e-6));
check("D4 orbiting preserves the distance", near(controls.getDistance(), 5, 1e-9));
check("D5 a quarter turn puts the camera on -X", near(oCam.position.x, -5, 1e-6) && near(oCam.position.z, 0, 1e-6));

controls.rotateUp(0.5);
check("D6 rotateUp lowers the polar angle", near(controls.getPolarAngle(), Math.PI / 2 - 0.5, 1e-6));
check("D7 the camera rises with the orbit", oCam.position.y > 0.4);

controls.maxPolarAngle = Math.PI / 4;
controls.rotateUp(-2);
check("D8 maxPolarAngle clamps the orbit", near(controls.getPolarAngle(), Math.PI / 4, 1e-6));
controls.maxPolarAngle = Math.PI;
controls.minPolarAngle = Math.PI / 2;
controls.rotateUp(2);
check("D9 minPolarAngle clamps the orbit", near(controls.getPolarAngle(), Math.PI / 2, 1e-6));
controls.minPolarAngle = 0;

controls.minAzimuthAngle = -0.2;
controls.maxAzimuthAngle = 0.2;
controls.rotateLeft(-5);
check("D10 azimuth limits clamp the orbit", near(controls.getAzimuthalAngle(), 0.2, 1e-9));
controls.minAzimuthAngle = -Infinity;
controls.maxAzimuthAngle = Infinity;

var beforeZoom:Number = controls.getDistance();
controls.dollyIn(0.5);
check("D11 dollyIn halves the radius", near(controls.getDistance(), beforeZoom * 0.5, 1e-6));
// r187 convention: dollyOut(x) divides the scale, so the INVERSE of dollyIn(0.5)
// is dollyOut(0.5) -- the factor is a zoom < 1, never a divisor > 1.
controls.dollyOut(0.5);
check("D12 dollyOut(0.5) restores the radius", near(controls.getDistance(), beforeZoom, 1e-6));

controls.minDistance = 1;
controls.dollyIn(0.01);
check("D13 minDistance clamps the dolly", near(controls.getDistance(), 1, 1e-6));
controls.maxDistance = 2;
controls.dollyOut(0.1);
check("D14 maxDistance clamps the dolly", near(controls.getDistance(), 2, 1e-6));
controls.minDistance = 0;
controls.maxDistance = Infinity;

// reset returns to whatever saveState() captured, not to the constructor state.
controls.saveState();
var savedX:Number = oCam.position.x;
var savedDist:Number = controls.getDistance();
controls.rotateLeft(1.0);
controls.dollyIn(0.5);
controls.reset();
check("D15 reset restores the saved position and distance",
      near(oCam.position.x, savedX, 1e-6) && near(controls.getDistance(), savedDist, 1e-6));

// Damping: with rotation deltas left over, each update applies dampingFactor of
// them; the accumulated delta shrinks geometrically.
var dCam:PerspectiveCamera = new PerspectiveCamera(60, 1.5, 0.1, 100);
dCam.position.set(0, 0, 5);
dCam.lookAt(0, 0, 0);
dCam.updateMatrixWorld(true);
var damp:OrbitControls = new OrbitControls(dCam);
damp.setSize(640, 480);
damp.enableDamping = true;
damp.dampingFactor = 0.5;
// rotateLeft() is the r187 convenience wrapper: _rotateLeft + one update, so it
// already applies only dampingFactor of the delta.
damp.rotateLeft(Math.PI / 2);
var theta1:Number = damp.getAzimuthalAngle();
damp.update();
var theta2:Number = damp.getAzimuthalAngle();
damp.update();
var theta3:Number = damp.getAzimuthalAngle();
// The delta is applied as a FRACTION each update, so the first update only
// travels dampingFactor * delta (0.5 * PI/2) and the rest is still pending.
check("D16 damping applies only a fraction of the delta per update",
      near(Math.abs(theta1), Math.PI / 4, 1e-6) && Math.abs(theta1) < Math.abs(theta2) && Math.abs(theta2) < Math.abs(theta3));
check("D17 the damped orbit approaches the full delta without overshooting",
      Math.abs(theta1) < Math.abs(theta2) && Math.abs(theta2) < Math.abs(theta3) &&
      Math.abs(theta3) < Math.PI / 2);

// autoRotate advances the azimuth once per update when no drag is active.
var rotateCam:PerspectiveCamera = new PerspectiveCamera(60, 1.5, 0.1, 100);
rotateCam.position.set(0, 0, 5);
rotateCam.lookAt(0, 0, 0);
rotateCam.updateMatrixWorld(true);
var auto:OrbitControls = new OrbitControls(rotateCam);
auto.setSize(640, 480);
auto.autoRotate = true;
auto.autoRotateSpeed = 2;
auto.update();
check("D18 autoRotate moves the azimuth", Math.abs(auto.getAzimuthalAngle()) > 0);
check("D19 autoRotate preserves the distance", near(auto.getDistance(), 5, 1e-6));

// Pan: target and camera translate together, so the distance is unchanged.
var panCam:PerspectiveCamera = new PerspectiveCamera(60, 1.5, 0.1, 100);
panCam.position.set(0, 0, 10);
panCam.lookAt(0, 0, 0);
panCam.updateMatrixWorld(true);
var panCtl:OrbitControls = new OrbitControls(panCam);
panCtl.setSize(640, 480);
var panBefore:Number = panCtl.getDistance();
panCtl.pan(100, 0);
check("D20 pan moves the target", Math.abs(panCtl.target.x) > 0.1);
check("D21 pan keeps camera and target together", near(panCtl.getDistance(), panBefore, 1e-6));
check("D22 screen-space pan pushes the target toward -X", panCtl.target.x < 0);

// Orthographic: the wheel changes zoom, not the radius.
var orthoPick:OrthographicCamera = new OrthographicCamera(-4, 4, 3, -3, 0.1, 100);
orthoPick.position.set(0, 0, 10);
orthoPick.lookAt(0, 0, 0);
orthoPick.updateMatrixWorld(true);
var orthoCtl:OrbitControls = new OrbitControls(orthoPick);
orthoCtl.setSize(640, 480);
var orthoPos:Vector3 = orthoPick.position.clone();
orthoCtl.dollyIn(0.5);
check("D23 ortho dolly changes zoom, not position",
      orthoPick.zoom != 1 && near(orthoPick.position.z, orthoPos.z, 1e-6));

// The event bridge, driven by real MouseEvents on a display object (no window
// needed: the control listens to the object, and AIR's stage events arrive there).
var evCam:PerspectiveCamera = new PerspectiveCamera(60, 1.5, 0.1, 100);
evCam.position.set(0, 0, 5);
evCam.lookAt(0, 0, 0);
evCam.updateMatrixWorld(true);
var view:Sprite = new Sprite();
var evCtl:OrbitControls = new OrbitControls(evCam, view);
evCtl.setSize(640, 480);

var down:MouseEvent = new MouseEvent(MouseEvent.MOUSE_DOWN);
down.stageX = 320;
down.stageY = 240;
view.dispatchEvent(down);

var move:MouseEvent = new MouseEvent(MouseEvent.MOUSE_MOVE);
move.stageX = 420;
move.stageY = 240;
view.dispatchEvent(move);
check("D24 a mouse drag rotates the camera (state machine reached ROTATE)", evCtl.state == OrbitControls.ROTATE);
var expectedTheta:Number = 2 * Math.PI * 100 / 480;
check("D25 the drag delta is 2PI * dx / height",
      near(Math.abs(evCtl.getAzimuthalAngle()), expectedTheta, 1e-6));

var upEvent:MouseEvent = new MouseEvent(MouseEvent.MOUSE_UP);
view.dispatchEvent(upEvent);
check("D26 mouse up ends the drag", evCtl.state == OrbitControls.NONE);

var beforeWheel:Number = evCtl.getDistance();
var wheel:MouseEvent = new MouseEvent(MouseEvent.MOUSE_WHEEL);
wheel.delta = 1;
view.dispatchEvent(wheel);
check("D27 wheel up (positive AIR delta) dollies IN", evCtl.getDistance() < beforeWheel);
wheel.delta = -1;
view.dispatchEvent(wheel);
check("D28 wheel down (negative AIR delta) dollies back OUT", near(evCtl.getDistance(), beforeWheel, 1e-6));

evCtl.enableZoom = false;
var lockedDist:Number = evCtl.getDistance();
wheel.delta = 1;
view.dispatchEvent(wheel);
check("D29 enableZoom=false ignores the wheel", near(evCtl.getDistance(), lockedDist, 1e-9));
evCtl.enableZoom = true;

evCtl.disconnect();
var detachedTheta:Number = evCtl.getAzimuthalAngle();
view.dispatchEvent(move);
check("D30 disconnect stops listening", near(evCtl.getAzimuthalAngle(), detachedTheta, 1e-12));

// Spherical round trip and makeSafe.
var sp:Spherical = new Spherical();
sp.setFromCartesianCoords(0, 0, 5);
check("D31 spherical of +Z is theta 0 / phi 90deg", near(sp.theta, 0) && near(sp.phi, Math.PI / 2));
var backVec:Vector3 = new Vector3().setFromSpherical(sp);
check("D32 spherical -> cartesian round trip", vecNear(backVec, 0, 0, 5, 1e-9));
sp.set(1, 0, 0);
sp.makeSafe();
check("D33 makeSafe keeps phi off the poles", sp.phi > 0 && sp.phi < Math.PI);

// Triangle helpers.
var nrm:Vector3 = Triangle.getNormal(triA, triB, triC, new Vector3());
check("D34 Triangle.getNormal is unit length", near(nrm.length(), 1, 1e-9));
check("D35 Triangle.getNormal faces +Z for this winding", near(nrm.z, 1, 1e-6));
var degTri:Vector3 = Triangle.getBarycoord(new Vector3(0, 0, 0),
                                            new Vector3(0, 0, 0), new Vector3(1, 0, 0), new Vector3(2, 0, 0),
                                            new Vector3());
check("D36 degenerate triangle has no barycentric coords", degTri == null);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));