// asaot.three.cameras.OrthographicCamera -- orthographic projection camera.
//
// Borrows src/cameras/OrthographicCamera.js (r187): left/right/top/bottom/
// near/far frustum + zoom, and updateProjectionMatrix which rebuilds the
// orthographic matrix (and its inverse) from those knobs. The multiview
// (setViewOffset) API is skipped -- it exists for stereo/XR rendering, which
// is out of scope for asaot3d.
package asaot.three.cameras
{
    import asaot.three.cameras.Camera;

    public class OrthographicCamera extends Camera
    {
        public var left:Number;
        public var right:Number;
        public var top:Number;
        public var bottom:Number;
        public var near:Number;
        public var far:Number;

        public function OrthographicCamera(left:Number = -1, right:Number = 1, top:Number = 1, bottom:Number = -1,
                                           near:Number = 0.1, far:Number = 2000)
        {
            super();
            this.isOrthographicCamera = true;
            this.zoom = 1;
            this.left = left;
            this.right = right;
            this.top = top;
            this.bottom = bottom;
            this.near = near;
            this.far = far;
            this.updateProjectionMatrix();
        }

        // Rebuild projectionMatrix (WebGL depth range [-1, 1]) from the frustum
        // knobs. zoom scales the frustum around its centre (OrthographicCamera
        // .js:195-211, minus the skipped view-offset branch).
        override public function updateProjectionMatrix():void
        {
            var dx:Number = (this.right - this.left) / (2 * this.zoom);
            var dy:Number = (this.top - this.bottom) / (2 * this.zoom);
            var cx:Number = (this.right + this.left) / 2;
            var cy:Number = (this.top + this.bottom) / 2;

            var left:Number = cx - dx;
            var right:Number = cx + dx;
            var top:Number = cy + dy;
            var bottom:Number = cy - dy;

            this.projectionMatrix.makeOrthographic(left, right, top, bottom, this.near, this.far);
            this.projectionMatrixInverse.copy(this.projectionMatrix).invert();
        }
    }
}
