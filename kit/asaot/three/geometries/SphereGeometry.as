// asaot.three.geometries.SphereGeometry -- UV-sphere attribute factory, three.js style.
//
// Borrows the topology of three.js src/geometries/SphereGeometry.js (r187): a
// latitude/longitude grid with pole UV offsets, skipping the degenerate triangles
// at the poles. DIVERGENCES:
//   D-grid   the `grid` of per-row vertex indices is a JS array of arrays; AS3 uses
//            a flat Vector.<Vector.<Number>> (row -> vertex index).
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.Vector3;

    public class SphereGeometry extends BufferGeometry
    {
        public function SphereGeometry(radius:Number = 1, widthSegments:int = 32, heightSegments:int = 16,
                                       phiStart:Number = 0, phiLength:Number = Math.PI * 2,
                                       thetaStart:Number = 0, thetaLength:Number = Math.PI)
        {
            super();

            widthSegments = Math.max(3, Math.floor(widthSegments));
            heightSegments = Math.max(2, Math.floor(heightSegments));

            var thetaEnd:Number = Math.min(thetaStart + thetaLength, Math.PI);

            var index:int = 0;
            var grid:Vector.<Vector.<Number>> = new Vector.<Vector.<Number>>();

            var vertex:Vector3 = new Vector3();
            var normal:Vector3 = new Vector3();

            var indices:Vector.<Number> = new Vector.<Number>();
            var vertices:Vector.<Number> = new Vector.<Number>();
            var normals:Vector.<Number> = new Vector.<Number>();
            var uvs:Vector.<Number> = new Vector.<Number>();

            var iy:int = 0;
            while (iy <= heightSegments)
            {
                var verticesRow:Vector.<Number> = new Vector.<Number>();

                var v:Number = iy / heightSegments;
                var theta:Number = thetaStart + v * thetaLength;

                var y:Number = radius * Math.cos(theta);
                var ringRadius:Number = Math.sqrt(radius * radius - y * y);

                var uOffset:Number = 0;
                if (iy == 0 && thetaStart == 0)
                {
                    uOffset = 0.5 / widthSegments;
                }
                else if (iy == heightSegments && thetaEnd == Math.PI)
                {
                    uOffset = -0.5 / widthSegments;
                }

                var ix:int = 0;
                while (ix <= widthSegments)
                {
                    var u:Number = ix / widthSegments;
                    var phi:Number = phiStart + u * phiLength;

                    vertex.x = -ringRadius * Math.cos(phi);
                    vertex.y = y;
                    vertex.z = ringRadius * Math.sin(phi);
                    vertices.push(vertex.x, vertex.y, vertex.z);

                    normal.copy(vertex).normalize();
                    normals.push(normal.x, normal.y, normal.z);

                    uvs.push(u + uOffset, 1 - v);

                    verticesRow.push(index);
                    index++;
                    ix++;
                }

                grid.push(verticesRow);
                iy++;
            }

            iy = 0;
            while (iy < heightSegments)
            {
                var ix2:int = 0;
                while (ix2 < widthSegments)
                {
                    var row0:Vector.<Number> = grid[iy];
                    var row1:Vector.<Number> = grid[iy + 1];

                    var a:int = row0[ix2 + 1];
                    var b:int = row0[ix2];
                    var c:int = row1[ix2];
                    var d:int = row1[ix2 + 1];

                    if (iy != 0 || thetaStart > 0) indices.push(a, b, d);
                    if (iy != heightSegments - 1 || thetaEnd < Math.PI) indices.push(b, c, d);

                    ix2++;
                }
                iy++;
            }

            this.setIndex(new BufferAttribute(indices, 1));
            this.setAttribute("position", new BufferAttribute(vertices, 3));
            this.setAttribute("normal", new BufferAttribute(normals, 3));
            this.setAttribute("uv", new BufferAttribute(uvs, 2));
        }
    }
}
