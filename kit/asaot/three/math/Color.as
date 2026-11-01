// asaot.three.math.Color -- RGB color stored as 0..1 floats in LINEAR working
// space, 0xRRGGBB I/O on the sRGB side.
//
// Borrows three.js src/math/Color.js (r187) WITH default color management:
// the stored components are linear-sRGB (ColorManagement.workingColorSpace
// default), so `setHex(hex)` decodes sRGB -> linear (Color.js:204-212,
// colorSpace default SRGBColorSpace) and `getHex()` encodes linear -> sRGB
// (Color.js:539-541). `setRGB(r,g,b)` stores working-space values AS-IS
// (Color.js:227-233, default colorSpace is the working space) -- same
// asymmetry as three.js. The transfer functions follow
// ColorManagement.js:186-194 (SRGBToLinear / LinearToSRGB). The renderer's
// output sRGB encode (R7) is the matching other half; see three-api-design.md
// R7/D30.
package asaot.three.math
{
    public class Color
    {
        public var r:Number;
        public var g:Number;
        public var b:Number;

        public function Color(hex:uint = 0xffffff)
        {
            this.setHex(hex);
        }

        public function setHex(hex:uint):Color
        {
            this.r = Color.srgbToLinear((hex >> 16 & 255) / 255);
            this.g = Color.srgbToLinear((hex >> 8 & 255) / 255);
            this.b = Color.srgbToLinear((hex & 255) / 255);
            return this;
        }

        // Working-space setter: values are linear already, stored AS-IS
        // (three.js Color.setRGB defaults to the working color space).
        public function setRGB(r:Number, g:Number, b:Number):Color
        {
            this.r = r;
            this.g = g;
            this.b = b;
            return this;
        }

        public function clone():Color
        {
            return new Color().copy(this);
        }

        public function copy(color:Color):Color
        {
            this.r = color.r;
            this.g = color.g;
            this.b = color.b;
            return this;
        }

        public function getHex():uint
        {
            return uint(Math.round(Color.linearToSrgb(this.r) * 255)) * 65536
                + uint(Math.round(Color.linearToSrgb(this.g) * 255)) * 256
                + uint(Math.round(Color.linearToSrgb(this.b) * 255));
        }

        public function getHexString():String
        {
            var s:String = this.getHex().toString(16).toUpperCase();
            while (s.length < 6) s = "0" + s;
            return s;
        }

        // Component-wise linear interpolation toward color by alpha
        // (both operands are in the linear working space, like three.js).
        public function lerp(color:Color, alpha:Number):Color
        {
            this.r += (color.r - this.r) * alpha;
            this.g += (color.g - this.g) * alpha;
            this.b += (color.b - this.b) * alpha;
            return this;
        }

        public function equals(color:Color):Boolean
        {
            return color.r == this.r && color.g == this.g && color.b == this.b;
        }

        // M12: Color.js:fromArray/toArray, the pair PropertyBinding needs for a
        // `x.material.color` HasFromToArray binding (ColorKeyframeTrack).
        public function fromArray(array:Vector.<Number>, offset:int = 0):Color
        {
            this.r = array[offset];
            this.g = array[offset + 1];
            this.b = array[offset + 2];
            return this;
        }

        public function toArray(array:Vector.<Number> = null, offset:int = 0):Vector.<Number>
        {
            if (array == null) array = new Vector.<Number>(offset + 3);
            array[offset] = this.r;
            array[offset + 1] = this.g;
            array[offset + 2] = this.b;
            return array;
        }

        // ColorManagement.js:186-188 -- SRGBToLinear.
        private static function srgbToLinear(c:Number):Number
        {
            return (c < 0.04045)
                ? c * 0.0773993808
                : Math.pow(c * 0.9478672986 + 0.0521327014, 2.4);
        }

        // ColorManagement.js:192-194 -- LinearToSRGB.
        private static function linearToSrgb(c:Number):Number
        {
            return (c < 0.0031308)
                ? c * 12.92
                : 1.055 * Math.pow(c, 0.41666) - 0.055;
        }
    }
}
