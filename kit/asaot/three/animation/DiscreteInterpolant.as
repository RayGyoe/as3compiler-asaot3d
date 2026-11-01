// asaot.three.animation.DiscreteInterpolant -- step (hold) interpolation.
//
// Borrows src/math/interpolants/DiscreteInterpolant.js (r187): the value of the
// key at or before the sample time, i.e. the sample at the START of the interval
// (three.js expresses it as copySampleValue_( i1 - 1 )).
package asaot.three.animation
{
    public class DiscreteInterpolant extends Interpolant
    {
        public function DiscreteInterpolant(parameterPositions:Vector.<Number>, sampleValues:Vector.<Number>,
                                            sampleSize:int, resultBuffer:Vector.<Number> = null)
        {
            super(parameterPositions, sampleValues, sampleSize, resultBuffer);
        }

        protected override function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            return this.copySampleValue(i1 - 1);
        }
    }
}