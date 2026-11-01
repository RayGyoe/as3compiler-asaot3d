// asaot3d/probes/geometry-smoke/GeometrySmoke.as -- assertion smoke for the geometry layer.
//
// Compiles BufferAttribute/BufferGeometry/Box3/Sphere + the three built-in geometries
// against known topology (vertex/index counts, attribute shapes, bounding volumes).
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/geometry-smoke/GeometrySmoke.as \
//        $(find kit -name '*.as') -o temp/geometry-smoke.exe --run
//
// The whole kit is swept rather than math+core+geometries: Frustum.intersectsObject and
// Box3.expandByObject take a Mesh (three.js's own signatures do the same), so core is no
// longer compilable without objects/*.as.
import asaot.three.core.Box3;
import asaot.three.core.BufferAttribute;
import asaot.three.core.BufferGeometry;
import asaot.three.core.Sphere;
import asaot.three.geometries.BoxGeometry;
import asaot.three.geometries.PlaneGeometry;
import asaot.three.geometries.SphereGeometry;
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

// ---- BufferAttribute basics ----
var arr:Vector.<Number> = new Vector.<Number>();
arr.push(0, 0, 0, 1, 2, 3);
var attr:BufferAttribute = new BufferAttribute(arr, 3);
check("attr.count", attr.count == 2);
check("attr.getX(1)", attr.getX(1) == 1);
check("attr.getY(1)", attr.getY(1) == 2);
check("attr.getZ(1)", attr.getZ(1) == 3);
attr.setXYZ(0, 7, 8, 9);
check("attr.setXYZ", attr.getX(0) == 7 && attr.getY(0) == 8 && attr.getZ(0) == 9);

var v0:int = attr.version;
attr.needsUpdate = true;
check("attr.needsUpdate bumps version", attr.version == v0 + 1);
attr.needsUpdate = false;
check("attr.needsUpdate=false no bump", attr.version == v0 + 1);

var attrCopy:BufferAttribute = attr.clone();
check("attr.clone data", attrCopy.getX(0) == 7 && attrCopy.count == 2);

// ---- Box3 ----
var bbox:Box3 = new Box3();
check("Box3 starts empty", bbox.isEmpty());
bbox.expandByPoint(new Vector3(-1, -2, -3));
bbox.expandByPoint(new Vector3(4, 5, 6));
check("Box3 expands", !bbox.isEmpty());
var center:Vector3 = bbox.getCenter(new Vector3());
check("Box3 center", near(center.x, 1.5) && near(center.y, 1.5) && near(center.z, 1.5));
var size:Vector3 = bbox.getSize(new Vector3());
check("Box3 size", near(size.x, 5) && near(size.y, 7) && near(size.z, 9));

// ---- BoxGeometry topology ----
// 6 faces x 4 verts = 24 vertices; 6 faces x 2 tris x 3 = 36 indices; 6 groups.
var box:BoxGeometry = new BoxGeometry(1, 1, 1);
var boxPos:BufferAttribute = box.getAttribute("position");
check("box has position/normal/uv", box.hasAttribute("position") && box.hasAttribute("normal") && box.hasAttribute("uv"));
check("box vertex count", boxPos.count == 24);
check("box index count", box.getIndex().count == 36);
check("box group count", box.groups.length == 6);
check("box group materialIndex", box.groups[0].materialIndex == 0 && box.groups[5].materialIndex == 5);

// All positions lie on the half-extent boundary (0.5 in one axis).
var allOnBoundary:Boolean = true;
var pi:int = 0;
while (pi < boxPos.count)
{
    var ax:Number = boxPos.getX(pi);
    var ay:Number = boxPos.getY(pi);
    var az:Number = boxPos.getZ(pi);
    if (!(near(Math.abs(ax), 0.5) || near(Math.abs(ay), 0.5) || near(Math.abs(az), 0.5))) allOnBoundary = false;
    pi++;
}
check("box vertices on half-extent", allOnBoundary);

