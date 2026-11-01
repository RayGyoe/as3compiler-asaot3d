// asaot.three.core.Raycaster -- mouse picking, three.js style.
//
// Borrows src/core/Raycaster.js (r187): `ray` + `near`/`far` window, the
// perspective/orthographic `setFromCamera` branches, delegation to each object's
// own `raycast()`, recursive traversal, and the "sorted by distance, closest
// first" result contract. Mesh.raycast holds the triangle work; this class is
// only the driver.
//
// STAGE3D BRIDGE (M14): three.js feeds `coords` from a DOM pointer event. There
// is no DOM here -- AIR delivers MouseEvent.stageX/stageY on the Stage (see
// `_controls`/the demo), so `setFromPointer(x, y, width, height, camera)` is the
// one-line conversion from AOT pointer coordinates to the NDC pair `setFromCamera`
// expects. Keeping it on Raycaster (rather than inside the control) means a
// click handler and an orbit control agree bit-for-bit on where the pointer is.
//
// DEPTH CONVENTION: `setFromCamera` unprojects at NDC z = 0.5 (perspective) and
// at `projectionMatrix.elements[14]` (orthographic). Both are depth-range
// INDEPENDENT: 0.5 is the middle of the pipe, and `elements[14]` is the NDC z of
// the camera plane in either convention ([0,1] here, [-1,1] in WebGL). That is
// why r187's code ports unchanged even though our projection matrices map depth
// to [0,1] (M7). A perspective direction is a pure line, so the depth of the
// unprojected point cannot change it; an orthographic origin does depend on it,
// and `elements[14]` puts that origin exactly on the camera plane, as three.js
// documents ("set origin in plane of camera").
//
// DIVERGENCES (three-api-design.md §19):
//   D96  hits are typed `Intersection`/`Face` instances, not object literals.
//   D97  `layers` and `params` are absent: the AGAL backend has no Layers and no
//        Line/Points picking, so an API that silently filtered nothing would be
//        worse than an absent one. `intersectObject` therefore visits EVERY
//        object it can (three.js filters by layer first).
//   D98  `intersects` is an explicit out-parameter (AS3 has no default `[]`
//        literal per call); passing null allocates one and returns it.
package asaot.three.core
{
    import asaot.three.cameras.Camera;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Ray;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;

    public class Raycaster
    {
        public var ray:Ray;
        public var near:Number;
        public var far:Number;
        public var camera:Camera;

        // Scratch (module-wide like three.js's _matrix). Picking runs per click,
        // so allocation here would be acceptable -- but the traversal itself walks
        // thousands of triangles, and shared scratch keeps the per-triangle path
        // free of `new`.
        private static var _coords:Vector3 = new Vector3();
        private static var _invMatrix:Matrix4 = new Matrix4();

        public function Raycaster(origin:Vector3 = null, direction:Vector3 = null,
                                  near:Number = 0, far:Number = Infinity)
        {
            this.ray = new Ray(origin, direction);
            this.near = near;
            this.far = far;
            this.camera = null;
        }

        public function set(origin:Vector3, direction:Vector3):Raycaster
        {
            this.ray.set(origin, direction);
            return this;
        }

        // Raycaster.js:setFromCamera. `coords` are NDC: x right, y UP, each in
        // [-1, 1].
        public function setFromCamera(coords:Vector2, camera:Camera):Raycaster
        {
            // The renderer refreshes the camera's world matrix every frame, but a
            // pick can be issued before the first render or right after an app
            // moved the camera by hand. Refreshing here makes the call correct in
            // both cases (a divergence: three.js leaves it to the caller).
            camera.updateMatrixWorld();

            if (camera.isPerspectiveCamera)
            {
                this.ray.origin.setFromMatrixPosition(camera.matrixWorld);
                Raycaster._coords.set(coords.x, coords.y, 0.5);
                this._unproject(Raycaster._coords, camera);
                this.ray.direction.subVectors(Raycaster._coords, this.ray.origin).normalize();
                this.camera = camera;
            }
            else if (camera.isOrthographicCamera)
            {
                Raycaster._coords.set(coords.x, coords.y, camera.projectionMatrix.elements[14]);
                this._unproject(Raycaster._coords, camera);
                this.ray.origin.copy(Raycaster._coords);
                this.ray.direction.set(0, 0, -1).transformDirection(camera.matrixWorld);
                this.camera = camera;
            }
            else
            {
                throw new Error("Raycaster.setFromCamera: unsupported camera type (needs isPerspectiveCamera or isOrthographicCamera)");
            }
            return this;
        }

        // M14 bridge: AIR pointer coordinates (stage/client pixels, origin top-left)
        // -> NDC. This is the single place the y flip happens, so a click and a drag
        // cannot disagree about "up".
        public function setFromPointer(x:Number, y:Number, width:Number, height:Number,
                                       camera:Camera):Raycaster
        {
            var ndc:Vector2 = new Vector2();
            Pointer.toNDC(x, y, width, height, ndc);
            return this.setFromCamera(ndc, camera);
        }

        // Vector3.unproject (three.js) without importing Camera into math/:
        // undo the projection, then go from view to world space.
        private function _unproject(v:Vector3, camera:Camera):void
        {
            v.applyMatrix4(camera.projectionMatrixInverse);
            v.applyMatrix4(camera.matrixWorld);
        }

        // Raycaster.js:intersectObject. `recursive` defaults to true; `intersects`
        // may be null, in which case a fresh vector is allocated and returned.
        public function intersectObject(object:Object3D, recursive:Boolean = true,
                                        intersects:Vector.<Intersection> = null):Vector.<Intersection>
        {
            if (intersects == null) intersects = new Vector.<Intersection>();
            this._intersect(object, intersects, recursive);
            Raycaster.sortByDistance(intersects);
            return intersects;
        }

        public function intersectObjects(objects:Vector.<Object3D>, recursive:Boolean = true,
                                         intersects:Vector.<Intersection> = null):Vector.<Intersection>
        {
            if (intersects == null) intersects = new Vector.<Intersection>();
            var i:int = 0;
            while (i < objects.length)
            {
                this._intersect(objects[i], intersects, recursive);
                i++;
            }
            Raycaster.sortByDistance(intersects);
            return intersects;
        }

        // Raycaster.js:intersect -- one object, then its children. An object's
        // `raycast` may return false to prune its subtree (r187 behaviour).
        private function _intersect(object:Object3D, intersects:Vector.<Intersection>,
                                     recursive:Boolean):void
        {
            if (object == null) return;

            var propagate:Boolean = true;
            if (object.isObject3D) propagate = object.raycast(this, intersects);

            if (propagate && recursive)
            {
                var children:Vector.<Object3D> = object.children;
                var i:int = 0;
                while (i < children.length)
                {
                    this._intersect(children[i], intersects, recursive);
                    i++;
                }
            }
        }

        // three.js uses Array.prototype.sort (stable in every modern engine).
        // Vector.sort with a comparator is not guaranteed by the AOT runtime, so a
        // stable insertion sort keeps ties in traversal order (D98).
        public static function sortByDistance(intersects:Vector.<Intersection>):void
        {
            var n:int = intersects.length;
            var i:int = 1;
            while (i < n)
            {
                var current:Intersection = intersects[i];
                var j:int = i - 1;
                while (j >= 0 && intersects[j].distance > current.distance)
                {
                    intersects[j + 1] = intersects[j];
                    j--;
                }
                intersects[j + 1] = current;
                i++;
            }
        }
    }
}