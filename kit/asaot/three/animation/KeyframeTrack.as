// asaot.three.animation.KeyframeTrack -- a timed sequence of keyframes for one
// animatable property.
//
// Borrows src/animation/KeyframeTrack.js (r187): name/times/values, the
// interpolation selector (InterpolateDiscrete / InterpolateLinear /
// InterpolateSmooth) with its per-track-type default, getValueSize(), and the
// shift/scale/trim/validate helpers that AnimationClip uses.
//
// Interpolation constants mirror src/constants.js:2300-2302.
//
// DIVERGENCES:
//   D70  The interpolant factory is a normal overridable method backed by an
//        int selector. three.js re-assigns `this.createInterpolant` to a factory
//        method pointer in setInterpolation(); AS3 cannot re-point a method per
//        instance, and an int selector is also friendlier to AOT (no function
//        value dispatch on the sampling hot path).
//   D71  `toJSON` and `optimize()` are not borrowed (no serialiser in this kit).
//   D72  Keyframe buffers are Vector.<Number> (D67). Times are always numbers,
//        so a `string`/`bool` track keeps its payload in `values` as 0/1 for
//        bool; BooleanKeyframeTrack is Discrete-only, as in three.js.
package asaot.three.animation
{
    public class KeyframeTrack
    {
        public static const InterpolateDiscrete:int = 2300;
        public static const InterpolateLinear:int = 2301;
        public static const InterpolateSmooth:int = 2302;
        // Extension (not a three.js constant): glTF CUBICSPLINE stores
        // [inTangent, value, outTangent] per key, so this mode is only produced by
        // GLTFLoader (see GltfCubicSplineInterpolant).
        public static const InterpolateCubicSpline:int = 2303;

        public var name:String;
        public var times:Vector.<Number>;
        public var values:Vector.<Number>;

        // three.js `ValueTypeName` ('number' | 'vector' | 'quaternion' | 'color'
        // | 'bool'). PropertyMixer switches on it to pick its blend operator.
        public var valueTypeName:String = "number";

        // three.js `DefaultInterpolation`, per track type.
        public var defaultInterpolation:int = InterpolateLinear;

        protected var _interpolation:int = InterpolateLinear;

        public function KeyframeTrack(name:String, times:*, values:*, interpolation:int = -1)
        {
            if (name == null) throw new Error("THREE.KeyframeTrack: track name is undefined");
            if (times == null || times.length == 0)
            {
                throw new Error("THREE.KeyframeTrack: no keyframes in track named " + name);
            }

            this.name = name;
            this.times = AnimationUtils.convertArray(times);
            this.values = AnimationUtils.convertArray(values);
        }

        // Called by every subclass constructor once valueTypeName /
        // defaultInterpolation are known (see D70).
        protected function initInterpolation(interpolation:int):void
        {
            if (interpolation == -1) interpolation = this.defaultInterpolation;
            this.setInterpolation(interpolation);
        }

        public function setInterpolation(interpolation:int):KeyframeTrack
        {
            if (!this.supportsInterpolation(interpolation))
            {
                interpolation = this.defaultInterpolation;
            }
            this._interpolation = interpolation;
            return this;
        }

        public function getInterpolation():int
        {
            return this._interpolation;
        }

        protected function supportsInterpolation(interpolation:int):Boolean
        {
            return interpolation == InterpolateDiscrete
                || interpolation == InterpolateLinear
                || interpolation == InterpolateSmooth
                || interpolation == InterpolateCubicSpline;
        }

        public function getValueSize():int
        {
            return int(this.values.length / this.times.length);
        }

        // M12: the sample stride a PropertyMixer must allocate. For every mode but
        // glTF CUBICSPLINE this is getValueSize(); CUBICSPLINE buffers carry three
        // values per key (inTangent, value, outTangent), so the accumulator needs
        // one third of it.
        //
        // DIVERGENCE (see three-api-design.md §17.5): AnimationMixer._bindAction in
        // r187 sizes the PropertyMixer from getValueSize() even for CUBICSPLINE
        // tracks, whose interpolant is built with getValueSize() / 3 -- the
        // accumulator then reads past the values the interpolant writes. We size
        // the mixer from the interpolant's stride instead.
        public function getValueStride():int
        {
            var size:int = this.getValueSize();
            return (this._interpolation == InterpolateCubicSpline) ? int(size / 3) : size;
        }

        // KeyframeTrack.js:createInterpolant + the three InterpolantFactory
        // methods. QuaternionKeyframeTrack overrides _createLinearInterpolant.
        public function createInterpolant(resultBuffer:Vector.<Number> = null):Interpolant
        {
            if (this._interpolation == InterpolateDiscrete)
            {
                return new DiscreteInterpolant(this.times, this.values, this.getValueSize(), resultBuffer);
            }
            if (this._interpolation == InterpolateSmooth)
            {
                return new CubicInterpolant(this.times, this.values, this.getValueSize(), resultBuffer);
            }
            if (this._interpolation == InterpolateCubicSpline)
            {
                return this._createCubicSplineInterpolant(resultBuffer);
            }
            return this._createLinearInterpolant(resultBuffer);
        }

        protected function _createCubicSplineInterpolant(resultBuffer:Vector.<Number>):Interpolant
        {
            return new GltfCubicSplineInterpolant(this.times, this.values, int(this.getValueSize() / 3), resultBuffer);
        }

        protected function _createLinearInterpolant(resultBuffer:Vector.<Number>):Interpolant
        {
            return new LinearInterpolant(this.times, this.values, this.getValueSize(), resultBuffer);
        }

        // Move all keys in time.
        public function shift(timeOffset:Number):KeyframeTrack
        {
            if (timeOffset != 0)
            {
                var n:int = this.times.length;
                for (var i:int = 0; i < n; i++) this.times[i] += timeOffset;
            }
            return this;
        }

        // Scale all key times (frame <-> seconds conversions).
        public function scale(timeScale:Number):KeyframeTrack
        {
            if (timeScale != 1)
            {
                var n:int = this.times.length;
                for (var i:int = 0; i < n; i++) this.times[i] *= timeScale;
            }
            return this;
        }

        // Drop keys outside [startTime, endTime] without shifting the rest.
        public function trim(startTime:Number, endTime:Number):KeyframeTrack
        {
            var times:Vector.<Number> = this.times;
            var nKeys:int = times.length;

            var from:int = 0;
            var to:int = nKeys - 1;

            while (from != nKeys && times[from] < startTime) from++;
            while (to != -1 && times[to] > endTime) to--;
            to++; // inclusive -> exclusive bound

            if (from != 0 || to != nKeys)
            {
                // empty tracks are forbidden, so keep at least one keyframe
                if (from >= to)
                {
                    to = (to > 1) ? to : 1;
                    from = to - 1;
                }

                var stride:int = this.getValueSize();

                var newTimes:Vector.<Number> = new Vector.<Number>(to - from);
                for (var i:int = from; i < to; i++) newTimes[i - from] = times[i];

                var newValues:Vector.<Number> = new Vector.<Number>((to - from) * stride);
                var src:int = from * stride;
                for (var j:int = 0; j < (to - from) * stride; j++) newValues[j] = this.values[src + j];

                this.times = newTimes;
                this.values = newValues;
            }

            return this;
        }

        // Minimal validation: an integral value size and matching buffer lengths.
        public function validate():Boolean
        {
            var valueSize:int = this.getValueSize();
            var nTimes:int = this.times.length;
            var ok:Boolean = true;

            if (valueSize < 1) ok = false;
            if (nTimes < 1) ok = false;
            if (valueSize * nTimes != this.values.length) ok = false;

            // non-monotonic times break the interval search
            for (var i:int = 1; i < nTimes; i++)
            {
                if (this.times[i] < this.times[i - 1]) ok = false;
            }

            return ok;
        }
    }
}