// ---- BoxGeometry bounding box ----
box.computeBoundingBox();
check("box bbox min", near(box.boundingBox.min.x, -0.5) && near(box.boundingBox.min.y, -0.5) && near(box.boundingBox.min.z, -0.5));
check("box bbox max", near(box.boundingBox.max.x, 0.5) && near(box.boundingBox.max.y, 0.5) && near(box.boundingBox.max.z, 0.5));
box.computeBoundingSphere();
check("box sphere radius", near(box.boundingSphere.radius, Math.sqrt(3) / 2));
check("box sphere center", near(box.boundingSphere.center.x, 0) && near(box.boundingSphere.center.y, 0) && near(box.boundingSphere.center.z, 0));

// ---- PlaneGeometry topology ----
// gridX1 * gridY1 = 4 verts; 2 tris x 3 = 6 indices; no groups.
var plane:PlaneGeometry = new PlaneGeometry(1, 1);
check("plane vertex count", plane.getAttribute("position").count == 4);
check("plane index count", plane.getIndex().count == 6);
check("plane no groups", plane.groups.length == 0);
// +Z normals.
check("plane +Z normal", plane.getAttribute("normal").getZ(0) == 1);

// ---- SphereGeometry topology ----
// (widthSegments+1)*(heightSegments+1) = 33*17 = 561 vertices.
var sphere:SphereGeometry = new SphereGeometry(1, 32, 16);
check("sphere vertex count", sphere.getAttribute("position").count == (32 + 1) * (16 + 1));
check("sphere has index", sphere.getIndex() != null);
sphere.computeBoundingSphere();
check("sphere radius ~1", near(sphere.boundingSphere.radius, 1));
// Sphere positions lie on the unit sphere (radius 1).
var onSphere:Boolean = true;
var si:int = 0;
var spherePos:BufferAttribute = sphere.getAttribute("position");
while (si < spherePos.count)
{
    var sx:Number = spherePos.getX(si);
    var sy:Number = spherePos.getY(si);
    var sz:Number = spherePos.getZ(si);
    var r:Number = Math.sqrt(sx * sx + sy * sy + sz * sz);
    if (!near(r, 1, 1e-4)) onSphere = false;
    si++;
}
check("sphere vertices on unit sphere", onSphere);

// ---- M4: computeTangents (three.js BufferGeometry.js:837-975) ----
// Box: 24 vertices, tangent attribute itemSize 4, Gram-Schmidt-orthogonal to
// the normal, unit length, and handedness w = +-1.
var tbox:BoxGeometry = new BoxGeometry(2, 2, 2);
tbox.computeTangents();
var tangent:BufferAttribute = tbox.getAttribute("tangent");
check("box tangent exists", tangent != null);
check("box tangent itemSize 4", tangent != null && tangent.itemSize == 4);
check("box tangent count 24", tangent != null && tangent.count == 24);
var tOk:Boolean = true;
if (tangent != null)
{
    var tNormal:BufferAttribute = tbox.getAttribute("normal");
    var ti:int;
    for (ti = 0; ti < tangent.count; ti++)
    {
        var td:Number = tangent.getX(ti) * tNormal.getX(ti)
                      + tangent.getY(ti) * tNormal.getY(ti)
                      + tangent.getZ(ti) * tNormal.getZ(ti);
        var tl:Number = tangent.getX(ti) * tangent.getX(ti)
                      + tangent.getY(ti) * tangent.getY(ti)
                      + tangent.getZ(ti) * tangent.getZ(ti);
        var tw:Number = tangent.getW(ti);
        if (!near(td, 0) || !near(tl, 1) || !(near(tw, 1) || near(tw, -1))) tOk = false;
    }
}
check("box tangents orthogonal/unit/w=+-1", tOk);

// Degenerate guard: an unindexed geometry without uv is silently skipped.
var nobox:BoxGeometry = new BoxGeometry(1, 1, 1);
nobox.deleteAttribute("uv");
nobox.computeTangents();
check("tangent skipped without uv", nobox.getAttribute("tangent") == null);

trace(failed == 0 ? "RESULT: PASS" : "RESULT: FAIL (" + failed + ")");
