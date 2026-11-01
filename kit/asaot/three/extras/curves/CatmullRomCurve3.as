// asaot.three.extras.curves.CatmullRomCurve3 -- centripetal/chordal/uniform Catmull-Rom.
//
// Borrows src/extras/curves/CatmullRomCurve3.js (r187): four-point cubic
// interpolation with three parameterizations --
//   'centripetal' (default, alpha=0.25) -- no cusps or self-intersections;
//   'chordal'     (alpha=0.5)            -- uniform-ish, can overshoot;
//   'catmullrom'  (uniform)              -- classic, tension-driven.
// Endpoints are handled by reflecting the last interior point outward when the
// curve is open.
//
// DIVERGENCES (three-api-design.md §16):
//   D60  `CubicPoly` is a JS factory returning a closure object. AS3 has no
//        nested functions, so the three polynomials become `CubicPoly` instances
//        (one per axis) held as fields, with the same init/calc split.
package asaot.three.extras.curves
{
    import asaot.three.extras.core.CubicPoly;
    import asaot.three.extras.core.Curve;
    import asaot.three.math.Vector3;

    public class CatmullRomCurve3 extends Curve
    {
        public var points:Vector.<Vector3>;
        public var closed:Boolean;
        public var curveType:String;
        public var tension:Number;

        private var _px:CubicPoly = new CubicPoly();
        private var _py:CubicPoly = new CubicPoly();
        private var _pz:CubicPoly = new CubicPoly();

        // Endpoint reflections (three.js module-scope `tmp`/`tmp2`).
        private var _tmp:Vector3 = new Vector3();
        private var _tmp2:Vector3 = new Vector3();

        public function CatmullRomCurve3(points:Vector.<Vector3> = null, closed:Boolean = false,
                                         curveType:String = "centripetal", tension:Number = 0.5)
        {
            super();
            this.points = (points != null) ? points : new Vector.<Vector3>();
            this.closed = closed;
            this.curveType = curveType;
            this.tension = tension;
        }

        override public function getPoint(t:Number, target:Vector3 = null):Vector3
        {
            var point:Vector3 = (target != null) ? target : new Vector3();
            var points:Vector.<Vector3> = this.points;
            var l:int = points.length;
            if (l == 0) return point.set(0, 0, 0);

            var p:Number = (l - (this.closed ? 0 : 1)) * t;
            var intPoint:int = Math.floor(p);
            var weight:Number = p - intPoint;

            if (this.closed)
            {
                // wrap negative seam indices back into the ring
                if (intPoint <= 0) intPoint += (Math.floor(Math.abs(intPoint) / l) + 1) * l;
            }
            else if (weight == 0 && intPoint == l - 1)
            {
                intPoint = l - 2;
                weight = 1;
            }

            var p0:Vector3;
            var p3:Vector3;

            if (this.closed || intPoint > 0)
            {
                p0 = points[(intPoint - 1) % l];
            }
            else
            {
                // reflect p1 about p0 to synthesize a phantom p0
                this._tmp2.subVectors(points[0], points[1]).add(points[0]);
                p0 = this._tmp2;
            }

            var p1:Vector3 = points[intPoint % l];
            var p2:Vector3 = points[(intPoint + 1) % l];

            if (this.closed || intPoint + 2 < l)
            {
                p3 = points[(intPoint + 2) % l];
            }
            else
            {
                this._tmp.subVectors(points[l - 1], points[l - 2]).add(points[l - 1]);
                p3 = this._tmp;
            }

            if (this.curveType == "centripetal" || this.curveType == "chordal")
            {
                var pow:Number = (this.curveType == "chordal") ? 0.5 : 0.25;

                var dt0:Number = Math.pow(p0.distanceToSquared(p1), pow);
                var dt1:Number = Math.pow(p1.distanceToSquared(p2), pow);
                var dt2:Number = Math.pow(p2.distanceToSquared(p3), pow);

                // Coincident control points would divide by zero; fall back to the
                // neighbours' spacing (matching three.js's 1e-4 guard).
                if (dt1 < 0.0001) dt1 = 1.0;
                if (dt0 < 0.0001) dt0 = dt1;
                if (dt2 < 0.0001) dt2 = dt1;

                this._px.initNonuniformCatmullRom(p0.x, p1.x, p2.x, p3.x, dt0, dt1, dt2);
                this._py.initNonuniformCatmullRom(p0.y, p1.y, p2.y, p3.y, dt0, dt1, dt2);
                this._pz.initNonuniformCatmullRom(p0.z, p1.z, p2.z, p3.z, dt0, dt1, dt2);
            }
            else if (this.curveType == "catmullrom")
            {
                this._px.initCatmullRom(p0.x, p1.x, p2.x, p3.x, this.tension);
                this._py.initCatmullRom(p0.y, p1.y, p2.y, p3.y, this.tension);
                this._pz.initCatmullRom(p0.z, p1.z, p2.z, p3.z, this.tension);
            }

            return point.set(this._px.calc(weight), this._py.calc(weight), this._pz.calc(weight));
        }
    }
}