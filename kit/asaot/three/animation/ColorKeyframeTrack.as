// asaot.three.animation.ColorKeyframeTrack -- linear RGB keyframes ('color').
//
// Borrows src/animation/tracks/ColorKeyframeTrack.js (r187). The value buffer is
// a flat rgb triple, which PropertyBinding feeds straight into Color.fromArray.
//
// Like three.js, LINEAR interpolation lerps in the *working* (linear) space: the
// material colour is already linear here, so no colour-space conversion is
// inserted at this layer.
package asaot.three.animation
{
    public class ColorKeyframeTrack extends KeyframeTrack
    {
        public function ColorKeyframeTrack(name:String, times:*, values:*, interpolation:int = -1)
        {
            super(name, times, values);
            this.valueTypeName = "color";
            this.defaultInterpolation = InterpolateLinear;
            this.initInterpolation(interpolation);
        }
    }
}
