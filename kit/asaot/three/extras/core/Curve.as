// asaot.three.extras.core.Curve -- parametric curve base + arc-length + Frenet frames.
//
// Borrows src/extras/core/Curve.js (r187): `getPoint(t)` is the one abstract
// method; everything else (constant-speed `getPointAt` via an arc-length
// reparameterization table, `getTangentAt`, `getLength`, and
// `computeFrenetFrames`) is derived from it. M11 needs exactly this subset for
// TubeGeometry; the drawing helpers (drawPoints/Line) and the 2D/3D
// shape-extrusion paths are not ported.
//
// DIVERGENCES (three-api-design.md §16):
//   D58  `getPoint` throws (no `throw new Error` in three.js's sense: the AS3
//        port uses a plain Error so an unimplemented subclass fails loudly at
//        the first sample instead of returning a zero point).
//   D59  `computeFrenetFrames` returns a `FrenetFrames` value object rather than
//        a JS `{tangents, normals, binormals}` literal (D-object: AS3 object
//        initializers are not used anywhere in this engine).
package asaot.three.extras.core
{
    import asaot.three.math.MathUtils;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;

    public class Curve
    {
        // `Number.EPSILON` (three.js's twist guard) is not in this compiler's
        // number-constant surface, so it is spelled out: 2^-52.
        public static const EPSILON:Number = 2.220446049250313e-16;

        public var arcLengthDivisions:int = 200;
        public var cacheArcLengths:Vector.<Number>;
        public var needsUpdate:Boolean = false;

        // Scratch shared by computeFrenetFrames (three.js uses closure locals).
        private var _cfNormal:Vector3 = new Vector3();
        private var _cfVec:Vector3 = new Vector3();
        private var _cfQuat:Quaternion = new Quaternion();
        private var _cfMat:Matrix4 = new Matrix4();

        // Scratch for getTangent (three.js allocates two Vector3 per call).
        private var _tgA:Vector3 = new Vector3();
        private var _tgB:Vector3 = new Vector3();

        // three.js Curve.js:135 -- abstract.
        public function getPoint(t:Number, target:Vector3 = null):Vector3
        {
            throw new Error("asaot.three.Curve.getPoint(): subclasses must override getPoint()");
        }

        // ---- arc length (Curve.js:239) ----

        public function getLength():Number
        {
            var lengths:Vector.<Number> = this.getLengths();
            return lengths[lengths.length - 1];
        }

        // Sample the curve `divisions` times and accumulate chord lengths. The
        // table is cached until `needsUpdate` (Curve.js:250).
        public function getLengths(divisions:int = -1):Vector.<Number>
        {
            if (divisions < 0) divisions = this.arcLengthDivisions;

            if (this.cacheArcLengths != null
                && this.cacheArcLengths.length == divisions + 1
                && !this.needsUpdate)
            {
                return this.cacheArcLengths;
            }

            this.needsUpdate = false;

            var cache:Vector.<Number> = new Vector.<Number>();
            var current:Vector3 = new Vector3();
            var last:Vector3 = new Vector3();
            var sum:Number = 0;
            var p:int;

            this.getPoint(0, current);
            last.copy(current);
            cache.push(0);

            p = 1;
            while (p <= divisions)
            {
                this.getPoint(p / divisions, current);
                sum += current.distanceTo(last);
                cache.push(sum);
                last.copy(current);
                p++;
            }

            this.cacheArcLengths = cache;
            return cache;
        }

        public function updateArcLengths():void
        {
            this.needsUpdate = true;
            this.getLengths();
        }

        // Binary-search the arc-length table for the `u`-parameter whose arc
        // length matches (Curve.js:285). Returns the curve parameter t.
        public function getUtoTmapping(u:Number, distance:Number = NaN):Number
        {
            var arcLengths:Vector.<Number> = this.getLengths();
            var il:int = arcLengths.length;
            var i:int = 0;
            var targetArcLength:Number;

            // three.js: `if (distance)` -- 0 and null are both "not given".
            if (!isNaN(distance) && distance != 0) targetArcLength = distance;
            else targetArcLength = u * arcLengths[il - 1];

            var low:int = 0;
            var high:int = il - 1;
            var comparison:Number;

            while (low <= high)
            {
                i = Math.floor(low + (high - low) / 2);
                comparison = arcLengths[i] - targetArcLength;
                if (comparison < 0)
                {
                    low = i + 1;
                }
                else if (comparison > 0)
                {
                    high = i - 1;
                }
                else
                {
                    high = i;
                    break;
                }
            }

            i = high;
            if (arcLengths[i] == targetArcLength) return i / (il - 1);

            var lengthBefore:Number = arcLengths[i];
            var lengthAfter:Number = arcLengths[i + 1];
            var segmentLength:Number = lengthAfter - lengthBefore;
            var segmentFraction:Number = (targetArcLength - lengthBefore) / segmentLength;
            return (i + segmentFraction) / (il - 1);
        }

        // Curve.js:190 -- constant-speed sample (arc-length parameterized).
        public function getPointAt(u:Number, target:Vector3 = null):Vector3
        {
            var t:Number = this.getUtoTmapping(u);
            return this.getPoint(t, target);
        }

        // Curve.js:341 -- central difference over +/-1e-4 with clamping at the
        // ends, so a curve with a hard corner still yields a finite tangent.
        public function getTangent(t:Number, target:Vector3 = null):Vector3
        {
            var delta:Number = 0.0001;
            var t1:Number = t - delta;
            var t2:Number = t + delta;

            if (t1 < 0) t1 = 0;
            if (t2 > 1) t2 = 1;

            this.getPoint(t1, this._tgA);
            this.getPoint(t2, this._tgB);

            var tangent:Vector3 = (target != null) ? target : new Vector3();
            tangent.copy(this._tgB).sub(this._tgA).normalize();
            return tangent;
        }

        public function getTangentAt(u:Number, target:Vector3 = null):Vector3
        {
            var t:Number = this.getUtoTmapping(u);
            return this.getTangent(t, target);
        }

        // ---- Frenet frames (Curve.js:353) ----
        //
        // Parallel-transport frames: start with an arbitrary normal perpendicular
        // to the first tangent, then rotate each successive normal by the minimal
        // rotation between consecutive tangents. This avoids the 2nd-derivative
        // Frenet normal, which flips at inflection points.
        public function computeFrenetFrames(segments:int, closed:Boolean = false):FrenetFrames
        {
            var normal:Vector3 = this._cfNormal;
            var vec:Vector3 = this._cfVec;

            var tangents:Vector.<Vector3> = new Vector.<Vector3>();
            var normals:Vector.<Vector3> = new Vector.<Vector3>();
            var binormals:Vector.<Vector3> = new Vector.<Vector3>();

            var i:int = 0;
            while (i <= segments)
            {
                tangents.push(this.getTangentAt(i / segments, new Vector3()));
                i++;
            }

            normals.push(new Vector3());
            binormals.push(new Vector3());

            // Pick the axis least aligned with the first tangent so the initial
            // cross product is well-conditioned.
            var min:Number = Number.MAX_VALUE;
            var tx:Number = Math.abs(tangents[0].x);
            var ty:Number = Math.abs(tangents[0].y);
            var tz:Number = Math.abs(tangents[0].z);

            if (tx <= min) { min = tx; normal.set(1, 0, 0); }
            if (ty <= min) { min = ty; normal.set(0, 1, 0); }
            if (tz <= min) { normal.set(0, 0, 1); }

            vec.crossVectors(tangents[0], normal).normalize();
            normals[0].crossVectors(tangents[0], vec);
            binormals[0].crossVectors(tangents[0], normals[0]);

            i = 1;
            while (i <= segments)
            {
                normals[i] = normals[i - 1].clone();
                binormals[i] = binormals[i - 1].clone();

                vec.crossVectors(tangents[i - 1], tangents[i]);

                if (vec.length() > Curve.EPSILON)
                {
                    vec.normalize();

                    // clamp guards acos against |dot| slightly above 1
                    var theta:Number = Math.acos(MathUtils.clamp(tangents[i - 1].dot(tangents[i]), -1, 1));
                    this._cfQuat.setFromAxisAngle(vec, theta);
                    this._cfMat.makeRotationFromQuaternion(this._cfQuat);
                    normals[i].applyMatrix4(this._cfMat);
                }

                binormals[i].crossVectors(tangents[i], normals[i]);
                i++;
            }

            // For a closed curve the transported frame does not necessarily come
            // back to the start; distribute the residual twist evenly.
            if (closed)
            {
                var theta2:Number = Math.acos(MathUtils.clamp(normals[0].dot(normals[segments]), -1, 1));
                theta2 /= segments;

                if (tangents[0].dot(vec.crossVectors(normals[0], normals[segments])) > 0)
                {
                    theta2 = -theta2;
                }

                i = 1;
                while (i <= segments)
                {
                    this._cfQuat.setFromAxisAngle(tangents[i], theta2 * i);
                    this._cfMat.makeRotationFromQuaternion(this._cfQuat);
                    normals[i].applyMatrix4(this._cfMat);
                    binormals[i].crossVectors(tangents[i], normals[i]);
                    i++;
                }
            }

            return new FrenetFrames(tangents, normals, binormals);
        }
    }
}