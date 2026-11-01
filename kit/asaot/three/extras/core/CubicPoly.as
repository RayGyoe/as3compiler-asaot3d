// asaot.three.extras.core.CubicPoly -- one axis of a cubic polynomial.
//
// Borrows the `CubicPoly` factory in src/extras/curves/CatmullRomCurve3.js
// (r187). three.js returns an object of closures over four captured
// coefficients; AS3 has no nested functions and no closures over mutable
// locals, so the four coefficients become fields and init/calc become methods
// (divergence D60, three-api-design.md §16).
//
// The two `init*` entry points differ only in how the tangent magnitudes
// (c1, c2) are derived:
//   initCatmullRom        -- uniform spacing, tangents scaled by `tension`
//   initNonuniformCatmullRom -- per-segment spacing (centripetal/chordal)
package asaot.three.extras.core
{
    public class CubicPoly
    {
        private var _c0:Number = 0;
        private var _c1:Number = 0;
        private var _c2:Number = 0;
        private var _c3:Number = 0;

        public function CubicPoly()
        {
        }

        // Hermite -> polynomial coefficients: given the two endpoints and the two
        // tangents, expand to c0 + c1 t + c2 t^2 + c3 t^3.
        private function init(x0:Number, x1:Number, t0:Number, t1:Number):void
        {
            this._c0 = x0;
            this._c1 = t0;
            this._c2 = -3 * x0 + 3 * x1 - 2 * t0 - t1;
            this._c3 = 2 * x0 - 2 * x1 + t0 + t1;
        }

        // Uniform Catmull-Rom: tangents are tension * (next - prev).
        public function initCatmullRom(x0:Number, x1:Number, x2:Number, x3:Number, tension:Number):void
        {
            this.init(x1, x2, tension * (x2 - x0), tension * (x3 - x1));
        }

        // Non-uniform (centripetal/chordal) Catmull-Rom: the tangent at x1 is a
        // weighted blend of the neighbouring secants, with dt0/dt1/dt2 the
        // spacing exponents normalizing each one.
        public function initNonuniformCatmullRom(x0:Number, x1:Number, x2:Number, x3:Number,
                                                 dt0:Number, dt1:Number, dt2:Number):void
        {
            var t1:Number = (x1 - x0) / dt0 - (x2 - x0) / (dt0 + dt1) + (x2 - x1) / dt1;
            var t2:Number = (x2 - x1) / dt1 - (x3 - x1) / (dt1 + dt2) + (x3 - x2) / dt2;

            t1 *= dt1;
            t2 *= dt1;

            this.init(x1, x2, t1, t2);
        }

        public function calc(t:Number):Number
        {
            var t2:Number = t * t;
            var t3:Number = t2 * t;
            return this._c0 + this._c1 * t + this._c2 * t2 + this._c3 * t3;
        }
    }
}