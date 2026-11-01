// asaot.three.math.Vector4 -- mutable 4D vector, three.js style.
//
// Same conventions as Vector3. Used for quaternion-adjacent 4-tuples and
// homogeneous coords; kept minimal for M1.
package asaot.three.math
{
    public class Vector4
    {
        public var x:Number;
        public var y:Number;
        public var z:Number;
        public var w:Number;

        public function Vector4(x:Number = 0, y:Number = 0, z:Number = 0, w:Number = 1)
        {
            this.x = x;
            this.y = y;
            this.z = z;
            this.w = w;
        }

        public function set(x:Number, y:Number, z:Number, w:Number):Vector4
        {
            this.x = x;
            this.y = y;
            this.z = z;
            this.w = w;
            return this;
        }

        public function clone():Vector4
        {
            return new Vector4(this.x, this.y, this.z, this.w);
        }

        public function copy(v:Vector4):Vector4
        {
            this.x = v.x;
            this.y = v.y;
            this.z = v.z;
            this.w = v.w;
            return this;
        }

        public function add(v:Vector4):Vector4
        {
            this.x += v.x;
            this.y += v.y;
            this.z += v.z;
            this.w += v.w;
            return this;
        }

        public function addVectors(a:Vector4, b:Vector4):Vector4
        {
            this.x = a.x + b.x;
            this.y = a.y + b.y;
            this.z = a.z + b.z;
            this.w = a.w + b.w;
            return this;
        }

        public function sub(v:Vector4):Vector4
        {
            this.x -= v.x;
            this.y -= v.y;
            this.z -= v.z;
            this.w -= v.w;
            return this;
        }

        public function multiplyScalar(s:Number):Vector4
        {
            this.x *= s;
            this.y *= s;
            this.z *= s;
            this.w *= s;
            return this;
        }

        public function divideScalar(s:Number):Vector4
        {
            return this.multiplyScalar(1 / s);
        }

        public function dot(v:Vector4):Number
        {
            return this.x * v.x + this.y * v.y + this.z * v.z + this.w * v.w;
        }

        public function lengthSq():Number
        {
            return this.x * this.x + this.y * this.y + this.z * this.z + this.w * this.w;
        }

        public function length():Number
        {
            return Math.sqrt(this.lengthSq());
        }

        public function normalize():Vector4
        {
            return this.divideScalar(this.length() || 1);
        }

        public function lerp(v:Vector4, alpha:Number):Vector4
        {
            this.x += (v.x - this.x) * alpha;
            this.y += (v.y - this.y) * alpha;
            this.z += (v.z - this.z) * alpha;
            this.w += (v.w - this.w) * alpha;
            return this;
        }

        public function equals(v:Vector4):Boolean
        {
            return v.x == this.x && v.y == this.y && v.z == this.z && v.w == this.w;
        }
    }
}
