// asaot.three.animation.QuaternionKeyframeTrack -- short-arc SLERP channels
// ('quaternion').
//
// Borrows src/animation/tracks/QuaternionKeyframeTrack.js (r187). The only
// difference from VectorKeyframeTrack is the factory: LINEAR interpolation of a
// rotation must slerp, not lerp the four components (three.js overrides the
// linear factory the same way).
package asaot.three.animation
{
    public class QuaternionKeyframeTrack extends KeyframeTrack
    {
        public function QuaternionKeyframeTrack(name:String, times:*, values:*, interpolation:int = -1)
        {
            super(name, times, values);
            this.valueTypeName = "quaternion";
            this.defaultInterpolation = InterpolateLinear;
            this.initInterpolation(interpolation);
        }

        protected override function _createLinearInterpolant(resultBuffer:Vector.<Number>):Interpolant
        {
            return new QuaternionLinearInterpolant(this.times, this.values, this.getValueSize(), resultBuffer);
        }

        protected override function _createCubicSplineInterpolant(resultBuffer:Vector.<Number>):Interpolant
        {
            return new GltfCubicSplineQuaternionInterpolant(this.times, this.values,
                int(this.getValueSize() / 3), resultBuffer);
        }
    }
}
