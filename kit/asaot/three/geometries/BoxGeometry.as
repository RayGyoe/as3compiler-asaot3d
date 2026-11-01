// asaot.three.geometries.BoxGeometry -- unit-cuboid attribute factory, three.js style.
//
// Borrows the topology generation of three.js src/geometries/BoxGeometry.js (r187):
// six buildPlane() passes, each writing position/normal/uv + two-triangle indices and
// a material group. DIVERGENCES (three-api-design.md):
//   D-fn     buildPlane is a JS nested closure; AS3 has no nested functions, so it is
//            a private method with the shared counters (_numberOfVertices/_groupStart)
//            and buffers promoted to instance fields, cleared in the constructor.
//   D-index  vector[u] string-indexing -> Vector3.setComponent(int).
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.Vector3;

    public class BoxGeometry extends BufferGeometry
    {
        // Shared buildPlane state (three.js keeps these as closure locals).
        private var _indices:Vector.<Number>;
        private var _vertices:Vector.<Number>;
        private var _normals:Vector.<Number>;
        private var _uvs:Vector.<Number>;
        private var _numberOfVertices:int;
        private var _groupStart:int;

        public function BoxGeometry(width:Number = 1, height:Number = 1, depth:Number = 1,
                                    widthSegments:int = 1, heightSegments:int = 1, depthSegments:int = 1)
        {
            super();

            this._indices = new Vector.<Number>();
            this._vertices = new Vector.<Number>();
            this._normals = new Vector.<Number>();
            this._uvs = new Vector.<Number>();
            this._numberOfVertices = 0;
            this._groupStart = 0;

            widthSegments = Math.floor(widthSegments);
            heightSegments = Math.floor(heightSegments);
            depthSegments = Math.floor(depthSegments);

            // Six faces, matching three.js BoxGeometry.js:70-75 (u,v,w in x/y/z index form).
            // px / nx
            this.buildPlane(2, 1, 0, -1, -1, depth, height, width, depthSegments, heightSegments, 0);
            this.buildPlane(2, 1, 0, 1, -1, depth, height, -width, depthSegments, heightSegments, 1);
            // py / ny
            this.buildPlane(0, 2, 1, 1, 1, width, depth, height, widthSegments, depthSegments, 2);
            this.buildPlane(0, 2, 1, 1, -1, width, depth, -height, widthSegments, depthSegments, 3);
            // pz / nz
            this.buildPlane(0, 1, 2, 1, -1, width, height, depth, widthSegments, heightSegments, 4);
            this.buildPlane(0, 1, 2, -1, -1, width, height, -depth, widthSegments, heightSegments, 5);

            this.setIndex(new BufferAttribute(this._indices, 1));
            this.setAttribute("position", new BufferAttribute(this._vertices, 3));
            this.setAttribute("normal", new BufferAttribute(this._normals, 3));
            this.setAttribute("uv", new BufferAttribute(this._uvs, 2));

            // Release the scratch buffers (they were copied by reference into the
            // BufferAttributes above; dropping these local refs is safe).
            this._indices = null;
            this._vertices = null;
            this._normals = null;
            this._uvs = null;
        }

        // Port of three.js BoxGeometry.buildPlane (BoxGeometry.js:90-160), with u/v/w
        // as component indices (0=x,1=y,2=z) instead of string keys.
        private function buildPlane(u:int, v:int, w:int, udir:Number, vdir:Number,
                                    width:Number, height:Number, depth:Number,
                                    gridX:int, gridY:int, materialIndex:int):void
        {
            var segmentWidth:Number = width / gridX;
            var segmentHeight:Number = height / gridY;
            var widthHalf:Number = width / 2;
            var heightHalf:Number = height / 2;
            var depthHalf:Number = depth / 2;
            var gridX1:int = gridX + 1;
            var gridY1:int = gridY + 1;
            var vertexCounter:int = 0;
            var groupCount:int = 0;
            var vector:Vector3 = new Vector3();

            var iy:int = 0;
            while (iy < gridY1)
            {
                var y:Number = iy * segmentHeight - heightHalf;
                var ix:int = 0;
                while (ix < gridX1)
                {
                    var x:Number = ix * segmentWidth - widthHalf;

                    vector.setComponent(u, x * udir);
                    vector.setComponent(v, y * vdir);
                    vector.setComponent(w, depthHalf);
                    this._vertices.push(vector.x, vector.y, vector.z);

                    vector.setComponent(u, 0);
                    vector.setComponent(v, 0);
                    vector.setComponent(w, depth > 0 ? 1 : -1);
                    this._normals.push(vector.x, vector.y, vector.z);

                    this._uvs.push(ix / gridX);
                    this._uvs.push(1 - (iy / gridY));

                    vertexCounter++;
                    ix++;
                }
                iy++;
            }

            iy = 0;
            while (iy < gridY)
            {
                var ix2:int = 0;
                while (ix2 < gridX)
                {
                    var a:int = this._numberOfVertices + ix2 + gridX1 * iy;
                    var b:int = this._numberOfVertices + ix2 + gridX1 * (iy + 1);
                    var c:int = this._numberOfVertices + (ix2 + 1) + gridX1 * (iy + 1);
                    var d:int = this._numberOfVertices + (ix2 + 1) + gridX1 * iy;

                    this._indices.push(a, b, d);
                    this._indices.push(b, c, d);

                    groupCount += 6;
                    ix2++;
                }
                iy++;
            }

            this.addGroup(this._groupStart, groupCount, materialIndex);
            this._groupStart += groupCount;
            this._numberOfVertices += vertexCounter;
        }
    }
}
