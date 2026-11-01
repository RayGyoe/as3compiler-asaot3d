// asaot.three.math.Matrix3 -- 3x3 matrix, column-major, three.js style.
//
// Subset of three.js src/math/Matrix3.js (r187) kept for M1 completeness. The
// primary downstream use is `getNormalMatrix` (inverse-transpose of the upper 3x3)
// for lighting, which M2 needs; the class is stubbed in now so the import surface
// is stable. Column-major storage matches Matrix4.
package asaot.three.math
{
    import asaot.three.math.Matrix4;

    public class Matrix3
    {
        public var elements:Vector.<Number>;

        public function Matrix3(
            n11:Number = 1, n12:Number = 0, n13:Number = 0,
            n21:Number = 0, n22:Number = 1, n23:Number = 0,
            n31:Number = 0, n32:Number = 0, n33:Number = 1)
        {
            this.elements = new Vector.<Number>(9);
            this.set(n11, n12, n13, n21, n22, n23, n31, n32, n33);
        }

        public function set(
            n11:Number, n12:Number, n13:Number,
            n21:Number, n22:Number, n23:Number,
            n31:Number, n32:Number, n33:Number):Matrix3
        {
            var te:Vector.<Number> = this.elements;
            te[0] = n11; te[3] = n12; te[6] = n13;
            te[1] = n21; te[4] = n22; te[7] = n23;
            te[2] = n31; te[5] = n32; te[8] = n33;
            return this;
        }

        public function identity():Matrix3
        {
            return this.set(
                1, 0, 0,
                0, 1, 0,
                0, 0, 1);
        }

        public function clone():Matrix3
        {
            var te:Vector.<Number> = this.elements;
            return new Matrix3(
                te[0], te[3], te[6],
                te[1], te[4], te[7],
                te[2], te[5], te[8]);
        }

        public function copy(m:Matrix3):Matrix3
        {
            var te:Vector.<Number> = this.elements;
            var me:Vector.<Number> = m.elements;
            for (var i:int = 0; i < 9; i++) te[i] = me[i];
            return this;
        }

        // Copy the upper 3x3 of a Matrix4.
        public function setFromMatrix4(m:Matrix4):Matrix3
        {
            var me:Vector.<Number> = m.elements;
            return this.set(
                me[0], me[4], me[8],
                me[1], me[5], me[9],
                me[2], me[6], me[10]);
        }

        // M18: the uv transform three.js uses for every map
        // (Matrix3.js:394 setUvTransform, called from Texture.updateMatrix).
        //
        //   uv' = T(offset) * T(center) * R(rotation) * S(repeat) * T(-center) * uv
        //
        // which expands to the affine 2x3 below. Column-major `elements` like the
        // rest of this class, so element[3] is m01 (row 0, column 1) -- the
        // formula is copied verbatim from r187 rather than re-derived, because a
        // sign slip here rotates the texture the wrong way and nothing else
        // would catch it.
        public function setUvTransform(tx:Number, ty:Number, sx:Number, sy:Number,
                                      rotation:Number, cx:Number, cy:Number):Matrix3
        {
            var c:Number = Math.cos(rotation);
            var s:Number = Math.sin(rotation);

            return this.set(
                sx * c, sx * s, -sx * (c * cx + s * cy) + cx + tx,
                -sy * s, sy * c, -sy * (-s * cx + c * cy) + cy + ty,
                0, 0, 1);
        }

        public function multiply(m:Matrix3):Matrix3
        {
            return this.multiplyMatrices(this, m);
        }

        // this = a * b (a and b untouched); no allocation.
        public function multiplyMatrices(a:Matrix3, b:Matrix3):Matrix3
        {
            var ae:Vector.<Number> = a.elements;
            var be:Vector.<Number> = b.elements;
            var te:Vector.<Number> = this.elements;

            var a11:Number = ae[0], a12:Number = ae[3], a13:Number = ae[6];
            var a21:Number = ae[1], a22:Number = ae[4], a23:Number = ae[7];
            var a31:Number = ae[2], a32:Number = ae[5], a33:Number = ae[8];

            var b11:Number = be[0], b12:Number = be[3], b13:Number = be[6];
            var b21:Number = be[1], b22:Number = be[4], b23:Number = be[7];
            var b31:Number = be[2], b32:Number = be[5], b33:Number = be[8];

            te[0] = a11 * b11 + a12 * b21 + a13 * b31;
            te[3] = a11 * b12 + a12 * b22 + a13 * b32;
            te[6] = a11 * b13 + a12 * b23 + a13 * b33;

            te[1] = a21 * b11 + a22 * b21 + a23 * b31;
            te[4] = a21 * b12 + a22 * b22 + a23 * b32;
            te[7] = a21 * b13 + a22 * b23 + a23 * b33;

            te[2] = a31 * b11 + a32 * b21 + a33 * b31;
            te[5] = a31 * b12 + a32 * b22 + a33 * b32;
            te[8] = a31 * b13 + a32 * b23 + a33 * b33;
            return this;
        }

        public function determinant():Number
        {
            var te:Vector.<Number> = this.elements;
            var a:Number = te[0], b:Number = te[1], c:Number = te[2];
            var d:Number = te[3], e:Number = te[4], f:Number = te[5];
            var g:Number = te[6], h:Number = te[7], i:Number = te[8];
            return a * e * i - a * f * h - b * d * i + b * f * g + c * d * h - c * e * g;
        }

        public function transpose():Matrix3
        {
            var te:Vector.<Number> = this.elements;
            var tmp:Number;
            tmp = te[1]; te[1] = te[3]; te[3] = tmp;
            tmp = te[2]; te[2] = te[6]; te[6] = tmp;
            tmp = te[5]; te[5] = te[7]; te[7] = tmp;
            return this;
        }

        public function invert():Matrix3
        {
            var te:Vector.<Number> = this.elements;
            var n11:Number = te[0], n21:Number = te[1], n31:Number = te[2];
            var n12:Number = te[3], n22:Number = te[4], n32:Number = te[5];
            var n13:Number = te[6], n23:Number = te[7], n33:Number = te[8];

            var t11:Number = n33 * n22 - n32 * n23;
            var t12:Number = n32 * n13 - n33 * n12;
            var t13:Number = n23 * n12 - n22 * n13;

            var det:Number = n11 * t11 + n21 * t12 + n31 * t13;
            if (det == 0) return this.set(0, 0, 0, 0, 0, 0, 0, 0, 0);

            var detInv:Number = 1 / det;
            te[0] = t11 * detInv;
            te[1] = (n31 * n23 - n33 * n21) * detInv;
            te[2] = (n32 * n21 - n31 * n22) * detInv;
            te[3] = t12 * detInv;
            te[4] = (n33 * n11 - n31 * n13) * detInv;
            te[5] = (n31 * n12 - n32 * n11) * detInv;
            te[6] = t13 * detInv;
            te[7] = (n21 * n13 - n23 * n11) * detInv;
            te[8] = (n22 * n11 - n21 * n12) * detInv;
            return this;
        }

        // Normal matrix: inverse-transpose of the upper 3x3 of a Matrix4.
        public function getNormalMatrix(matrix4:Matrix4):Matrix3
        {
            return this.setFromMatrix4(matrix4).invert().transpose();
        }

        public function equals(m:Matrix3):Boolean
        {
            var te:Vector.<Number> = this.elements;
            var me:Vector.<Number> = m.elements;
            for (var i:int = 0; i < 9; i++)
            {
                if (te[i] != me[i]) return false;
            }
            return true;
        }
    }
}
