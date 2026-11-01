// asaot.three.geometries.PlaneGeometry -- flat quad attribute factory, three.js style.
//
// Borrows the topology of three.js src/geometries/PlaneGeometry.js (r187): an X/Y
// grid of vertices with +Z normals, two triangles per cell, no material groups.
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;

    public class PlaneGeometry extends BufferGeometry
    {
        public function PlaneGeometry(width:Number = 1, height:Number = 1,
                                      widthSegments:int = 1, heightSegments:int = 1)
        {
            super();

            var widthHalf:Number = width / 2;
            var heightHalf:Number = height / 2;
            var gridX:int = Math.floor(widthSegments);
            var gridY:int = Math.floor(heightSegments);
            var gridX1:int = gridX + 1;
            var gridY1:int = gridY + 1;
            var segmentWidth:Number = width / gridX;
            var segmentHeight:Number = height / gridY;

            var indices:Vector.<Number> = new Vector.<Number>();
            var vertices:Vector.<Number> = new Vector.<Number>();
            var normals:Vector.<Number> = new Vector.<Number>();
            var uvs:Vector.<Number> = new Vector.<Number>();

            var iy:int = 0;
            while (iy < gridY1)
            {
                var y:Number = iy * segmentHeight - heightHalf;
                var ix:int = 0;
                while (ix < gridX1)
                {
                    var x:Number = ix * segmentWidth - widthHalf;

                    vertices.push(x, -y, 0);
                    normals.push(0, 0, 1);
                    uvs.push(ix / gridX);
                    uvs.push(1 - (iy / gridY));

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
                    var a:int = ix2 + gridX1 * iy;
                    var b:int = ix2 + gridX1 * (iy + 1);
                    var c:int = (ix2 + 1) + gridX1 * (iy + 1);
                    var d:int = (ix2 + 1) + gridX1 * iy;

                    indices.push(a, b, d);
                    indices.push(b, c, d);

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
