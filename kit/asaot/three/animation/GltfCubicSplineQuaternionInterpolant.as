// asaot.three.animation.GltfCubicSplineQuaternionInterpolant -- glTF CUBICSPLINE
// sampling for rotation tracks: the Hermite result is renormalised, exactly like
// GLTFCubicSplineQuaternionInterpolant in examples/jsm/loaders/GLTFLoader.js.
//
// A normalised quaternion is required because the two tangent terms are added in
// the four-component space and do not preserve unit length.
package asaot.three.animation
{
    import asaot.three.math.Quaternion;

    public class GltfCubicSplineQuaternionInterpolant extends GltfCubicSplineInterpolant
    {
        private var _scratch:Quaternion = new Quaternion();

        public function GltfCubicSplineQuaternionInterpolant(parameterPositions:Vector.<Number>,
                                                             sampleValues:Vector.<Number>,
                                                             sampleSize:int,
                                                             resultBuffer:Vector.<Number> = null)
        {
            super(parameterPositions, sampleValues, sampleSize, resultBuffer);
        }

        protected override function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            var result:Vector.<Number> = super.interpolate(i1, t0, t, t1);

            this._scratch.fromArray(result);
            this._scratch.normalize();
            this._scratch.toArray(result);

            return result;
        }
    }
}