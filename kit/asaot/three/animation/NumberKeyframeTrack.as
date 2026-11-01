// asaot.three.animation.NumberKeyframeTrack -- scalar keyframes ('number').
//
// Borrows src/animation/tracks/NumberKeyframeTrack.js (r187). Used by glTF for
// morph-target weights and for STEP-sampled single-component channels.
package asaot.three.animation
{
    public class NumberKeyframeTrack extends KeyframeTrack
    {
        public function NumberKeyframeTrack(name:String, times:*, values:*, interpolation:int = -1)
        {
            super(name, times, values);
            this.valueTypeName = "number";
            this.defaultInterpolation = InterpolateLinear;
            this.initInterpolation(interpolation);
        }
    }
}
