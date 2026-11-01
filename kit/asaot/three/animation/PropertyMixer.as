// asaot.three.animation.PropertyMixer -- weighted accumulation buffer for one
// animated property.
//
// Borrows src/animation/PropertyMixer.js (r187): the `[incoming | accu0 | accu1 |
// orig | addAccu]` buffer layout, `accumulate()`'s running-weight normalisation,
// `apply()`'s "blend back toward the original when the total weight is < 1" rule
// and its change detection against the *other* accumulator, plus
// save/restoreOriginalState.
//
// The blend operator is chosen by the track's valueTypeName:
//   quaternion -> slerp, bool/string -> select (hold), everything else -> lerp.
//
// DIVERGENCES:
//   D67  No typed-array views. three.js aliases `interpolant.resultBuffer` onto
//        offset 0 of this buffer; here the mixer simply holds a reference to the
//        interpolant's own result vector (`incoming`) and accumulate() reads from
//        it. No extra copy, and no aliasing hazard.
//   D76  Additive animation (AdditiveAnimationBlendMode) is not borrowed, so the
//        `addAccu` region and accumulateAdditive()/applyAdditive() are absent.
package asaot.three.animation
{
    import asaot.three.math.Quaternion;

    public class PropertyMixer
    {
        private static const MIX_LERP:int = 0;
        private static const MIX_SLERP:int = 1;
        private static const MIX_SELECT:int = 2;

        public var binding:PropertyBinding;
        public var valueSize:int;

        // [ incoming | accu0 | accu1 | orig ] -- incoming is never stored here
        // (see D67); regions start at index 1.
        public var buffer:Vector.<Number>;

        public var incoming:Vector.<Number>;

        public var cumulativeWeight:Number = 0;
        public var useCount:int = 0;
        public var referenceCount:int = 0;

        private var _origIndex:int = 3;
        private var _mixType:int = MIX_LERP;

        public function PropertyMixer(binding:PropertyBinding, typeName:String, valueSize:int)
        {
            this.binding = binding;
            this.valueSize = valueSize;
            this.buffer = new Vector.<Number>(valueSize * 5);
            this.incoming = new Vector.<Number>(valueSize);

            if (typeName == "quaternion")
            {
                this._mixType = MIX_SLERP;
            }
            else if (typeName == "bool" || typeName == "string")
            {
                this._mixType = MIX_SELECT;
            }
            else
            {
                this._mixType = MIX_LERP;
            }
        }

        // PropertyMixer.js:accumulate. `weight` is the action's effective weight.
        // Note the running normalisation: the accumulator always holds the
        // weighted *mean* of everything mixed into it so far.
        public function accumulate(accuIndex:int, weight:Number):void
        {
            var stride:int = this.valueSize;
            var offset:int = accuIndex * stride + stride;

            // Our incoming data lives in its own vector (D67: no aliasing a
            // Float64Array region), so mirror it into buffer region 0 first --
            // that region is what three.js's alias makes `incoming`, and
            // _mixBufferRegion() mixes toward it on the second and later actions.
            for (var c:int = 0; c < stride; c++) this.buffer[c] = this.incoming[c];

            var currentWeight:Number = this.cumulativeWeight;

            if (currentWeight == 0)
            {
                // accuN := incoming
                for (var i:int = 0; i < stride; i++) this.buffer[offset + i] = this.incoming[i];
                currentWeight = weight;
            }
            else
            {
                // accuN := accuN + incoming * weight, renormalised
                currentWeight += weight;
                var mix:Number = weight / currentWeight;
                this._mixBufferRegion(offset, 0, mix, stride);
            }

            this.cumulativeWeight = currentWeight;
        }

        // PropertyMixer.js:apply. Writes to the scene graph only when the
        // accumulated value actually differs from the previous frame's.
        public function apply(accuIndex:int):void
        {
            var stride:int = this.valueSize;
            var offset:int = accuIndex * stride + stride;
            var weight:Number = this.cumulativeWeight;

            this.cumulativeWeight = 0;

            if (weight < 1)
            {
                // blend the original value back in (weight 0 == fully original)
                var originalValueOffset:int = stride * this._origIndex;
                this._mixBufferRegion(offset, originalValueOffset, 1 - weight, stride);
            }

            for (var i:int = stride, e:int = stride + stride; i < e; i++)
            {
                if (this.buffer[i] != this.buffer[i + stride])
                {
                    this.binding.setValue(this.buffer, offset);
                    break;
                }
            }
        }

        public function saveOriginalState():void
        {
            var stride:int = this.valueSize;
            var originalValueOffset:int = stride * this._origIndex;

            this.binding.getValue(this.buffer, originalValueOffset);

            // accu[0..1] := orig -- initially detect changes against the original
            for (var i:int = stride, e:int = originalValueOffset; i < e; i++)
            {
                this.buffer[i] = this.buffer[originalValueOffset + (i % stride)];
            }

            // Additive identity (all zero); unused until D76 is lifted.
            var addStart:int = 4 * stride;
            for (var j:int = addStart; j < addStart + stride; j++) this.buffer[j] = 0;

            this.cumulativeWeight = 0;
        }

        public function restoreOriginalState():void
        {
            this.binding.setValue(this.buffer, this._origIndex * this.valueSize);
        }

        // ------------------------------------------------------------------
        // Blend operators (PropertyMixer._lerp / _slerp / _select)
        // ------------------------------------------------------------------

        // buffer[dst] = buffer[dst] * (1 - t) + (source) * t
        private function _mixBufferRegion(dstOffset:int, srcOffset:int, t:Number, stride:int):void
        {
            var buffer:Vector.<Number> = this.buffer;
            var i:int;
            var j:int;

            if (this._mixType == MIX_SLERP && stride == 4)
            {
                Quaternion.slerpFlat(buffer, dstOffset, buffer, dstOffset, buffer, srcOffset, t);
                return;
            }

            if (this._mixType == MIX_SELECT)
            {
                if (t >= 0.5)
                {
                    for (i = 0; i < stride; i++) buffer[dstOffset + i] = buffer[srcOffset + i];
                }
                return;
            }

            var s:Number = 1 - t;
            for (i = 0; i < stride; i++)
            {
                j = dstOffset + i;
                buffer[j] = buffer[j] * s + buffer[srcOffset + i] * t;
            }
        }
    }
}