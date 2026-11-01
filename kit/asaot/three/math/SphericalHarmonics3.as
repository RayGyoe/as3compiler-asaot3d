// asaot.three.math.SphericalHarmonics3 -- order-2 (9 coefficient) real SH.
//
// Borrows src/math/SphericalHarmonics3.js (r187) verbatim in behaviour:
// `coefficients` is nine Vector3s holding the PROJECTED luminance integral
// c_lm = integral L(w) Y_lm(w) dw, which is what LightProbeGenerator produces
// and what `getIrradianceAt` consumes. The basis ORDER is three.js's, not the
// textbook's:
//
//   i=1 -> y, i=2 -> z, i=3 -> x        (l=1)
//   i=4 -> xy, i=5 -> yz, i=6 -> 3z^2-1, i=7 -> xz, i=8 -> x^2-y^2   (l=2)
//
// Getting that order wrong is silent: the result is still "smooth directional
// light", just rotated. The probe pins it by evaluating axes one at a time.
//
// `getAt` evaluates the RADIANCE reconstruction (basis * c_lm), `getIrradianceAt`
// the IRRADIANCE one (basis * c_lm * A_l, A_0 = pi, A_1 = 2pi/3, A_2 = pi/4 --
// Ramamoorthi & Hanrahan's cosine-lobe factors). Only the second is a lighting
// term; the first is what a probe would show to an eye.
package asaot.three.math
{
    public class SphericalHarmonics3
    {
        // Band constants (r187 SphericalHarmonics3.js:8-24), folded into the
        // radiance/irradiance forms below so the evaluation is a plain sum.
        public static const C0:Number = 0.282095;
        public static const C1:Number = 0.488603;
        public static const C2_XY:Number = 1.092548;
        public static const C2_Z2:Number = 0.315392;
        public static const C2_XY2:Number = 0.546274;

        public var coefficients:Vector.<Vector3>;

        // The real-SH basis value for direction (x,y,z), in the SAME order and
        // with the SAME constants `getAt` multiplies the coefficients by. Public
        // because the generator projects with it: projection and reconstruction
        // sharing one function is what makes them exact inverses.
        public static function basis(i:int, x:Number, y:Number, z:Number):Number
        {
            switch (i)
            {
                case 0: return SphericalHarmonics3.C0;
                case 1: return SphericalHarmonics3.C1 * y;
                case 2: return SphericalHarmonics3.C1 * z;
                case 3: return SphericalHarmonics3.C1 * x;
                case 4: return SphericalHarmonics3.C2_XY * (x * y);
                case 5: return SphericalHarmonics3.C2_XY * (y * z);
                case 6: return SphericalHarmonics3.C2_Z2 * (3.0 * z * z - 1.0);
                case 7: return SphericalHarmonics3.C2_XY * (x * z);
                case 8: return SphericalHarmonics3.C2_XY2 * (x * x - y * y);
            }
            throw new Error("SphericalHarmonics3.basis: index " + i + " is outside 0..8");
        }

        public function SphericalHarmonics3()
        {
            var i:int;
            this.coefficients = new Vector.<Vector3>(9, true);
            for (i = 0; i < 9; i++) this.coefficients[i] = new Vector3();
        }

        public function set(c0:Vector3, c1:Vector3, c2:Vector3, c3:Vector3, c4:Vector3,
                            c5:Vector3, c6:Vector3, c7:Vector3, c8:Vector3):SphericalHarmonics3
        {
            this.coefficients[0].copy(c0);
            this.coefficients[1].copy(c1);
            this.coefficients[2].copy(c2);
            this.coefficients[3].copy(c3);
            this.coefficients[4].copy(c4);
            this.coefficients[5].copy(c5);
            this.coefficients[6].copy(c6);
            this.coefficients[7].copy(c7);
            this.coefficients[8].copy(c8);
            return this;
        }

        public function zero():SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++) this.coefficients[i].set(0, 0, 0);
            return this;
        }

        // Radiance reconstruction. Equal to what an unfiltered probe would see
        // looking along `normal`.
        public function getAt(normal:Vector3, target:Vector3):Vector3
        {
            var x:Number = normal.x;
            var y:Number = normal.y;
            var z:Number = normal.z;
            var coeff:Vector.<Vector3> = this.coefficients;

            target.copy(coeff[0]).multiplyScalar(SphericalHarmonics3.C0);
            target.addScaledVector(coeff[1], SphericalHarmonics3.C1 * y);
            target.addScaledVector(coeff[2], SphericalHarmonics3.C1 * z);
            target.addScaledVector(coeff[3], SphericalHarmonics3.C1 * x);
            target.addScaledVector(coeff[4], SphericalHarmonics3.C2_XY * (x * y));
            target.addScaledVector(coeff[5], SphericalHarmonics3.C2_XY * (y * z));
            target.addScaledVector(coeff[6], SphericalHarmonics3.C2_Z2 * (3.0 * z * z - 1.0));
            target.addScaledVector(coeff[7], SphericalHarmonics3.C2_XY * (x * z));
            target.addScaledVector(coeff[8], SphericalHarmonics3.C2_XY2 * (x * x - y * y));
            return target;
        }

        // Irradiance for a surface whose normal is `normal`. The numeric factors
        // are r187's, and they are NOT arbitrary: 2*0.511664 = (2pi/3)*0.488603
        // and 0.743125/0.247708 come from (pi/4)*0.315392*3 and *(1).
        public function getIrradianceAt(normal:Vector3, target:Vector3):Vector3
        {
            var x:Number = normal.x;
            var y:Number = normal.y;
            var z:Number = normal.z;
            var coeff:Vector.<Vector3> = this.coefficients;

            target.copy(coeff[0]).multiplyScalar(0.886227);        // pi * 0.282095
            target.addScaledVector(coeff[1], 2.0 * 0.511664 * y);  // (2pi/3) * 0.488603
            target.addScaledVector(coeff[2], 2.0 * 0.511664 * z);
            target.addScaledVector(coeff[3], 2.0 * 0.511664 * x);
            target.addScaledVector(coeff[4], 2.0 * 0.429043 * x * y); // (pi/4) * 1.092548
            target.addScaledVector(coeff[5], 2.0 * 0.429043 * y * z);
            target.addScaledVector(coeff[6], 0.743125 * z * z - 0.247708);
            target.addScaledVector(coeff[7], 2.0 * 0.429043 * x * z);
            target.addScaledVector(coeff[8], 0.429043 * (x * x - y * y));
            return target;
        }

        public function add(sh:SphericalHarmonics3):SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++) this.coefficients[i].add(sh.coefficients[i]);
            return this;
        }

        public function addScaledSH(sh:SphericalHarmonics3, s:Number):SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++) this.coefficients[i].addScaledVector(sh.coefficients[i], s);
            return this;
        }

        public function scale(s:Number):SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++) this.coefficients[i].multiplyScalar(s);
            return this;
        }

        public function lerp(sh:SphericalHarmonics3, alpha:Number):SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++)
            {
                var c:Vector3 = this.coefficients[i];
                c.x += (sh.coefficients[i].x - c.x) * alpha;
                c.y += (sh.coefficients[i].y - c.y) * alpha;
                c.z += (sh.coefficients[i].z - c.z) * alpha;
            }
            return this;
        }

        public function equals(sh:SphericalHarmonics3):Boolean
        {
            var i:int;
            for (i = 0; i < 9; i++)
            {
                if (!this.coefficients[i].equals(sh.coefficients[i])) return false;
            }
            return true;
        }

        public function copy(sh:SphericalHarmonics3):SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++) this.coefficients[i].copy(sh.coefficients[i]);
            return this;
        }

        public function clone():SphericalHarmonics3
        {
            return new SphericalHarmonics3().copy(this);
        }

        public function fromArray(array:Vector.<Number>, offset:int = 0):SphericalHarmonics3
        {
            var i:int;
            for (i = 0; i < 9; i++)
            {
                this.coefficients[i].set(array[offset + i * 3],
                                         array[offset + i * 3 + 1],
                                         array[offset + i * 3 + 2]);
            }
            return this;
        }

        public function toArray(array:Vector.<Number>, offset:int = 0):Vector.<Number>
        {
            var i:int;
            for (i = 0; i < 9; i++)
            {
                array[offset + i * 3] = this.coefficients[i].x;
                array[offset + i * 3 + 1] = this.coefficients[i].y;
                array[offset + i * 3 + 2] = this.coefficients[i].z;
            }
            return array;
        }
    }
}