// asaot.three.math.Vector2 -- mutable 2D vector, three.js style.
//
// Same conventions as Vector3 (in-place mutators returning `this`, no allocating
// two-argument overloads per D4). Needed for UVs and 2D math; kept minimal.
package asaot.three.math
{
    public class Vector2
    {
        public var x:Number;
        public var y:Number;

        public function Vector2(x:Number = 0, y:Number = 0)
        {
            this.x = x;
            this.y = y;
        }

        public function set(x:Number, y:Number):Vector2
        {
            this.x = x;
            this.y = y;
            return this;
        }

        public function setX(x:Number):Vector2 { this.x = x; return this; }
        public function setY(y:Number):Vector2 { this.y = y; return this; }

        public function clone():Vector2
        {
            return new Vector2(this.x, this.y);
        }

        public function copy(v:Vector2):Vector2
        {
            this.x = v.x;
            this.y = v.y;
            return this;
        }

        public function add(v:Vector2):Vector2
        {
            this.x += v.x;
            this.y += v.y;
            return this;
        }

        public function addScalar(s:Number):Vector2
        {
            this.x += s;
            this.y += s;
            return this;
        }

        public function addVectors(a:Vector2, b:Vector2):Vector2
        {
            this.x = a.x + b.x;
            this.y = a.y + b.y;
            return this;
        }

        public function sub(v:Vector2):Vector2
        {
            this.x -= v.x;
            this.y -= v.y;
            return this;
        }

        public function subVectors(a:Vector2, b:Vector2):Vector2
        {
            this.x = a.x - b.x;
            this.y = a.y - b.y;
            return this;
        }

        public function multiply(v:Vector2):Vector2
        {
            this.x *= v.x;
            this.y *= v.y;
            return this;
        }

        public function multiplyScalar(s:Number):Vector2
        {
            this.x *= s;
            this.y *= s;
            return this;
        }

        public function divide(v:Vector2):Vector2
        {
            this.x /= v.x;
            this.y /= v.y;
            return this;
        }

        public function divideScalar(s:Number):Vector2
        {
            return this.multiplyScalar(1 / s);
        }

        public function dot(v:Vector2):Number
        {
            return this.x * v.x + this.y * v.y;
        }

        public function cross(v:Vector2):Number
        {
            return this.x * v.y - this.y * v.x;
        }

        public function lengthSq():Number
        {
            return this.x * this.x + this.y * this.y;
        }

        public function length():Number
        {
            return Math.sqrt(this.x * this.x + this.y * this.y);
        }

        public function normalize():Vector2
        {
            return this.divideScalar(this.length() || 1);
        }

        public function negate():Vector2
        {
            this.x = -this.x;
            this.y = -this.y;
            return this;
        }

        public function lerp(v:Vector2, alpha:Number):Vector2
        {
            this.x += (v.x - this.x) * alpha;
            this.y += (v.y - this.y) * alpha;
            return this;
        }

        public function lerpVectors(a:Vector2, b:Vector2, t:Number):Vector2
        {
            this.x = a.x + (b.x - a.x) * t;
            this.y = a.y + (b.y - a.y) * t;
            return this;
        }

        public function distanceTo(v:Vector2):Number
        {
            return Math.sqrt(this.distanceToSquared(v));
        }

        public function distanceToSquared(v:Vector2):Number
        {
            var dx:Number = this.x - v.x;
            var dy:Number = this.y - v.y;
            return dx * dx + dy * dy;
        }

        public function equals(v:Vector2):Boolean
        {
            return v.x == this.x && v.y == this.y;
        }
    }
}
