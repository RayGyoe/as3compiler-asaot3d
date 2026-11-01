// asaot.three.math.MathUtils -- pure scalar helpers (clamp/lerp/radian conversion/...).
//
// Borrows the FUNCTION SET of three.js src/math/MathUtils.js (r187), not its JS
// run-time shape. Everything here is a pure static function; no state, no allocation.
// The radian conversion pair (DEG2RAD / RAD2DEG) matches three.js exactly.
//
// WHY NOT IMPORTED FROM three.js: three.js's MathUtils is an ES module exporting
// top-level functions plus internal mutable state (_seed for seededRandom). AS3 has
// no module scope; a final class of static functions is the equivalent shape.
package asaot.three.math
{
    public final class MathUtils
    {
        public static const DEG2RAD:Number = Math.PI / 180;
        public static const RAD2DEG:Number = 180 / Math.PI;

        // Clamp value to the closed interval [min, max].
        public static function clamp(value:Number, min:Number, max:Number):Number
        {
            return Math.max(min, Math.min(max, value));
        }

        // Euclidean modulo: ((n % m) + m) % m, always non-negative.
        public static function euclideanModulo(n:Number, m:Number):Number
        {
            return ((n % m) + m) % m;
        }

        // Linear map from [a1, a2] to [b1, b2].
        public static function mapLinear(x:Number, a1:Number, a2:Number, b1:Number, b2:Number):Number
        {
            return b1 + (x - a1) * (b2 - b1) / (a2 - a1);
        }

        // Inverse of lerp; returns t in [0,1] for value between x and y.
        public static function inverseLerp(x:Number, y:Number, value:Number):Number
        {
            if (x != y) return (value - x) / (y - x);
            return 0;
        }

        // Linear interpolation: (1 - t) * x + t * y.
        public static function lerp(x:Number, y:Number, t:Number):Number
        {
            return (1 - t) * x + t * y;
        }

        // Damped spring toward target: lerp by 1 - exp(-lambda * dt).
        public static function damp(x:Number, y:Number, lambda:Number, dt:Number):Number
        {
            return lerp(x, y, 1 - Math.exp(-lambda * dt));
        }

        // Triangle wave: value folded into [0, 2*length].
        public static function pingpong(x:Number, length:Number):Number
        {
            if (length == 0) return 0;
            return length - Math.abs(euclideanModulo(x, length * 2) - length);
        }

        // Smooth Hermite step: 3t^2 - 2t^3 over [min, max].
        public static function smoothstep(x:Number, min:Number, max:Number):Number
        {
            if (x <= min) return 0;
            if (x >= max) return 1;
            x = (x - min) / (max - min);
            return x * x * (3 - 2 * x);
        }

        // Smoother quintic step: 6t^5 - 15t^4 + 10t^3 over [min, max].
        public static function smootherstep(x:Number, min:Number, max:Number):Number
        {
            if (x <= min) return 0;
            if (x >= max) return 1;
            x = (x - min) / (max - min);
            return x * x * x * (x * (x * 6 - 15) + 10);
        }

        // Random integer in [low, high] (inclusive).
        public static function randInt(low:int, high:int):int
        {
            return low + int(Math.floor(Math.random() * (high - low + 1)));
        }

        // Random float in [low, high).
        public static function randFloat(low:Number, high:Number):Number
        {
            return low + Math.random() * (high - low);
        }

        // Random float in [-range/2, range/2).
        public static function randFloatSpread(range:Number):Number
        {
            return range * (0.5 - Math.random());
        }

        public static function degToRad(degrees:Number):Number
        {
            return degrees * DEG2RAD;
        }

        public static function radToDeg(radians:Number):Number
        {
            return radians * RAD2DEG;
        }

        public static function isPowerOfTwo(value:int):Boolean
        {
            return (value & (value - 1)) == 0 && value != 0;
        }

        public static function ceilPowerOfTwo(value:Number):Number
        {
            return Math.pow(2, Math.ceil(Math.log(value) / Math.LN2));
        }

        public static function floorPowerOfTwo(value:Number):Number
        {
            return Math.pow(2, Math.floor(Math.log(value) / Math.LN2));
        }

        // 128-bit UUID in the canonical 8-4-4-4-12 hex form (lowercase).
        // three.js generates this at module scope for Object3D identity; we keep it
        // for scene-graph `uuid` fields, same format, AS3 implementation.
        public static function generateUUID():String
        {
            var d0:uint = uint(Math.random() * 0xffffffff);
            var d1:uint = uint(Math.random() * 0xffffffff);
            var d2:uint = uint(Math.random() * 0xffffffff);
            var d3:uint = uint(Math.random() * 0xffffffff);
            return hex2(d0 & 0xff) + hex2(d0 >> 8 & 0xff) + hex2(d0 >> 16 & 0xff) + hex2(d0 >> 24 & 0xff) + "-"
                + hex2(d1 & 0xff) + hex2(d1 >> 8 & 0xff) + "-" + hex2((d1 >> 16 & 0x0f) | 0x40) + hex2(d1 >> 24 & 0xff) + "-"
                + hex2((d2 & 0x3f) | 0x80) + hex2(d2 >> 8 & 0xff) + "-" + hex2(d2 >> 16 & 0xff) + hex2(d2 >> 24 & 0xff)
                + hex2(d3 & 0xff) + hex2(d3 >> 8 & 0xff) + hex2(d3 >> 16 & 0xff) + hex2(d3 >> 24 & 0xff);
        }

        private static function hex2(b:uint):String
        {
            var s:String = b.toString(16);
            return s.length == 1 ? "0" + s : s;
        }
    }
}
