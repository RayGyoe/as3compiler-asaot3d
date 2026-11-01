// asaot.three.geometries.TubeGeometry -- swept circle along a Curve.
//
// Borrows src/geometries/TubeGeometry.js (r187): the path is sampled at
// `tubularSegments` arc-length-parameterized points, each carrying a parallel
// transported frame (tangent/normal/binormal). A ring of `radialSegments+1`
// vertices is placed around each sample in the normal/binormal plane.
//
// DIVERGENCES (three-api-design.md §16):
//   D-fn  generateBufferData/generateSegment/generateIndices/generateUVs are JS
//         nested closures over `path`, `frames` and the buffers; they become
//         private methods over instance fields (same shape as CylinderGeometry).
//   D61   `tubularSegments` is clamped to >= 1. three.js divides by it without a
//         guard, so `new TubeGeometry(path, 0)` yields NaN vertices there; we
//         would rather produce a degenerate-but-finite geometry.
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.extras.core.Curve;
    import asaot.three.extras.core.FrenetFrames;
    import asaot.three.extras.curves.CatmullRomCurve3;
    import asaot.three.math.Vector3;

    public class TubeGeometry extends BufferGeometry
    {
        // Generator state (three.js closure locals).
        private var _vertices:Vector.<Number>;
        private var _normals:Vector.<Number>;
        private var _uvs:Vector.<Number>;
        private var _indices:Vector.<Number>;
        private var _frames:FrenetFrames;
        private var _radius:Number;
        private var _radialSegments:int;
        private var _tubularSegments:int;
        private var _closed:Boolean;
        private var _path:Curve;
        private var _point:Vector3 = new Vector3();

        public function TubeGeometry(path:Curve = null, tubularSegments:int = 64, radius:Number = 1,
                                     radialSegments:int = 8, closed:Boolean = false)
        {
            super();

            if (path == null)
            {
                // three.js's default: a quadratic Bezier arc, approximated here by
                // an equivalent three-point Catmull-Rom spline (the M11 port does
                // not carry the Bezier curve family).
                var pts:Vector.<Vector3> = new Vector.<Vector3>();
                pts.push(new Vector3(-1, -1, 0));
                pts.push(new Vector3(-1, 1, 0));
                pts.push(new Vector3(1, 1, 0));
                path = new CatmullRomCurve3(pts);
            }

            if (tubularSegments < 1) tubularSegments = 1;      // D61
            if (radialSegments < 1) radialSegments = 1;

            this._path = path;
            this._tubularSegments = tubularSegments;
            this._radialSegments = radialSegments;
            this._radius = radius;
            this._closed = closed;

            this._vertices = new Vector.<Number>();
            this._normals = new Vector.<Number>();
            this._uvs = new Vector.<Number>();
            this._indices = new Vector.<Number>();

            this._frames = path.computeFrenetFrames(tubularSegments, closed);

            this.generateBufferData();

            this.setIndex(new BufferAttribute(this._indices, 1));
            this.setAttribute("position", new BufferAttribute(this._vertices, 3));
            this.setAttribute("normal", new BufferAttribute(this._normals, 3));
            this.setAttribute("uv", new BufferAttribute(this._uvs, 2));

            this._path = null;
            this._frames = null;
            this._vertices = null;
            this._normals = null;
            this._uvs = null;
            this._indices = null;
        }

        private function generateBufferData():void
        {
            var i:int = 0;
            while (i < this._tubularSegments)
            {
                this.generateSegment(i);
                i++;
            }
            // The final (or, for a closed tube, the first) ring closes the sweep.
            this.generateSegment(this._closed ? 0 : this._tubularSegments);
            this.generateUVs();
            this.generateIndices();
        }

        private function generateSegment(i:int):void
        {
            this._path.getPointAt(i / this._tubularSegments, this._point);

            var N:Vector3 = this._frames.normals[i];
            var B:Vector3 = this._frames.binormals[i];

            var j:int = 0;
            while (j <= this._radialSegments)
            {
                var v:Number = j / this._radialSegments * Math.PI * 2;
                var sin:Number = Math.sin(v);
                var cos:Number = -Math.cos(v);

                // Ring direction in the (B, N) plane. cos is negated so the ring
                // winds the same way as the frame's handedness.
                var nx:Number = cos * N.x + sin * B.x;
                var ny:Number = cos * N.y + sin * B.y;
                var nz:Number = cos * N.z + sin * B.z;
                var len:Number = Math.sqrt(nx * nx + ny * ny + nz * nz);
                if (len > 0)
                {
                    nx /= len; ny /= len; nz /= len;
                }
                this._normals.push(nx, ny, nz);

                this._vertices.push(this._point.x + this._radius * nx,
                                    this._point.y + this._radius * ny,
                                    this._point.z + this._radius * nz);
                j++;
            }
        }

        private function generateIndices():void
        {
            var radialSegments:int = this._radialSegments;
            var j:int = 1;
            while (j <= this._tubularSegments)
            {
                var i:int = 1;
                while (i <= radialSegments)
                {
                    var a:int = (radialSegments + 1) * (j - 1) + (i - 1);
                    var b:int = (radialSegments + 1) * j + (i - 1);
                    var c:int = (radialSegments + 1) * j + i;
                    var d:int = (radialSegments + 1) * (j - 1) + i;

                    this._indices.push(a, b, d);
                    this._indices.push(b, c, d);
                    i++;
                }
                j++;
            }
        }

        private function generateUVs():void
        {
            var i:int = 0;
            while (i <= this._tubularSegments)
            {
                var j:int = 0;
                while (j <= this._radialSegments)
                {
                    this._uvs.push(i / this._tubularSegments, j / this._radialSegments);
                    j++;
                }
                i++;
            }
        }
    }
}