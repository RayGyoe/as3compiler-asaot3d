// asaot.three.math.Quaternion -- mutable unit quaternion, three.js style.
//
// Borrows the algorithm set of three.js src/math/Quaternion.js (r187):
// setFromEuler's six rotation-order cases, setFromRotationMatrix's trace branch
// selection, multiplyQuaternions, and slerp are copied verbatim (semantics are
// language-neutral).
//
// _onChange MECHANISM (aligns three.js, fixes D6): components live in private
// _x/_y/_z/_w with getter/setter accessors that fire `_onChangeCallback`.
// Object3D hooks this to keep the paired Euler in sync (the other half of the
// rotation<->quaternion two-way sync). Mutating methods write _x/_y/_z/_w
// directly and fire the callback once at the end (not once per component), the
// same discipline three.js uses.
package asaot.three.math
{
    import asaot.three.math.Euler;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector3;

    public class Quaternion
    {
        private var _x:Number;
        private var _y:Number;
        private var _z:Number;
        private var _w:Number;
        private var _onChangeCallback:Function = null;

        public function Quaternion(x:Number = 0, y:Number = 0, z:Number = 0, w:Number = 1)
        {
            this._x = x;
            this._y = y;
            this._z = z;
            this._w = w;
        }

        public function get x():Number { return this._x; }
        public function set x(value:Number):void { this._x = value; this._fireChange(); }

        public function get y():Number { return this._y; }
        public function set y(value:Number):void { this._y = value; this._fireChange(); }

        public function get z():Number { return this._z; }
        public function set z(value:Number):void { this._z = value; this._fireChange(); }

        public function get w():Number { return this._w; }
        public function set w(value:Number):void { this._w = value; this._fireChange(); }

        public function set(x:Number, y:Number, z:Number, w:Number):Quaternion
        {
            this._x = x;
            this._y = y;
            this._z = z;
            this._w = w;
            this._fireChange();
            return this;
        }

        public function clone():Quaternion
        {
            return new Quaternion(this._x, this._y, this._z, this._w);
        }

        public function copy(q:Quaternion):Quaternion
        {
            this._x = q._x;
            this._y = q._y;
            this._z = q._z;
            this._w = q._w;
            this._fireChange();
            return this;
        }

        public function identity():Quaternion
        {
            return this.set(0, 0, 0, 1);
        }

        // Set from an Euler rotation (honors euler.order among the six cases).
        // `update=false` suppresses the onChange callback (used by Object3D's
        // rotation->quaternion sync to avoid a callback loop).
        public function setFromEuler(euler:Euler, update:Boolean = true):Quaternion
        {
            var ex:Number = euler.x, ey:Number = euler.y, ez:Number = euler.z;
            var order:String = euler.order;

            var c1:Number = Math.cos(ex / 2);
            var c2:Number = Math.cos(ey / 2);
            var c3:Number = Math.cos(ez / 2);
            var s1:Number = Math.sin(ex / 2);
            var s2:Number = Math.sin(ey / 2);
            var s3:Number = Math.sin(ez / 2);

            if (order == "XYZ")
            {
                this._x = s1 * c2 * c3 + c1 * s2 * s3;
                this._y = c1 * s2 * c3 - s1 * c2 * s3;
                this._z = c1 * c2 * s3 + s1 * s2 * c3;
                this._w = c1 * c2 * c3 - s1 * s2 * s3;
            }
            else if (order == "YXZ")
            {
                this._x = s1 * c2 * c3 + c1 * s2 * s3;
                this._y = c1 * s2 * c3 - s1 * c2 * s3;
                this._z = c1 * c2 * s3 - s1 * s2 * c3;
                this._w = c1 * c2 * c3 + s1 * s2 * s3;
            }
            else if (order == "ZXY")
            {
                this._x = s1 * c2 * c3 - c1 * s2 * s3;
                this._y = c1 * s2 * c3 + s1 * c2 * s3;
                this._z = c1 * c2 * s3 + s1 * s2 * c3;
                this._w = c1 * c2 * c3 - s1 * s2 * s3;
            }
            else if (order == "ZYX")
            {
                this._x = s1 * c2 * c3 - c1 * s2 * s3;
                this._y = c1 * s2 * c3 + s1 * c2 * s3;
                this._z = c1 * c2 * s3 - s1 * s2 * c3;
                this._w = c1 * c2 * c3 + s1 * s2 * s3;
            }
            else if (order == "YZX")
            {
                this._x = s1 * c2 * c3 + c1 * s2 * s3;
                this._y = c1 * s2 * c3 + s1 * c2 * s3;
                this._z = c1 * c2 * s3 - s1 * s2 * c3;
                this._w = c1 * c2 * c3 - s1 * s2 * s3;
            }
            else if (order == "XZY")
            {
                this._x = s1 * c2 * c3 - c1 * s2 * s3;
                this._y = c1 * s2 * c3 - s1 * c2 * s3;
                this._z = c1 * c2 * s3 + s1 * s2 * c3;
                this._w = c1 * c2 * c3 + s1 * s2 * s3;
            }
            else
            {
                throw new Error("Quaternion.setFromEuler: unknown order '" + order + "'");
            }

            if (update) this._fireChange();
            return this;
        }

        // Set from a normalized axis and angle (radians).
        public function setFromAxisAngle(axis:Vector3, angle:Number):Quaternion
        {
            var halfAngle:Number = angle / 2;
            var s:Number = Math.sin(halfAngle);
            this._x = axis.x * s;
            this._y = axis.y * s;
            this._z = axis.z * s;
            this._w = Math.cos(halfAngle);
            this._fireChange();
            return this;
        }

        // Set from the upper 3x3 of a pure rotation matrix (assumed unscaled).
        public function setFromRotationMatrix(m:Matrix4):Quaternion
        {
            var te:Vector.<Number> = m.elements;
            var m11:Number = te[0], m12:Number = te[4], m13:Number = te[8];
            var m21:Number = te[1], m22:Number = te[5], m23:Number = te[9];
            var m31:Number = te[2], m32:Number = te[6], m33:Number = te[10];
            var trace:Number = m11 + m22 + m33;

            if (trace > 0)
            {
                var s:Number = 0.5 / Math.sqrt(trace + 1.0);
                this._w = 0.25 / s;
                this._x = (m32 - m23) * s;
                this._y = (m13 - m31) * s;
                this._z = (m21 - m12) * s;
            }
            else if (m11 > m22 && m11 > m33)
            {
                var s2:Number = 2.0 * Math.sqrt(1.0 + m11 - m22 - m33);
                this._w = (m32 - m23) / s2;
                this._x = 0.25 * s2;
                this._y = (m12 + m21) / s2;
                this._z = (m13 + m31) / s2;
            }
            else if (m22 > m33)
            {
                var s3:Number = 2.0 * Math.sqrt(1.0 + m22 - m11 - m33);
                this._w = (m13 - m31) / s3;
                this._x = (m12 + m21) / s3;
                this._y = 0.25 * s3;
                this._z = (m23 + m32) / s3;
            }
            else
            {
                var s4:Number = 2.0 * Math.sqrt(1.0 + m33 - m11 - m22);
                this._w = (m21 - m12) / s4;
                this._x = (m13 + m31) / s4;
                this._y = (m23 + m32) / s4;
                this._z = 0.25 * s4;
            }

            this._fireChange();
            return this;
        }

        // Rotation taking vFrom to vTo (both assumed normalized).
        public function setFromUnitVectors(vFrom:Vector3, vTo:Vector3):Quaternion
        {
            var r:Number = vFrom.dot(vTo) + 1;
            if (r < 1e-8)
            {
                // Opposite directions: pick an orthogonal axis.
                r = 0;
                if (Math.abs(vFrom.x) > Math.abs(vFrom.z))
                {
                    this._x = -vFrom.y;
                    this._y = vFrom.x;
                    this._z = 0;
                    this._w = r;
                }
                else
                {
                    this._x = 0;
                    this._y = -vFrom.z;
                    this._z = vFrom.y;
                    this._w = r;
                }
            }
            else
            {
                // Inlined cross product (avoids a Vector3 temp).
                this._x = vFrom.y * vTo.z - vFrom.z * vTo.y;
                this._y = vFrom.z * vTo.x - vFrom.x * vTo.z;
                this._z = vFrom.x * vTo.y - vFrom.y * vTo.x;
                this._w = r;
            }
            return this.normalize();
        }

        public function lengthSq():Number
        {
            return this._x * this._x + this._y * this._y + this._z * this._z + this._w * this._w;
        }

        public function length():Number
        {
            return Math.sqrt(this._x * this._x + this._y * this._y + this._z * this._z + this._w * this._w);
        }

        public function normalize():Quaternion
        {
            var l:Number = this.length();
            if (l == 0)
            {
                this._x = 0;
                this._y = 0;
                this._z = 0;
                this._w = 1;
            }
            else
            {
                l = 1 / l;
                this._x *= l;
                this._y *= l;
                this._z *= l;
                this._w *= l;
            }
            this._fireChange();
            return this;
        }

        public function invert():Quaternion
        {
            return this.conjugate().normalize();
        }

        public function conjugate():Quaternion
        {
            this._x = -this._x;
            this._y = -this._y;
            this._z = -this._z;
            this._fireChange();
            return this;
        }

        public function dot(q:Quaternion):Number
        {
            return this._x * q._x + this._y * q._y + this._z * q._z + this._w * q._w;
        }

        public function multiply(q:Quaternion):Quaternion
        {
            return this.multiplyQuaternions(this, q);
        }

        public function premultiply(q:Quaternion):Quaternion
        {
            return this.multiplyQuaternions(q, this);
        }

        // this = a * b (Hamilton product, a and b untouched).
        public function multiplyQuaternions(a:Quaternion, b:Quaternion):Quaternion
        {
            var qax:Number = a._x, qay:Number = a._y, qaz:Number = a._z, qaw:Number = a._w;
            var qbx:Number = b._x, qby:Number = b._y, qbz:Number = b._z, qbw:Number = b._w;
            this._x = qax * qbw + qaw * qbx + qay * qbz - qaz * qby;
            this._y = qay * qbw + qaw * qby + qaz * qbx - qax * qbz;
            this._z = qaz * qbw + qaw * qbz + qax * qby - qay * qbx;
            this._w = qaw * qbw - qax * qbx - qay * qby - qaz * qbz;
            this._fireChange();
            return this;
        }

        // Spherical linear interpolation toward qb by t (shortest path).
        // Algorithm copied verbatim from three.js r187 Quaternion.slerp: small
        // angles (< acos(0.9995)) fall back to lerp + normalize to stay stable.
        public function slerp(qb:Quaternion, t:Number):Quaternion
        {
            var x:Number = qb._x, y:Number = qb._y, z:Number = qb._z, w:Number = qb._w;

            var dot:Number = this.dot(qb);
            if (dot < 0)
            {
                x = -x; y = -y; z = -z; w = -w;
                dot = -dot;
            }

            var s:Number = 1 - t;
            if (dot < 0.9995)
            {
                // slerp
                var theta:Number = Math.acos(dot);
                var sinTheta:Number = Math.sin(theta);
                s = Math.sin(s * theta) / sinTheta;
                t = Math.sin(t * theta) / sinTheta;

                this._x = this._x * s + x * t;
                this._y = this._y * s + y * t;
                this._z = this._z * s + z * t;
                this._w = this._w * s + w * t;

                this._fireChange();
            }
            else
            {
                // Small angle: lerp, then normalize for stability.
                this._x = this._x * s + x * t;
                this._y = this._y * s + y * t;
                this._z = this._z * s + z * t;
                this._w = this._w * s + w * t;
                this.normalize(); // normalize fires _fireChange()
            }

            return this;
        }

        // M26: the angle between two orientations, and a STEP-limited turn toward
        // another one (Quaternion.js angleTo / rotateTowards). Needed by the walk
        // demo, which turns the character toward its movement direction instead of
        // snapping: OrbitControls' azimuth is a rotation, the character's facing is
        // a quaternion, and slerping between them at a fixed rate is three.js's
        // answer.
        public function angleTo(q:Quaternion):Number
        {
            var d:Number = Math.abs(this.dot(q));
            if (d > 1) d = 1;
            return 2 * Math.acos(d);
        }

        public function rotateTowards(q:Quaternion, step:Number):Quaternion
        {
            var angle:Number = this.angleTo(q);
            if (angle == 0) return this;
            var t:Number = Math.min(1, step / angle);
            this.slerp(q, t);
            return this;
        }

        public function equals(q:Quaternion):Boolean
        {
            return q._x == this._x && q._y == this._y && q._z == this._z && q._w == this._w;
        }

        // Read x/y/z/w from array[offset..offset+3] (three.js Quaternion.js:823).
        public function fromArray(array:Vector.<Number>, offset:int = 0):Quaternion
        {
            this._x = array[offset];
            this._y = array[offset + 1];
            this._z = array[offset + 2];
            this._w = array[offset + 3];
            this._fireChange();
            return this;
        }

        // M12: Quaternion.js:slerpFlat (static). The animation interpolants
        // slerp straight out of their flat sample buffers, so they need the
        // array-in / array-out form rather than the instance slerp.
        public static function slerpFlat(dst:Vector.<Number>, dstOffset:int,
                                         src0:Vector.<Number>, srcOffset0:int,
                                         src1:Vector.<Number>, srcOffset1:int,
                                         t:Number):void
        {
            var x0:Number = src0[srcOffset0 + 0];
            var y0:Number = src0[srcOffset0 + 1];
            var z0:Number = src0[srcOffset0 + 2];
            var w0:Number = src0[srcOffset0 + 3];

            var x1:Number = src1[srcOffset1 + 0];
            var y1:Number = src1[srcOffset1 + 1];
            var z1:Number = src1[srcOffset1 + 2];
            var w1:Number = src1[srcOffset1 + 3];

            if (w0 != w1 || x0 != x1 || y0 != y1 || z0 != z1)
            {
                var dot:Number = x0 * x1 + y0 * y1 + z0 * z1 + w0 * w1;

                if (dot < 0)
                {
                    x1 = -x1;
                    y1 = -y1;
                    z1 = -z1;
                    w1 = -w1;
                    dot = -dot;
                }

                var s:Number = 1 - t;

                if (dot < 0.9995)
                {
                    var theta:Number = Math.acos(dot);
                    var sin:Number = Math.sin(theta);

                    s = Math.sin(s * theta) / sin;
                    t = Math.sin(t * theta) / sin;

                    x0 = x0 * s + x1 * t;
                    y0 = y0 * s + y1 * t;
                    z0 = z0 * s + z1 * t;
                    w0 = w0 * s + w1 * t;
                }
                else
                {
                    // Small angles: lerp then renormalize (avoids a 0/0 sin).
                    x0 = x0 * s + x1 * t;
                    y0 = y0 * s + y1 * t;
                    z0 = z0 * s + z1 * t;
                    w0 = w0 * s + w1 * t;

                    var f:Number = 1 / Math.sqrt(x0 * x0 + y0 * y0 + z0 * z0 + w0 * w0);
                    x0 *= f;
                    y0 *= f;
                    z0 *= f;
                    w0 *= f;
                }
            }

            dst[dstOffset] = x0;
            dst[dstOffset + 1] = y0;
            dst[dstOffset + 2] = z0;
            dst[dstOffset + 3] = w0;
        }

        // M12: Quaternion.js:toArray (PropertyBinding HasFromToArray).
        public function toArray(array:Vector.<Number> = null, offset:int = 0):Vector.<Number>
        {
            if (array == null) array = new Vector.<Number>(offset + 4);
            array[offset] = this._x;
            array[offset + 1] = this._y;
            array[offset + 2] = this._z;
            array[offset + 3] = this._w;
            return array;
        }

        // Hook the onChange callback (Object3D wires Euler sync here).
        public function _onChange(callback:Function):Quaternion
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
