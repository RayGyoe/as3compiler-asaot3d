// asaot.three.math.Vector3 -- mutable 3D vector, three.js style.
//
// Borrows the API of three.js src/math/Vector3.js (r187): public x/y/z fields,
// in-place mutating methods that `return this` for chaining. The KEY divergence
// from three.js is D4 (three-api-design.md §8): we do NOT provide the two-argument
// `add(a, b)` convenience overloads that allocate a fresh vector -- only the
// `addVectors(a, b)` "store into this" form, which allocates nothing.
//
// WHY MUTABLE + RETURN THIS: as-aot's arena allocator never reclaims (AGENTS.md
// memory red line); a chaining API that allocates a temp per step would grow the
// arena every frame. Mutating in place is the only hot-path-safe shape.
package asaot.three.math
{
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;

    public class Vector3
    {
        public var x:Number;
        public var y:Number;
        public var z:Number;

        public function Vector3(x:Number = 0, y:Number = 0, z:Number = 0)
        {
            this.x = x;
            this.y = y;
            this.z = z;
        }

        public function set(x:Number, y:Number, z:Number):Vector3
        {
            this.x = x;
            this.y = y;
            this.z = z;
            return this;
        }

        public function setX(x:Number):Vector3 { this.x = x; return this; }
        public function setY(y:Number):Vector3 { this.y = y; return this; }
        public function setZ(z:Number):Vector3 { this.z = z; return this; }

        public function clone():Vector3
        {
            return new Vector3(this.x, this.y, this.z);
        }

        public function copy(v:Vector3):Vector3
        {
            this.x = v.x;
            this.y = v.y;
            this.z = v.z;
            return this;
        }

        public function add(v:Vector3):Vector3
        {
            this.x += v.x;
            this.y += v.y;
            this.z += v.z;
            return this;
        }

        public function addScalar(s:Number):Vector3
        {
            this.x += s;
            this.y += s;
            this.z += s;
            return this;
        }

        // this = a + b (a and b untouched); no allocation.
        public function addVectors(a:Vector3, b:Vector3):Vector3
        {
            this.x = a.x + b.x;
            this.y = a.y + b.y;
            this.z = a.z + b.z;
            return this;
        }

        // this = this + v*s (three.js Vector3.js:278). M4: computeTangents uses it
        // in the Lengyel tangent formula; taking a copy of `v` first keeps it
        // allocation-free at call sites (setup-time only).
        public function addScaledVector(v:Vector3, s:Number):Vector3
        {
            this.x += v.x * s;
            this.y += v.y * s;
            this.z += v.z * s;
            return this;
        }

        public function sub(v:Vector3):Vector3
        {
            this.x -= v.x;
            this.y -= v.y;
            this.z -= v.z;
            return this;
        }

        public function subScalar(s:Number):Vector3
        {
            this.x -= s;
            this.y -= s;
            this.z -= s;
            return this;
        }

        // this = a - b (a and b untouched); no allocation.
        public function subVectors(a:Vector3, b:Vector3):Vector3
        {
            this.x = a.x - b.x;
            this.y = a.y - b.y;
            this.z = a.z - b.z;
            return this;
        }

        public function multiply(v:Vector3):Vector3
        {
            this.x *= v.x;
            this.y *= v.y;
            this.z *= v.z;
            return this;
        }

        public function multiplyScalar(s:Number):Vector3
        {
            this.x *= s;
            this.y *= s;
            this.z *= s;
            return this;
        }

        public function divide(v:Vector3):Vector3
        {
            this.x /= v.x;
            this.y /= v.y;
            this.z /= v.z;
            return this;
        }

        public function divideScalar(s:Number):Vector3
        {
            return this.multiplyScalar(1 / s);
        }

        public function dot(v:Vector3):Number
        {
            return this.x * v.x + this.y * v.y + this.z * v.z;
        }

        // this = this x v (in place).
        public function cross(v:Vector3):Vector3
        {
            return this.crossVectors(this, v);
        }

        // this = a x b (a and b untouched); no allocation.
        public function crossVectors(a:Vector3, b:Vector3):Vector3
        {
            var ax:Number = a.x, ay:Number = a.y, az:Number = a.z;
            var bx:Number = b.x, by:Number = b.y, bz:Number = b.z;
            this.x = ay * bz - az * by;
            this.y = az * bx - ax * bz;
            this.z = ax * by - ay * bx;
            return this;
        }

        public function lengthSq():Number
        {
            return this.x * this.x + this.y * this.y + this.z * this.z;
        }

        public function length():Number
        {
            return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z);
        }

        public function lengthManhattan():Number
        {
            return Math.abs(this.x) + Math.abs(this.y) + Math.abs(this.z);
        }

        public function normalize():Vector3
        {
            return this.divideScalar(this.length() || 1);
        }

        public function setLength(length:Number):Vector3
        {
            return this.normalize().multiplyScalar(length);
        }

        public function min(v:Vector3):Vector3
        {
            this.x = Math.min(this.x, v.x);
            this.y = Math.min(this.y, v.y);
            this.z = Math.min(this.z, v.z);
            return this;
        }

        public function max(v:Vector3):Vector3
        {
            this.x = Math.max(this.x, v.x);
            this.y = Math.max(this.y, v.y);
            this.z = Math.max(this.z, v.z);
            return this;
        }

        public function clamp(min:Vector3, max:Vector3):Vector3
        {
            this.x = Math.max(min.x, Math.min(max.x, this.x));
            this.y = Math.max(min.y, Math.min(max.y, this.y));
            this.z = Math.max(min.z, Math.min(max.z, this.z));
            return this;
        }

        public function clampScalar(minVal:Number, maxVal:Number):Vector3
        {
            this.x = Math.max(minVal, Math.min(maxVal, this.x));
            this.y = Math.max(minVal, Math.min(maxVal, this.y));
            this.z = Math.max(minVal, Math.min(maxVal, this.z));
            return this;
        }

        public function clampLength(min:Number, max:Number):Vector3
        {
            var len:Number = this.length();
            return this.divideScalar(len || 1).multiplyScalar(Math.max(min, Math.min(max, len)));
        }

        public function negate():Vector3
        {
            this.x = -this.x;
            this.y = -this.y;
            this.z = -this.z;
            return this;
        }

        // Component-wise linear interpolation toward v by alpha.
        public function lerp(v:Vector3, alpha:Number):Vector3
        {
            this.x += (v.x - this.x) * alpha;
            this.y += (v.y - this.y) * alpha;
            this.z += (v.z - this.z) * alpha;
            return this;
        }

        // this = a + (b - a) * t (a and b untouched); no allocation.
        public function lerpVectors(a:Vector3, b:Vector3, t:Number):Vector3
        {
            this.x = a.x + (b.x - a.x) * t;
            this.y = a.y + (b.y - a.y) * t;
            this.z = a.z + (b.z - a.z) * t;
            return this;
        }

        // Copy the translation column of a Matrix4 into this vector.
        public function setFromMatrixPosition(m:Matrix4):Vector3
        {
            var e:Vector.<Number> = m.elements;
            this.x = e[12];
            this.y = e[13];
            this.z = e[14];
            return this;
        }

        // Copy one COLUMN (index 0..3) of a Matrix4 into this vector, dropping the
        // fourth component (three.js Vector3.js:setFromMatrixColumn). OrbitControls
        // reads the camera's matrix X/Y columns to pan in screen space (M14).
        public function setFromMatrixColumn(m:Matrix4, index:int):Vector3
        {
            var e:Vector.<Number> = m.elements;
            var o:int = index * 4;
            this.x = e[o];
            this.y = e[o + 1];
            this.z = e[o + 2];
            return this;
        }

        // Transform a DIRECTION (no translation, no perspective divide) and
        // normalize it. three.js Vector3.js:transformDirection. Used by Ray;
        // note it re-normalizes, so it is only correct for directions -- a point
        // goes through applyMatrix4 instead.
        public function transformDirection(m:Matrix4):Vector3
        {
            var x:Number = this.x, y:Number = this.y, z:Number = this.z;
            var e:Vector.<Number> = m.elements;
            this.x = e[0] * x + e[4] * y + e[8] * z;
            this.y = e[1] * x + e[5] * y + e[9] * z;
            this.z = e[2] * x + e[6] * y + e[10] * z;
            return this.normalize();
        }

        // Inverse of Spherical.setFromVector3 (three.js Vector3.js:setFromSpherical).
        public function setFromSpherical(s:Spherical):Vector3
        {
            var sinPhiRadius:Number = Math.sin(s.phi) * s.radius;
            this.x = sinPhiRadius * Math.sin(s.theta);
            this.y = Math.cos(s.phi) * s.radius;
            this.z = sinPhiRadius * Math.cos(s.theta);
            return this;
        }

        // Transform by a 4x4 matrix with perspective divide (point transform).
        public function applyMatrix4(m:Matrix4):Vector3
        {
            var x:Number = this.x, y:Number = this.y, z:Number = this.z;
            var e:Vector.<Number> = m.elements;
            var w:Number = 1 / (e[3] * x + e[7] * y + e[11] * z + e[15]);
            this.x = (e[0] * x + e[4] * y + e[8] * z + e[12]) * w;
            this.y = (e[1] * x + e[5] * y + e[9] * z + e[13]) * w;
            this.z = (e[2] * x + e[6] * y + e[10] * z + e[14]) * w;
            return this;
        }

        // Rotate by a quaternion (assumed normalized).
        public function applyQuaternion(q:Quaternion):Vector3
        {
            var x:Number = this.x, y:Number = this.y, z:Number = this.z;
            var qx:Number = q.x, qy:Number = q.y, qz:Number = q.z, qw:Number = q.w;
            var ix:Number = qw * x + qy * z - qz * y;
            var iy:Number = qw * y + qz * x - qx * z;
            var iz:Number = qw * z + qx * y - qy * x;
            var iw:Number = -qx * x - qy * y - qz * z;
            this.x = ix * qw + iw * -qx + iy * -qz - iz * -qy;
            this.y = iy * qw + iw * -qy + iz * -qx - ix * -qz;
            this.z = iz * qw + iw * -qz + ix * -qy - iy * -qx;
            return this;
        }

        // Rotate around a NORMALIZED axis (Vector3.js applyAxisAngle; three.js
        // borrows a module-scope quaternion, which AS3 has no scope for -- the
        // Rodrigues form needs no temporary at all and is exact for a unit axis).
        public function applyAxisAngle(axis:Vector3, angle:Number):Vector3
        {
            var x:Number = this.x, y:Number = this.y, z:Number = this.z;
            var ax:Number = axis.x, ay:Number = axis.y, az:Number = axis.z;
            var c:Number = Math.cos(angle);
            var s:Number = Math.sin(angle);
            var t:Number = 1 - c;
            var dot:Number = ax * x + ay * y + az * z;
            this.x = x * c + (ay * z - az * y) * s + ax * dot * t;
            this.y = y * c + (az * x - ax * z) * s + ay * dot * t;
            this.z = z * c + (ax * y - ay * x) * s + az * dot * t;
            return this;
        }

        public function angleTo(v:Vector3):Number
        {            var denom:Number = Math.sqrt(this.lengthSq() * v.lengthSq());
            if (denom == 0) return Math.PI / 2;
            var theta:Number = this.dot(v) / denom;
            return Math.acos(Math.max(-1, Math.min(1, theta)));
        }

        public function distanceTo(v:Vector3):Number
        {
            return Math.sqrt(this.distanceToSquared(v));
        }

        public function distanceToSquared(v:Vector3):Number
        {
            var dx:Number = this.x - v.x;
            var dy:Number = this.y - v.y;
            var dz:Number = this.z - v.z;
            return dx * dx + dy * dy + dz * dz;
        }

        public function equals(v:Vector3):Boolean
        {
            return v.x == this.x && v.y == this.y && v.z == this.z;
        }

        // Set a component by index (0=x, 1=y, 2=z). three.js uses `vector[u]` with a
        // string key inside BoxGeometry.buildPlane; AS3 has no dynamic field access, so
        // the index-based accessor carries that instead.
        public function setComponent(index:int, value:Number):Vector3
        {
            if (index == 0) this.x = value;
            else if (index == 1) this.y = value;
            else if (index == 2) this.z = value;
            else throw new Error("Vector3.setComponent: index out of range: " + index);
            return this;
        }

        // Get a component by index (0=x, 1=y, 2=z).
        public function getComponent(index:int):Number
        {
            if (index == 0) return this.x;
            if (index == 1) return this.y;
            if (index == 2) return this.z;
            throw new Error("Vector3.getComponent: index out of range: " + index);
        }

        // Read x/y/z from array[offset..offset+2] (three.js Vector3.js:1168).
        public function fromArray(array:Vector.<Number>, offset:int = 0):Vector3
        {
            this.x = array[offset];
            this.y = array[offset + 1];
            this.z = array[offset + 2];
            return this;
        }

        // M12: Vector3.js:toArray. PropertyBinding's HasFromToArray binding
        // type needs BOTH directions; without toArray a track named
        // `x.position` would bind as a scalar Direct write instead.
        public function toArray(array:Vector.<Number> = null, offset:int = 0):Vector.<Number>
        {
            if (array == null) array = new Vector.<Number>(offset + 3);
            array[offset] = this.x;
            array[offset + 1] = this.y;
            array[offset + 2] = this.z;
            return array;
        }
    }
}
