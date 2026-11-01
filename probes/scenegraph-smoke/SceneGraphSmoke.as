// asaot3d/probes/scenegraph-smoke/SceneGraphSmoke.as -- scene-graph smoke test.
//
// Verifies the Object3D transform quartet, the rotation<->quaternion two-way
// sync (the D6 path that a field-level `rotation.x += 0.01` depends on), lazy
// matrixWorld updates, parent/child transform composition, lookAt, and clone.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/scenegraph-smoke/SceneGraphSmoke.as \
//        $(find kit -name '*.as') -o temp/scenegraph-smoke.exe --run
import asaot.three.cameras.PerspectiveCamera;
import asaot.three.core.Object3D;
import asaot.three.math.Euler;
import asaot.three.math.Matrix4;
import asaot.three.math.Quaternion;
import asaot.three.math.Vector3;
import asaot.three.objects.Group;
import asaot.three.objects.Mesh;
import asaot.three.scenes.Scene;

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

// ---- 1) rotation.x += 0.01 must sync into quaternion (the D6 path) ----
var obj:Object3D = new Object3D();
obj.rotation.x = Math.PI / 2; // 90 deg around X
check("rotation.x write syncs quaternion", Math.abs(obj.quaternion.x - Math.sin(Math.PI / 4)) < 1e-5);
check("quaternion.w after rotX90", near(obj.quaternion.w, Math.cos(Math.PI / 4)));

// field-level write through the accessor (not a whole-object setter)
obj.rotation.y += 0.5;
var qAfterY:Quaternion = obj.quaternion;
check("rotation.y += syncs quaternion", Math.abs(qAfterY.y) > 0.0);

// ---- 2) quaternion set must sync back into rotation ----
var obj2:Object3D = new Object3D();
obj2.quaternion.setFromAxisAngle(new Vector3(0, 1, 0), Math.PI / 2);
check("quaternion set syncs rotation.y", near(obj2.rotation.y, Math.PI / 2));

// ---- 3) updateMatrix composes position/rotation/scale ----
var obj3:Object3D = new Object3D();
obj3.position.set(1, 2, 3);
obj3.scale.set(2, 2, 2);
obj3.updateMatrix();
check("matrix translation", near(obj3.matrix.elements[12], 1) && near(obj3.matrix.elements[13], 2) && near(obj3.matrix.elements[14], 3));
check("matrix scale", near(obj3.matrix.elements[0], 2));

// ---- 4) parent/child world transform composition ----
var parent:Object3D = new Object3D();
var child:Object3D = new Object3D();
parent.add(child);
parent.position.set(10, 0, 0);
child.position.set(5, 0, 0);
parent.updateMatrixWorld(true);
var worldPos:Vector3 = new Vector3();
child.getWorldPosition(worldPos);
check("child world position = parent + child", near(worldPos.x, 15) && near(worldPos.y, 0) && near(worldPos.z, 0));

// ---- 5) add/remove maintain hierarchy ----
check("add sets parent", child.parent == parent);
check("children count", parent.children.length == 1);
var child2:Object3D = new Object3D();
parent.add(child2);
check("second child", parent.children.length == 2);
parent.remove(child2);
check("remove decrements", parent.children.length == 1);
check("removed child parent null", child2.parent == null);

// ---- 6) traverse visits self + descendants ----
var count:int = 0;
parent.add(child2);
parent.traverse(function(o:Object3D):void { count++; });
check("traverse visits all", count == 3);
parent.remove(child2);

// ---- 7) lookAt orients +Z toward target (non-camera) ----
var looker:Object3D = new Object3D();
looker.position.set(0, 0, 0);
looker.lookAt(0, 0, -1);
var dir:Vector3 = new Vector3();
looker.getWorldDirection(dir);
check("lookAt -Z", near(dir.z, -1) && Math.abs(dir.x) < 1e-5);

// ---- 8) camera lookAt orients -Z toward target (isCamera path) ----
// getWorldDirection returns the object's +Z; for a camera that looks TOWARD
// the target, +Z points AWAY from it (cameras face -Z).
var cam:PerspectiveCamera = new PerspectiveCamera(60, 1, 0.1, 100);
cam.position.set(0, 0, 5);
cam.lookAt(0, 0, 0);
var camDir:Vector3 = new Vector3();
cam.getWorldDirection(camDir);
check("camera +Z away from target", near(camDir.z, 1));

// ---- 9) perspective projection has known near/far compression ----
check("perspective[10]", near(cam.projectionMatrix.elements[10], -100.0 / 99.9, 1e-3));

// ---- 10) clone copies transform and (recursive) children ----------------
// AS3 has no `this.constructor` reflection (D9), so Object3D.clone returns an
// Object3D carrying the copied state rather than the exact subclass. Verify the
// copied CONTENT, not the runtime subclass tag.
var g:Group = new Group();
g.position.set(1, 1, 1);
var gm:Mesh = new Mesh();
g.add(gm);
var gcopy:Object3D = g.clone(true);
check("clone position", near(gcopy.position.x, 1) && near(gcopy.position.y, 1));
check("clone recursive children", gcopy.children.length == 1);

trace(failed == 0 ? "RESULT: PASS" : "RESULT: FAIL (" + failed + ")");
