// asaot.three.cameras.Camera -- abstract camera base, three.js style.
//
// Borrows src/cameras/Camera.js (r187): holds the projection matrix and the
// inverse of the world matrix (view matrix), plus the projection inverse. The
// renderer (seam layer) recomputes matrixWorldInverse each frame from the
// object's matrixWorld.
package asaot.three.cameras
{
    import asaot.three.core.Object3D;
    import asaot.three.math.Matrix4;

    public class Camera extends Object3D
    {
        public var matrixWorldInverse:Matrix4;
        public var projectionMatrix:Matrix4;
        public var projectionMatrixInverse:Matrix4;

        // ---- type flags + zoom, hoisted to the base on purpose (M14) ----
        // three.js puts `isPerspectiveCamera` / `isOrthographicCamera` on the two
        // subclasses and `zoom` on both as well. In AS3 a member that is absent
        // from the STATIC type is a compile error, and Raycaster/OrbitControls hold
        // a `Camera` reference while branching on the type, so the flags have to be
        // declared where every caller can see them. The subclasses set their own
        // flag to true; exactly one of them is ever true.
        public var isPerspectiveCamera:Boolean = false;
        public var isOrthographicCamera:Boolean = false;
        public var zoom:Number = 1;

        public function Camera()
        {
            super();
            this.isCamera = true;
            this.matrixWorldInverse = new Matrix4();
            this.projectionMatrix = new Matrix4();
            this.projectionMatrixInverse = new Matrix4();
        }

        // three.js declares this ABSTRACT (Camera.updateProjectionMatrix throws).
        // AS3 has no abstract methods, so the base throws at runtime and each
        // subclass overrides it -- which is also what lets OrbitControls call it
        // through a `Camera` reference (r187 `reset()` does exactly that).
        public function updateProjectionMatrix():void
        {
            throw new Error("Camera.updateProjectionMatrix: abstract method, use PerspectiveCamera or OrthographicCamera");
        }

        // Copy the inverse of the world matrix into matrixWorldInverse.
        // (three.js does this inside the renderer; exposing it here keeps the
        // camera self-consistent when a scene graph update precedes a render.)
        public function updateMatrixWorldInverse():void
        {
            this.matrixWorldInverse.copy(this.matrixWorld).invert();
        }
    }
}
