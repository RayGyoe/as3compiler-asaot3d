// asaot.three.animation.CubicInterpolant -- cubic Hermite spline through keys.
//
// Borrows src/math/interpolants/CubicInterpolant.js (r187) verbatim in spirit:
// the Hermitian construction whose tangent at each key is the linear slope of
// the neighbouring interval, plus the three ending modes. The weighting only
// depends on the *interval*, so intervalChanged() precomputes _weightPrev /
// _weightNext exactly like three.js.
//
// Endings (src/constants.js:2400-2402):
//   ZeroCurvatureEnding  f''(t) = 0  (natural spline; the default)
//   ZeroSlopeEnding      f'(t)  = 0
//   WrapAroundEnding     borrow the other end of the curve (looping clips)
//
// DIVERGENCES: none.
package asaot.three.animation
{
    public class CubicInterpolant extends Interpolant
    {
        public static const ZeroCurvatureEnding:int = 2400;
        public static const ZeroSlopeEnding:int = 2401;
        public static const WrapAroundEnding:int = 2402;

        private var _weightPrev:Number = 0;
        private var _offsetPrev:int = 0;
        private var _weightNext:Number = 0;
        private var _offsetNext:int = 0;

        public function CubicInterpolant(parameterPositions:Vector.<Number>, sampleValues:Vector.<Number>,
                                         sampleSize:int, resultBuffer:Vector.<Number> = null)
        {
            super(parameterPositions, sampleValues, sampleSize, resultBuffer);
            this.settings = { endingStart: ZeroCurvatureEnding, endingEnd: ZeroCurvatureEnding };
        }

        protected override function intervalChanged(i1:int, t0:Number, t1:Number):void
        {
            var pp:Vector.<Number> = this.parameterPositions;
            var n:int = pp.length;

            var iPrev:int = i1 - 2;
            var iNext:int = i1 + 1;
            var tPrev:Number = 0;
            var tNext:Number = 0;
            var hasPrev:Boolean = (iPrev >= 0);
            var hasNext:Boolean = (iNext < n);
            if (hasPrev) tPrev = pp[iPrev];
            if (hasNext) tNext = pp[iNext];

            if (!hasPrev)
            {
                var startMode:int = int(this.settings["endingStart"]);
                if (startMode == ZeroSlopeEnding)
                {
                    // f'(t0) = 0
                    iPrev = i1;
                    tPrev = 2 * t0 - t1;
                }
                else if (startMode == WrapAroundEnding)
                {
                    // use the other end of the curve
                    iPrev = n - 2;
                    tPrev = t0 + pp[iPrev] - pp[iPrev + 1];
                }
                else
                {
                    // ZeroCurvatureEnding: f''(t0) = 0 (natural spline)
                    iPrev = i1;
                    tPrev = t1;
                }
            }

            if (!hasNext)
            {
                var endMode:int = int(this.settings["endingEnd"]);
                if (endMode == ZeroSlopeEnding)
                {
                    iNext = i1;
                    tNext = 2 * t1 - t0;
                }
                else if (endMode == WrapAroundEnding)
                {
                    iNext = 1;
                    tNext = t1 + pp[1] - pp[0];
                }
                else
                {
                    iNext = i1 - 1;
                    tNext = t0;
                }
            }

            var halfDt:Number = (t1 - t0) * 0.5;
            var stride:int = this.valueSize;

            this._weightPrev = halfDt / (t0 - tPrev);
            this._weightNext = halfDt / (tNext - t1);
            this._offsetPrev = iPrev * stride;
            this._offsetNext = iNext * stride;
        }

        protected override function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            var result:Vector.<Number> = this.resultBuffer;
            var values:Vector.<Number> = this.sampleValues;
            var stride:int = this.valueSize;

            var o1:int = i1 * stride;
            var o0:int = o1 - stride;
            var oP:int = this._offsetPrev;
            var oN:int = this._offsetNext;
            var wP:Number = this._weightPrev;
            var wN:Number = this._weightNext;

            var p:Number = (t - t0) / (t1 - t0);
            var pp:Number = p * p;
            var ppp:Number = pp * p;

            // evaluate the four Hermite basis polynomials
            var sP:Number = -wP * ppp + 2 * wP * pp - wP * p;
            var s0:Number = (1 + wP) * ppp + (-1.5 - 2 * wP) * pp + (-0.5 + wP) * p + 1;
            var s1:Number = (-1 - wN) * ppp + (1.5 + wN) * pp + 0.5 * p;
            var sN:Number = wN * ppp - wN * pp;

            for (var i:int = 0; i < stride; i++)
            {
                result[i] = sP * values[oP + i]
                          + s0 * values[o0 + i]
                          + s1 * values[o1 + i]
                          + sN * values[oN + i];
            }

            return result;
        }
    }
}