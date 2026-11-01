// asaot.three.animation.QuaternionLinearInterpolant -- per-key SLERP.
//
// Borrows src/math/interpolants/QuaternionLinearInterpolant.js (r187): the
// buffer is walked in groups of four and each group is slerped flat, which is
// why a quaternion track with several keyframes per time still interpolates as a
// short-arc slerp instead of a component-wise lerp.
package asaot.three.animation
{
    import asaot.three.math.Quaternion;

    public class QuaternionLinearInterpolant extends Interpolant
    {
        public function QuaternionLinearInterpolant(parameterPositions:Vector.<Number>, sampleValues:Vector.<Number>,
                                                    sampleSize:int, resultBuffer:Vector.<Number> = null)
        {
            super(parameterPositions, sampleValues, sampleSize, resultBuffer);
        }

        protected override function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            var result:Vector.<Number> = this.resultBuffer;
            var values:Vector.<Number> = this.sampleValues;
            var stride:int = this.valueSize;

            var alpha:Number = (t - t0) / (t1 - t0);
            var offset:int = i1 * stride;
            var end:int = offset + stride;

            while (offset < end)
            {
                Quaternion.slerpFlat(result, 0, values, offset - stride, values, offset, alpha);
                offset += 4;
            }

            return result;
        }
    }
}