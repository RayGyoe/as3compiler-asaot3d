// asaot.three.animation.GltfCubicSplineInterpolant -- glTF CUBICSPLINE sampling.
//
// Borrows the GLTFCubicSplineInterpolant class at the bottom of
// examples/jsm/loaders/GLTFLoader.js (r187).
//
// A glTF CUBICSPLINE sampler stores THREE values per keyframe:
//
//     [ inTangent_k, splineVertex_k, outTangent_k ]  (k = 0 .. n-1)
//
// so a track's `values` buffer is 3x the geometric stride and the interpolant is
// constructed with `getValueSize() / 3`. The Hermite basis below uses the stored
// tangents (scaled by the interval length), NOT the neighbour-difference tangents
// that CubicInterpolant derives.
package asaot.three.animation
{
    public class GltfCubicSplineInterpolant extends Interpolant
    {
        public function GltfCubicSplineInterpolant(parameterPositions:Vector.<Number>, sampleValues:Vector.<Number>,
                                                   sampleSize:int, resultBuffer:Vector.<Number> = null)
        {
            super(parameterPositions, sampleValues, sampleSize, resultBuffer);
        }

        public override function copySampleValue(index:int):Vector.<Number>
        {
            var result:Vector.<Number> = this.resultBuffer;
            var values:Vector.<Number> = this.sampleValues;
            var valueSize:int = this.valueSize;
            var offset:int = index * valueSize * 3 + valueSize;   // middle of the triple

            for (var i:int = 0; i < valueSize; i++) result[i] = values[offset + i];

            return result;
        }

        protected override function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            var result:Vector.<Number> = this.resultBuffer;
            var values:Vector.<Number> = this.sampleValues;
            var stride:int = this.valueSize;

            var stride2:int = stride * 2;
            var stride3:int = stride * 3;

            var td:Number = t1 - t0;

            var p:Number = (t - t0) / td;
            var pp:Number = p * p;
            var ppp:Number = pp * p;

            var offset1:int = i1 * stride3;
            var offset0:int = offset1 - stride3;

            var s2:Number = -2 * ppp + 3 * pp;
            var s3:Number = ppp - pp;
            var s0:Number = 1 - s2;
            var s1:Number = s3 - pp + p;

            for (var i:int = 0; i < stride; i++)
            {
                var p0:Number = values[offset0 + i + stride];          // splineVertex_k
                var m0:Number = values[offset0 + i + stride2] * td;    // outTangent_k * dt
                var p1:Number = values[offset1 + i + stride];          // splineVertex_k+1
                var m1:Number = values[offset1 + i] * td;              // inTangent_k+1 * dt

                result[i] = s0 * p0 + s1 * m0 + s2 * p1 + s3 * m1;
            }

            return result;
        }
    }
}