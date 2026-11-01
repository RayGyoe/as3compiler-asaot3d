// asaot.three.math.Euler -- Euler angles with a configurable rotation order.
//
// Borrows the algorithm set of three.js src/math/Euler.js (r187): the six
// rotation-order cases of setFromRotationMatrix are copied verbatim. The DEFAULT
// order is "XYZ" (intrinsic rotations, radians), matching three.js.
//
// _onChange MECHANISM (aligns three.js, fixes D6): components live in private
// _x/_y/_z/_order with getter/setter accessors that fire `_onChangeCallback`;
// Object3D hooks that callback to keep the paired Quaternion in sync. This is
// what makes `mesh.rotation.x += 0.01` work: the field write goes through the
// setter, not through Object3D's own `rotation` setter (which is why D6's
// Object3D-level-setter plan would have silently missed it).
//
// DIVERGENCE (AS3 default-param limit): three.js's `set(x, y, z, order = this._order)`
// relies on JS runtime defaulting to `this`. AS3 default parameters must be compile
// constants, so we use a `null` sentinel: passing no order keeps the current one,
// passing a string overrides it. Semantically identical to three.js.
package asaot.three.math
{
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;

    public class Euler
    {
        private var _x:Number;
        private var _y:Number;
        private var _z:Number;
        private var _order:String;
        private var _onChangeCallback:Function = null;

        public function Euler(x:Number = 0, y:Number = 0, z:Number = 0, order:String = "XYZ")
        {
            this._x = x;
            this._y = y;
            this._z = z;
            this._order = order;
        }

        public function get x():Number { return this._x; }
        public function set x(value:Number):void { this._x = value; this._fireChange(); }

        public function get y():Number { return this._y; }
        public function set y(value:Number):void { this._y = value; this._fireChange(); }

        public function get z():Number { return this._z; }
        public function set z(value:Number):void { this._z = value; this._fireChange(); }

        public function get order():String { return this._order; }
        public function set order(value:String):void { this._order = value; this._fireChange(); }

        // Set components; order stays unchanged unless a non-null order is given.
        public function set(x:Number, y:Number, z:Number, order:String = null):Euler
        {
            this._x = x;
            this._y = y;
            this._z = z;
            if (order != null) this._order = order;
            this._fireChange();
            return this;
        }

        public function clone():Euler
        {
            return new Euler(this._x, this._y, this._z, this._order);
        }

        public function copy(euler:Euler):Euler
        {
            this._x = euler._x;
            this._y = euler._y;
            this._z = euler._z;
            this._order = euler._order;
            this._fireChange();
            return this;
        }

        // Extract angles from the upper 3x3 of a pure rotation matrix.
        // `update=false` suppresses the onChange callback (used by the
        // Object3D quaternion->rotation sync to avoid a callback loop).
        public function setFromRotationMatrix(m:Matrix4, order:String = null, update:Boolean = true):Euler
        {
            if (order == null) order = this._order;

            var te:Vector.<Number> = m.elements;
            var m11:Number = te[0], m12:Number = te[4], m13:Number = te[8];
            var m21:Number = te[1], m22:Number = te[5], m23:Number = te[9];
            var m31:Number = te[2], m32:Number = te[6], m33:Number = te[10];

            if (order == "XYZ")
            {
                this._y = Math.asin(MathUtils.clamp(m13, -1, 1));
                if (Math.abs(m13) < 0.9999999)
                {
                    this._x = Math.atan2(-m23, m33);
                    this._z = Math.atan2(-m12, m11);
                }
                else
                {
                    this._x = Math.atan2(m32, m22);
                    this._z = 0;
                }
            }
            else if (order == "YXZ")
            {
                this._x = Math.asin(-MathUtils.clamp(m23, -1, 1));
                if (Math.abs(m23) < 0.9999999)
                {
                    this._y = Math.atan2(m13, m33);
                    this._z = Math.atan2(m21, m22);
                }
                else
                {
                    this._y = Math.atan2(-m31, m11);
                    this._z = 0;
                }
            }
            else if (order == "ZXY")
            {
                this._x = Math.asin(MathUtils.clamp(m32, -1, 1));
                if (Math.abs(m32) < 0.9999999)
                {
                    this._y = Math.atan2(-m31, m33);
                    this._z = Math.atan2(-m12, m22);
                }
                else
                {
                    this._y = 0;
                    this._z = Math.atan2(m21, m11);
                }
            }
            else if (order == "ZYX")
            {
                this._y = Math.asin(-MathUtils.clamp(m31, -1, 1));
                if (Math.abs(m31) < 0.9999999)
                {
                    this._x = Math.atan2(m32, m33);
                    this._z = Math.atan2(m21, m11);
                }
                else
                {
                    this._x = 0;
                    this._z = Math.atan2(-m12, m22);
                }
            }
            else if (order == "YZX")
            {
                this._z = Math.asin(MathUtils.clamp(m21, -1, 1));
                if (Math.abs(m21) < 0.9999999)
                {
                    this._x = Math.atan2(-m23, m22);
                    this._y = Math.atan2(-m31, m11);
                }
                else
                {
                    this._x = 0;
                    this._y = Math.atan2(m13, m33);
                }
            }
            else if (order == "XZY")
            {
                this._z = Math.asin(-MathUtils.clamp(m12, -1, 1));
                if (Math.abs(m12) < 0.9999999)
                {
                    this._x = Math.atan2(m32, m22);
                    this._y = Math.atan2(m13, m11);
                }
                else
                {
                    this._x = Math.atan2(-m23, m33);
                    this._y = 0;
                }
            }
            else
            {
                throw new Error("Euler.setFromRotationMatrix: unknown order '" + order + "'");
            }

            this._order = order;
            if (update) this._fireChange();
            return this;
        }

        // Extract angles from a quaternion (via its rotation matrix).
        public function setFromQuaternion(q:Quaternion, order:String = null, update:Boolean = true):Euler
        {
            var m:Matrix4 = new Matrix4();
            m.makeRotationFromQuaternion(q);
            return this.setFromRotationMatrix(m, order, update);
        }

        // Convert the angle triple to a new rotation order in place.
        public function reorder(newOrder:String):Euler
        {
            var q:Quaternion = new Quaternion().setFromEuler(this);
            return this.setFromQuaternion(q, newOrder);
        }

        public function equals(euler:Euler):Boolean
        {
            return euler._x == this._x && euler._y == this._y && euler._z == this._z && euler._order == this._order;
        }

        // Read x/y/z from array (three.js Euler.js:387). DIVERGENCE: three.js
        // also reads array[3] as the order STRING, but a Vector.<Number> cannot
        // carry it; AS3 keeps the current order (default "XYZ") and callers that
        // need a non-default order set `euler.order` afterward.
        public function fromArray(array:Vector.<Number>):Euler
        {
            this._x = array[0];
            this._y = array[1];
            this._z = array[2];
            this._fireChange();
            return this;
        }

        // Hook the onChange callback (Object3D wires quaternion sync here).
        public function _onChange(callback:Function):Euler
        {
            this._onChangeCallback = callback;
            return this;
        }

        private function _fireChange():void
        {
            if (this._onChangeCallback != null) this._onChangeCallback();
        }
    }
}
