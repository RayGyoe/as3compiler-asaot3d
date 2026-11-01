// asaot.three.animation.Interpolant -- keyframe interpolation base class.
//
// Borrows src/math/Interpolant.js (r187): parameterPositions / sampleValues /
// valueSize / resultBuffer, the cached-interval search, and the out-of-range
// clamp (before the first key -> first sample, at/after the last key -> last
// sample; three.js reaches the same result through `undefined` reads).
//
// DIVERGENCES:
//   D68  AS3 Vector.<Number> throws on an out-of-range read instead of yielding
//        `undefined`, so the interval search is written with explicit bounds
//        rather than three.js's `t1 === undefined` sentinels. Semantics match.
//   D69  A degenerate interval (duplicate key times) copies the sample at the
//        interval end instead of dividing 0/0 into NaN. three.js produces NaN
//        here, which then poisons the whole transform.
package asaot.three.animation
{
    public class Interpolant
    {
        public var parameterPositions:Vector.<Number>;
        public var sampleValues:Vector.<Number>;
        public var valueSize:int;
        public var resultBuffer:Vector.<Number>;

        // Shared { endingStart, endingEnd } object owned by AnimationAction for
        // CubicInterpolant (the ending modes are a per-action property in
        // three.js: AnimationAction._interpolantSettings).
        public var settings:Object = null;

        protected var _cachedIndex:int = 0;

        public function Interpolant(parameterPositions:Vector.<Number>, sampleValues:Vector.<Number>,
                                   sampleSize:int, resultBuffer:Vector.<Number> = null)
        {
            this.parameterPositions = parameterPositions;
            this.sampleValues = sampleValues;
            this.valueSize = sampleSize;
            this.resultBuffer = (resultBuffer != null) ? resultBuffer : new Vector.<Number>(sampleSize);
        }

        // Interpolant.js:evaluate. Returns resultBuffer (never null).
        public function evaluate(t:Number):Vector.<Number>
        {
            var pp:Vector.<Number> = this.parameterPositions;
            var n:int = pp.length;
            if (n == 0) return this.resultBuffer;
            if (t < pp[0]) return this.copySampleValue(0);
            if (t >= pp[n - 1]) return this.copySampleValue(n - 1);

            // Seek the interval i1 with pp[i1 - 1] <= t < pp[i1], starting from
            // the cached index (temporal coherence: clips are sampled forward).
            var i1:int = this._cachedIndex;
            if (i1 < 1) i1 = 1;
            if (i1 > n - 1) i1 = n - 1;
            while (i1 < n - 1 && pp[i1] <= t) i1++;
            while (i1 > 1 && pp[i1 - 1] > t) i1--;

            var t1:Number = pp[i1];
            var t0:Number = pp[i1 - 1];
            this._cachedIndex = i1;

            if (t1 == t0) return this.copySampleValue(i1); // D69

            this.intervalChanged(i1, t0, t1);
            return this.interpolate(i1, t0, t, t1);
        }

        public function copySampleValue(index:int):Vector.<Number>
        {
            var result:Vector.<Number> = this.resultBuffer;
            var values:Vector.<Number> = this.sampleValues;
            var stride:int = this.valueSize;
            var offset:int = index * stride;
            for (var i:int = 0; i < stride; i++) result[i] = values[offset + i];
            return result;
        }

        protected function intervalChanged(i1:int, t0:Number, t1:Number):void
        {
            // only CubicInterpolant uses this hook
        }

        protected function interpolate(i1:int, t0:Number, t:Number, t1:Number):Vector.<Number>
        {
            return this.resultBuffer;
        }
    }
}