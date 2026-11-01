// asaot.three.animation.BooleanKeyframeTrack -- step-only boolean channels
// ('bool'). A boolean cannot be blended, so only DISCRETE interpolation is legal
// (three.js's BooleanKeyframeTrack sets DefaultInterpolation = InterpolateDiscrete
// and rejects anything else).
//
// Values are stored as 0/1 in the numeric buffer; PropertyBinding writes
// `buffer[offset] != 0` back into the boolean property.
package asaot.three.animation
{
    public class BooleanKeyframeTrack extends KeyframeTrack
    {
        public function BooleanKeyframeTrack(name:String, times:*, values:*, interpolation:int = -1)
        {
            super(name, times, values);
            this.valueTypeName = "bool";
            this.defaultInterpolation = InterpolateDiscrete;
            this.initInterpolation(interpolation);
        }

        protected override function supportsInterpolation(interpolation:int):Boolean
        {
            return interpolation == InterpolateDiscrete;
        }
    }
}
