// asaot.three.cameras.PerspectiveCamera -- perspective projection camera.
//
// Borrows src/cameras/PerspectiveCamera.js (r187): fov (vertical, DEGREES),
// aspect, near/far planes, and updateProjectionMatrix which builds the
// perspective matrix and its inverse. The view-offset and film-offset knobs of
// r187 are skipped (not needed for M1).
package asaot.three.cameras
{
    import asaot.three.cameras.Camera;
    import asaot.three.math.MathUtils;

    public class PerspectiveCamera extends Camera
    {
        public var fov:Number;
        public var aspect:Number;
        public var near:Number;
        public var far:Number;
        // (zoom / isPerspectiveCamera live on Camera so that a `Camera`-typed
        // reference can read them -- see the note there.)

        public function PerspectiveCamera(fov:Number = 50, aspect:Number = 1, near:Number = 0.1, far:Number = 2000)
        {
            super();
            this.isPerspectiveCamera = true;
            this.fov = fov;
            this.aspect = aspect;
            this.near = near;
            this.far = far;
            this.updateProjectionMatrix();
        }

        // Rebuild projectionMatrix from the current fov/aspect/near/far.
        override public function updateProjectionMatrix():void
        {
            var near:Number = this.near;
            var top:Number = near * Math.tan(MathUtils.degToRad(0.5 * this.fov)) / this.zoom;
            var height:Number = 2 * top;
            var width:Number = this.aspect * height;
            var left:Number = -0.5 * width;

            this.projectionMatrix.makePerspective(left, left + width, top, top - height, near, this.far);
            this.projectionMatrixInverse.copy(this.projectionMatrix).invert();
        }

        public function setAspect(aspect:Number):void
        {
            this.aspect = aspect;
            this.updateProjectionMatrix();
        }
    }
}
