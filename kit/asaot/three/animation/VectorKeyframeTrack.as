// asaot.three.animation.VectorKeyframeTrack -- component-wise lerped tuples
// ('vector'): position, scale and any other x/y/z/w channel.
//
// Borrows src/animation/tracks/VectorKeyframeTrack.js (r187).
package asaot.three.animation
{
    public class VectorKeyframeTrack extends KeyframeTrack
    {
        public function VectorKeyframeTrack(name:String, times:*, values:*, interpolation:int = -1)
        {
            super(name, times, values);
            this.valueTypeName = "vector";
            this.defaultInterpolation = InterpolateLinear;
            this.initInterpolation(interpolation);
        }
    }
}
