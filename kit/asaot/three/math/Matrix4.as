// asaot.three.math.Matrix4 -- 4x4 matrix, column-major storage, three.js style.
//
// Borrows the algorithm set of three.js src/math/Matrix4.js (r187): set takes
// ROW-major arguments but stores COLUMN-major (so elements[4] is row1/col2),
// multiplyMatrices, compose/decompose, lookAt, makePerspective (Stage3D [0,1] depth),
// and invert are copied verbatim (with the depth range adapted from WebGL [-1,1]
// to Stage3D/Metal [0,1]). Column-major matches AGAL/OpenGL ordering so
// the renderer can upload `elements` with zero transposition.
//
// Hot-path note: `multiply`/`multiplyMatrices`/`compose` allocate nothing. The
// non-hot helpers (lookAt/decompose/invert) allocate one or two scratch objects;
// that is acceptable per AGENTS.md since they run at setup time, not per frame.
package asaot.three.math
{
    import asaot.three.math.Euler;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;

    public class Matrix4
    {
        public var elements:Vector.<Number>;

        // Defaults are the identity, so `new Matrix4()` is identity and
        // `new Matrix4(n11, ..., n44)` sets a specific row-major matrix.
        public function Matrix4(
            n11:Number = 1, n12:Number = 0, n13:Number = 0, n14:Number = 0,
            n21:Number = 0, n22:Number = 1, n23:Number = 0, n24:Number = 0,
            n31:Number = 0, n32:Number = 0, n33:Number = 1, n34:Number = 0,
            n41:Number = 0, n42:Number = 0, n43:Number = 0, n44:Number = 1)
        {
            this.elements = new Vector.<Number>(16);
            this.set(n11, n12, n13, n14, n21, n22, n23, n24, n31, n32, n33, n34, n41, n42, n43, n44);
        }

        // Row-major arguments -> column-major storage.
        public function set(
            n11:Number, n12:Number, n13:Number, n14:Number,
            n21:Number, n22:Number, n23:Number, n24:Number,
            n31:Number, n32:Number, n33:Number, n34:Number,
            n41:Number, n42:Number, n43:Number, n44:Number):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            te[0] = n11; te[4] = n12; te[8] = n13; te[12] = n14;
            te[1] = n21; te[5] = n22; te[9] = n23; te[13] = n24;
            te[2] = n31; te[6] = n32; te[10] = n33; te[14] = n34;
            te[3] = n41; te[7] = n42; te[11] = n43; te[15] = n44;
            return this;
        }

        public function identity():Matrix4
        {
            return this.set(
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1);
        }

        public function clone():Matrix4
        {
            var te:Vector.<Number> = this.elements;
            return new Matrix4(
                te[0], te[4], te[8], te[12],
                te[1], te[5], te[9], te[13],
                te[2], te[6], te[10], te[14],
                te[3], te[7], te[11], te[15]);
        }

        public function copy(m:Matrix4):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var me:Vector.<Number> = m.elements;
            for (var i:int = 0; i < 16; i++) te[i] = me[i];
            return this;
        }

        // Copy only the translation column (12/13/14).
        public function copyPosition(m:Matrix4):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var me:Vector.<Number> = m.elements;
            te[12] = me[12];
            te[13] = me[13];
            te[14] = me[14];
            return this;
        }

        // Keep only the upper 3x3, normalized per column to remove scale.
        public function extractRotation(m:Matrix4):Matrix4
        {
            if (m.determinantAffine() == 0) return this.identity();

            var te:Vector.<Number> = this.elements;
            var me:Vector.<Number> = m.elements;

            var scaleX:Number = 1 / Math.sqrt(me[0] * me[0] + me[1] * me[1] + me[2] * me[2]);
            var scaleY:Number = 1 / Math.sqrt(me[4] * me[4] + me[5] * me[5] + me[6] * me[6]);
            var scaleZ:Number = 1 / Math.sqrt(me[8] * me[8] + me[9] * me[9] + me[10] * me[10]);

            te[0] = me[0] * scaleX; te[4] = me[4] * scaleY; te[8] = me[8] * scaleZ;
            te[1] = me[1] * scaleX; te[5] = me[5] * scaleY; te[9] = me[9] * scaleZ;
            te[2] = me[2] * scaleX; te[6] = me[6] * scaleY; te[10] = me[10] * scaleZ;
            te[3] = 0; te[7] = 0; te[11] = 0;
            te[12] = 0; te[13] = 0; te[14] = 0; te[15] = 1;
            return this;
        }

        // Set the rotation component from Euler angles (honors euler.order).
        public function makeRotationFromEuler(euler:Euler):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var x:Number = euler.x, y:Number = euler.y, z:Number = euler.z;
            var a:Number = Math.cos(x), b:Number = Math.sin(x);
            var c:Number = Math.cos(y), d:Number = Math.sin(y);
            var e:Number = Math.cos(z), f:Number = Math.sin(z);

            if (euler.order == "XYZ")
            {
                var ae:Number = a * e, af:Number = a * f, be:Number = b * e, bf:Number = b * f;
                te[0] = c * e; te[4] = -c * f; te[8] = d;
                te[1] = af + be * d; te[5] = ae - bf * d; te[9] = -b * c;
                te[2] = bf - ae * d; te[6] = be + af * d; te[10] = a * c;
            }
            else if (euler.order == "YXZ")
            {
                var ce:Number = c * e, cf:Number = c * f, de:Number = d * e, df:Number = d * f;
                te[0] = ce + df * b; te[4] = de * b - cf; te[8] = a * d;
                te[1] = a * f; te[5] = a * e; te[9] = -b;
                te[2] = cf * b - de; te[6] = df + ce * b; te[10] = a * c;
            }
            else if (euler.order == "ZXY")
            {
                var ce2:Number = c * e, cf2:Number = c * f, de2:Number = d * e, df2:Number = d * f;
                te[0] = ce2 - df2 * b; te[4] = -a * f; te[8] = de2 + cf2 * b;
                te[1] = cf2 + de2 * b; te[5] = a * e; te[9] = df2 - ce2 * b;
                te[2] = -a * d; te[6] = b; te[10] = a * c;
            }
            else if (euler.order == "ZYX")
            {
                var ae2:Number = a * e, af2:Number = a * f, be2:Number = b * e, bf2:Number = b * f;
                te[0] = c * e; te[4] = be2 * d - af2; te[8] = ae2 * d + bf2;
                te[1] = c * f; te[5] = bf2 * d + ae2; te[9] = af2 * d - be2;
                te[2] = -d; te[6] = b * c; te[10] = a * c;
            }
            else if (euler.order == "YZX")
            {
                var ac:Number = a * c, ad:Number = a * d, bc:Number = b * c, bd:Number = b * d;
                te[0] = c * e; te[4] = bd - ac * f; te[8] = bc * f + ad;
                te[1] = f; te[5] = a * e; te[9] = -b * e;
                te[2] = -d * e; te[6] = ad * f + bc; te[10] = ac - bd * f;
            }
            else if (euler.order == "XZY")
            {
                var ac2:Number = a * c, ad2:Number = a * d, bc2:Number = b * c, bd2:Number = b * d;
                te[0] = c * e; te[4] = -f; te[8] = d * e;
                te[1] = ac2 * f + bd2; te[5] = a * e; te[9] = ad2 * f - bc2;
                te[2] = bc2 * f - ad2; te[6] = b * e; te[10] = bd2 * f + ac2;
            }
            else
            {
                throw new Error("Matrix4.makeRotationFromEuler: unknown order '" + euler.order + "'");
            }

            te[3] = 0; te[7] = 0; te[11] = 0;
            te[12] = 0; te[13] = 0; te[14] = 0; te[15] = 1;
            return this;
        }

        // Set the rotation component from a quaternion; rest is identity.
        // Inlined from compose(zero, q, one) to avoid scratch allocation (hot path).
        public function makeRotationFromQuaternion(q:Quaternion):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var x:Number = q.x, y:Number = q.y, z:Number = q.z, w:Number = q.w;
            var x2:Number = x + x, y2:Number = y + y, z2:Number = z + z;
            var xx:Number = x * x2, xy:Number = x * y2, xz:Number = x * z2;
            var yy:Number = y * y2, yz:Number = y * z2, zz:Number = z * z2;
            var wx:Number = w * x2, wy:Number = w * y2, wz:Number = w * z2;

            te[0] = 1 - (yy + zz); te[4] = xy - wz; te[8] = xz + wy;
            te[1] = xy + wz; te[5] = 1 - (xx + zz); te[9] = yz - wx;
            te[2] = xz - wy; te[6] = yz + wx; te[10] = 1 - (xx + yy);
            te[3] = 0; te[7] = 0; te[11] = 0;
            te[12] = 0; te[13] = 0; te[14] = 0; te[15] = 1;
            return this;
        }

        // Look from eye toward target, oriented by up (right-handed, +Z toward viewer).
        public function lookAt(eye:Vector3, target:Vector3, up:Vector3):Matrix4
        {
            var te:Vector.<Number> = this.elements;

            var z:Vector3 = new Vector3().subVectors(eye, target);
            if (z.lengthSq() == 0) z.z = 1;
            z.normalize();

            var x:Vector3 = new Vector3().crossVectors(up, z);
            if (x.lengthSq() == 0)
            {
                if (Math.abs(up.z) == 1) z.x += 0.0001;
                else z.z += 0.0001;
                z.normalize();
                x.crossVectors(up, z);
            }
            x.normalize();

            var y:Vector3 = new Vector3().crossVectors(z, x);

            te[0] = x.x; te[4] = y.x; te[8] = z.x;
            te[1] = x.y; te[5] = y.y; te[9] = z.y;
            te[2] = x.z; te[6] = y.z; te[10] = z.z;
            return this;
        }

        // Post-multiply: this = this * m.
        public function multiply(m:Matrix4):Matrix4
        {
            return this.multiplyMatrices(this, m);
        }

        // Pre-multiply: this = m * this.
        public function premultiply(m:Matrix4):Matrix4
        {
            return this.multiplyMatrices(m, this);
        }

        // this = a * b (a and b untouched); no allocation.
        public function multiplyMatrices(a:Matrix4, b:Matrix4):Matrix4
        {
            var ae:Vector.<Number> = a.elements;
            var be:Vector.<Number> = b.elements;
            var te:Vector.<Number> = this.elements;

            var a11:Number = ae[0], a12:Number = ae[4], a13:Number = ae[8], a14:Number = ae[12];
            var a21:Number = ae[1], a22:Number = ae[5], a23:Number = ae[9], a24:Number = ae[13];
            var a31:Number = ae[2], a32:Number = ae[6], a33:Number = ae[10], a34:Number = ae[14];
            var a41:Number = ae[3], a42:Number = ae[7], a43:Number = ae[11], a44:Number = ae[15];

            var b11:Number = be[0], b12:Number = be[4], b13:Number = be[8], b14:Number = be[12];
            var b21:Number = be[1], b22:Number = be[5], b23:Number = be[9], b24:Number = be[13];
            var b31:Number = be[2], b32:Number = be[6], b33:Number = be[10], b34:Number = be[14];
            var b41:Number = be[3], b42:Number = be[7], b43:Number = be[11], b44:Number = be[15];

            te[0] = a11 * b11 + a12 * b21 + a13 * b31 + a14 * b41;
            te[4] = a11 * b12 + a12 * b22 + a13 * b32 + a14 * b42;
            te[8] = a11 * b13 + a12 * b23 + a13 * b33 + a14 * b43;
            te[12] = a11 * b14 + a12 * b24 + a13 * b34 + a14 * b44;

            te[1] = a21 * b11 + a22 * b21 + a23 * b31 + a24 * b41;
            te[5] = a21 * b12 + a22 * b22 + a23 * b32 + a24 * b42;
            te[9] = a21 * b13 + a22 * b23 + a23 * b33 + a24 * b43;
            te[13] = a21 * b14 + a22 * b24 + a23 * b34 + a24 * b44;

            te[2] = a31 * b11 + a32 * b21 + a33 * b31 + a34 * b41;
            te[6] = a31 * b12 + a32 * b22 + a33 * b32 + a34 * b42;
            te[10] = a31 * b13 + a32 * b23 + a33 * b33 + a34 * b43;
            te[14] = a31 * b14 + a32 * b24 + a33 * b34 + a34 * b44;

            te[3] = a41 * b11 + a42 * b21 + a43 * b31 + a44 * b41;
            te[7] = a41 * b12 + a42 * b22 + a43 * b32 + a44 * b42;
            te[11] = a41 * b13 + a42 * b23 + a43 * b33 + a44 * b43;
            te[15] = a41 * b14 + a42 * b24 + a43 * b34 + a44 * b44;
            return this;
        }

        public function multiplyScalar(s:Number):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            for (var i:int = 0; i < 16; i++) te[i] *= s;
            return this;
        }

        public function determinant():Number
        {
            var te:Vector.<Number> = this.elements;
            var n11:Number = te[0], n12:Number = te[4], n13:Number = te[8], n14:Number = te[12];
            var n21:Number = te[1], n22:Number = te[5], n23:Number = te[9], n24:Number = te[13];
            var n31:Number = te[2], n32:Number = te[6], n33:Number = te[10], n34:Number = te[14];
            var n41:Number = te[3], n42:Number = te[7], n43:Number = te[11], n44:Number = te[15];

            var t11:Number = n23 * n34 - n24 * n33;
            var t12:Number = n22 * n34 - n24 * n32;
            var t13:Number = n22 * n33 - n23 * n32;
            var t21:Number = n21 * n34 - n24 * n31;
            var t22:Number = n21 * n33 - n23 * n31;
            var t23:Number = n21 * n32 - n22 * n31;

            return n11 * (n42 * t11 - n43 * t12 + n44 * t13) -
                n12 * (n41 * t11 - n43 * t21 + n44 * t22) +
                n13 * (n41 * t12 - n42 * t21 + n44 * t23) -
                n14 * (n41 * t13 - n42 * t22 + n43 * t23);
        }

        // 3x3 determinant (assumes affine bottom row [0,0,0,1]).
        public function determinantAffine():Number
        {
            var te:Vector.<Number> = this.elements;
            var n11:Number = te[0], n12:Number = te[4], n13:Number = te[8];
            var n21:Number = te[1], n22:Number = te[5], n23:Number = te[9];
            var n31:Number = te[2], n32:Number = te[6], n33:Number = te[10];

            return n11 * (n22 * n33 - n23 * n32) -
                n12 * (n21 * n33 - n23 * n31) +
                n13 * (n21 * n32 - n22 * n31);
        }

        public function transpose():Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var tmp:Number;
            tmp = te[1]; te[1] = te[4]; te[4] = tmp;
            tmp = te[2]; te[2] = te[8]; te[8] = tmp;
            tmp = te[6]; te[6] = te[9]; te[9] = tmp;
            tmp = te[3]; te[3] = te[12]; te[12] = tmp;
            tmp = te[7]; te[7] = te[13]; te[13] = tmp;
            tmp = te[11]; te[11] = te[14]; te[14] = tmp;
            return this;
        }

        public function setPosition(x:Number, y:Number, z:Number):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            te[12] = x;
            te[13] = y;
            te[14] = z;
            return this;
        }

        // Invert in place (analytic method); zero matrix if singular.
        public function invert():Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var n11:Number = te[0], n21:Number = te[1], n31:Number = te[2], n41:Number = te[3];
            var n12:Number = te[4], n22:Number = te[5], n32:Number = te[6], n42:Number = te[7];
            var n13:Number = te[8], n23:Number = te[9], n33:Number = te[10], n43:Number = te[11];
            var n14:Number = te[12], n24:Number = te[13], n34:Number = te[14], n44:Number = te[15];

            var t1:Number = n11 * n22 - n21 * n12;
            var t2:Number = n11 * n32 - n31 * n12;
            var t3:Number = n11 * n42 - n41 * n12;
            var t4:Number = n21 * n32 - n31 * n22;
            var t5:Number = n21 * n42 - n41 * n22;
            var t6:Number = n31 * n42 - n41 * n32;
            var t7:Number = n13 * n24 - n23 * n14;
            var t8:Number = n13 * n34 - n33 * n14;
            var t9:Number = n13 * n44 - n43 * n14;
            var t10:Number = n23 * n34 - n33 * n24;
            var t11:Number = n23 * n44 - n43 * n24;
            var t12:Number = n33 * n44 - n43 * n34;

            var det:Number = t1 * t12 - t2 * t11 + t3 * t10 + t4 * t9 - t5 * t8 + t6 * t7;
            if (det == 0) return this.set(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

            var detInv:Number = 1 / det;

            te[0] = (n22 * t12 - n32 * t11 + n42 * t10) * detInv;
            te[1] = (n31 * t11 - n21 * t12 - n41 * t10) * detInv;
            te[2] = (n24 * t6 - n34 * t5 + n44 * t4) * detInv;
            te[3] = (n33 * t5 - n23 * t6 - n43 * t4) * detInv;

            te[4] = (n32 * t9 - n12 * t12 - n42 * t8) * detInv;
            te[5] = (n11 * t12 - n31 * t9 + n41 * t8) * detInv;
            te[6] = (n34 * t3 - n14 * t6 - n44 * t2) * detInv;
            te[7] = (n13 * t6 - n33 * t3 + n43 * t2) * detInv;

            te[8] = (n12 * t11 - n22 * t9 + n42 * t7) * detInv;
            te[9] = (n21 * t9 - n11 * t11 - n41 * t7) * detInv;
            te[10] = (n14 * t5 - n24 * t3 + n44 * t1) * detInv;
            te[11] = (n23 * t3 - n13 * t5 - n43 * t1) * detInv;

            te[12] = (n22 * t8 - n12 * t10 - n32 * t7) * detInv;
            te[13] = (n11 * t10 - n21 * t8 + n31 * t7) * detInv;
            te[14] = (n24 * t2 - n14 * t4 - n34 * t1) * detInv;
            te[15] = (n13 * t4 - n23 * t2 + n33 * t1) * detInv;
            return this;
        }

        // Compose from position (translation), quaternion (rotation), scale.
        public function compose(position:Vector3, quaternion:Quaternion, scale:Vector3):Matrix4
        {
            var te:Vector.<Number> = this.elements;

            var x:Number = quaternion.x, y:Number = quaternion.y, z:Number = quaternion.z, w:Number = quaternion.w;
            var x2:Number = x + x, y2:Number = y + y, z2:Number = z + z;
            var xx:Number = x * x2, xy:Number = x * y2, xz:Number = x * z2;
            var yy:Number = y * y2, yz:Number = y * z2, zz:Number = z * z2;
            var wx:Number = w * x2, wy:Number = w * y2, wz:Number = w * z2;

            var sx:Number = scale.x, sy:Number = scale.y, sz:Number = scale.z;

            te[0] = (1 - (yy + zz)) * sx;
            te[1] = (xy + wz) * sx;
            te[2] = (xz - wy) * sx;
            te[3] = 0;

            te[4] = (xy - wz) * sy;
            te[5] = (1 - (xx + zz)) * sy;
            te[6] = (yz + wx) * sy;
            te[7] = 0;

            te[8] = (xz + wy) * sz;
            te[9] = (yz - wx) * sz;
            te[10] = (1 - (xx + yy)) * sz;
            te[11] = 0;

            te[12] = position.x;
            te[13] = position.y;
            te[14] = position.z;
            te[15] = 1;
            return this;
        }

        // Decompose into position, quaternion, scale (in the given targets).
        public function decompose(position:Vector3, quaternion:Quaternion, scale:Vector3):Matrix4
        {
            var te:Vector.<Number> = this.elements;

            position.x = te[12];
            position.y = te[13];
            position.z = te[14];

            var det:Number = this.determinantAffine();
            if (det == 0)
            {
                scale.set(1, 1, 1);
                quaternion.identity();
                return this;
            }

            var sx:Number = Math.sqrt(te[0] * te[0] + te[1] * te[1] + te[2] * te[2]);
            var sy:Number = Math.sqrt(te[4] * te[4] + te[5] * te[5] + te[6] * te[6]);
            var sz:Number = Math.sqrt(te[8] * te[8] + te[9] * te[9] + te[10] * te[10]);

            // Negative determinant: mirroring; fold the sign into one scale.
            if (det < 0) sx = -sx;

            var m1:Matrix4 = new Matrix4().copy(this);
            var invSX:Number = 1 / sx;
            var invSY:Number = 1 / sy;
            var invSZ:Number = 1 / sz;
            var me:Vector.<Number> = m1.elements;

            me[0] *= invSX; me[1] *= invSX; me[2] *= invSX;
            me[4] *= invSY; me[5] *= invSY; me[6] *= invSY;
            me[8] *= invSZ; me[9] *= invSZ; me[10] *= invSZ;

            quaternion.setFromRotationMatrix(m1);
            scale.set(sx, sy, sz);
            return this;
        }

        // Perspective projection (Stage3D/Metal depth range [0, 1]).
        public function makePerspective(left:Number, right:Number, top:Number, bottom:Number, near:Number, far:Number):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var x:Number = 2 * near / (right - left);
            var y:Number = 2 * near / (top - bottom);
            var a:Number = (right + left) / (right - left);
            var b:Number = (top + bottom) / (top - bottom);
            var c:Number = -far / (far - near);
            var d:Number = (-far * near) / (far - near);

            te[0] = x; te[4] = 0; te[8] = a; te[12] = 0;
            te[1] = 0; te[5] = y; te[9] = b; te[13] = 0;
            te[2] = 0; te[6] = 0; te[10] = c; te[14] = d;
            te[3] = 0; te[7] = 0; te[11] = -1; te[15] = 0;
            return this;
        }

        // Orthographic projection (Stage3D/Metal depth range [0, 1]).
        public function makeOrthographic(left:Number, right:Number, top:Number, bottom:Number, near:Number, far:Number):Matrix4
        {
            var te:Vector.<Number> = this.elements;
            var w:Number = 1.0 / (right - left);
            var h:Number = 1.0 / (top - bottom);
            var p:Number = 1.0 / (far - near);

            var x:Number = (right + left) * w;
            var y:Number = (top + bottom) * h;

            te[0] = 2 * w; te[4] = 0; te[8] = 0; te[12] = -x;
            te[1] = 0; te[5] = 2 * h; te[9] = 0; te[13] = -y;
            te[2] = 0; te[6] = 0; te[10] = -p; te[14] = -near * p;
            te[3] = 0; te[7] = 0; te[11] = 0; te[15] = 1;
            return this;
        }

        // Set the matrix to a pure scale (three.js Matrix4.js:1466). M11 needs it
        // for the Sphere.applyMatrix4 / Box3.applyMatrix4 tests.
        public function makeScale(x:Number, y:Number, z:Number):Matrix4
        {
            this.set(
                x, 0, 0, 0,
                0, y, 0, 0,
                0, 0, z, 0,
                0, 0, 0, 1
            );
            return this;
        }

        public function equals(m:Matrix4):Boolean
        {
            var te:Vector.<Number> = this.elements;
            var me:Vector.<Number> = m.elements;
            for (var i:int = 0; i < 16; i++)
            {
                if (te[i] != me[i]) return false;
            }
            return true;
        }

        // Read 16 column-major elements from array[offset..offset+15]
        // (three.js Matrix4.js:1274).
        public function fromArray(array:Vector.<Number>, offset:int = 0):Matrix4
        {
            for (var i:int = 0; i < 16; i++)
            {
                this.elements[i] = array[i + offset];
            }
            return this;
        }

        // M12: Matrix4.js:toArray. Skeleton.update flattens the per-bone offset
        // matrices into the skinning palette with this.
        public function toArray(array:Vector.<Number> = null, offset:int = 0):Vector.<Number>
        {
            if (array == null) array = new Vector.<Number>(offset + 16);
            for (var i:int = 0; i < 16; i++)
            {
                array[i + offset] = this.elements[i];
            }
            return array;
        }

        // Largest per-axis scale factor (three.js Matrix4.js:1174). M11 needs it
        // to grow a bounding sphere's radius by the object's world scale
        // (Sphere.applyMatrix4).
        public function getMaxScaleOnAxis():Number
        {
            var te:Vector.<Number> = this.elements;
            var scaleXSq:Number = te[0] * te[0] + te[1] * te[1] + te[2] * te[2];
            var scaleYSq:Number = te[4] * te[4] + te[5] * te[5] + te[6] * te[6];
            var scaleZSq:Number = te[8] * te[8] + te[9] * te[9] + te[10] * te[10];
            return Math.sqrt(Math.max(scaleXSq, Math.max(scaleYSq, scaleZSq)));
        }
    }
}
