// asaot.three.animation.LinearInterpolant -- per-component lerp between two keys.
//
// Borrows src/math/interpolants/LinearInterpolant.js (r187):
//   weight1 = (t - t0) / (t1 - t0); result[i] = v0[i] * (1 - w) + v1[i] * w
package asaot.three.animation
{
    public class LinearInterpolant extends Interpolant
    {
        public function LinearInterpolant(parameterPositions:Vector.<Number>, sampleValues:Vector.<Number>,
                                          sampleSize:int, resultBuffer:Vector.<Number> = null)
        {
            super(parameterPositions, sampleValues, sampleSize, resultBuffer);
        }

        protected override function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            var result:Vector.<Number> = this.resultBuffer;
            var values:Vector.<Number> = this.sampleValues;
            var stride:int = this.valueSize;

            var offset1:int = i1 * stride;
            var offset0:int = offset1 - stride;
            var weight1:Number = (t - t0) / (t1 - t0);
            var weight0:Number = 1 - weight1;

            for (var i:int = 0; i < stride; i++)
            {
                result[i] = values[offset0 + i] * weight0 + values[offset1 + i] * weight1;
            }

            return result;
        }
    }
}