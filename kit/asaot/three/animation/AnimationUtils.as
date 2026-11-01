// asaot.three.animation.AnimationUtils -- array helpers for the animation core.
//
// Borrows src/animation/AnimationUtils.js (r187). Only the pieces the mixer
// actually needs are borrowed: `convertArray` (track buffers are always
// Vector.<Number>) and `flattenJSON` is NOT borrowed (legacy JSON animation
// tracks are an ObjectLoader concern we do not support -- see
// three-api-design.md §17.8).
//
// DIVERGENCES:
//   D67  AS3 has no ArrayBuffer/typed-array *views*, so every keyframe buffer is
//        an owned Vector.<Number>. convertArray therefore always copies (three.js
//        re-uses the input when the type already matches). The only place the
//        missing view hurts is PropertyMixer's aliased `interpolant.resultBuffer`
//        -- see PropertyMixer.as.
package asaot.three.animation
{
    public class AnimationUtils
    {
        // AnimationUtils.js:convertArray. Accepts an Array, a Vector.<Number> or
        // a Vector.<int> (glTF accessors hand us the latter for STEP samplers on
        // integer data) and returns a freshly allocated Vector.<Number>.
        public static function convertArray(source:*, forceClone:Boolean = false):Vector.<Number>
        {
            var n:int = int(source.length);
            var out:Vector.<Number> = new Vector.<Number>(n);
            for (var i:int = 0; i < n; i++) out[i] = Number(source[i]);
            return out;
        }

        public static function arrayLength(source:*):int
        {
            return int(source.length);
        }

        // True for both Array and any Vector specialization.
        public static function isArrayLike(value:*):Boolean
        {
            if (value == null) return false;
            if (value is Array) return true;
            if (value is Vector.<Number>) return true;
            if (value is Vector.<int>) return true;
            if (value is Vector.<uint>) return true;
            if (value is Vector.<String>) return true;
            return false;
        }
    }
}