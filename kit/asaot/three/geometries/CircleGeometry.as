// asaot.three.geometries.CircleGeometry -- flat disc in the XY plane.
//
// Borrows src/geometries/CircleGeometry.js (r187): one centre vertex plus
// `segments+1` rim vertices, fanned into a triangle fan. The rim UVs are the
// position projected onto [-1,1] and remapped to [0,1] against the radius, so a
// texture maps as a disc.
//
// NOTE the AS3 port indexes the vertex buffer directly instead of three.js's
// `vertices[i]` absolute-offset read: three.js pushes (x,y,z) then reads
// `vertices[i]` / `vertices[i+1]` because it tracks a parallel offset `i`. Here
// the loop-local `vertex` already holds both components, so there is no reason to
// re-read the buffer.
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.Vector3;

    public class CircleGeometry extends BufferGeometry
    {
        public function CircleGeometry(radius:Number = 1, segments:int = 32,
                                       thetaStart:Number = 0, thetaLength:Number = Math.PI * 2)
        {
            super();

            segments = Math.max(3, segments);

            var indices:Vector.<Number> = new Vector.<Number>();
            var vertices:Vector.<Number> = new Vector.<Number>();
            var normals:Vector.<Number> = new Vector.<Number>();
            var uvs:Vector.<Number> = new Vector.<Number>();

            var vertex:Vector3 = new Vector3();

            // centre
            vertices.push(0, 0, 0);
            normals.push(0, 0, 1);
            uvs.push(0.5, 0.5);

            var s:int = 0;
            while (s <= segments)
            {
                var segment:Number = thetaStart + s / segments * thetaLength;

                vertex.x = radius * Math.cos(segment);
                vertex.y = radius * Math.sin(segment);
                vertices.push(vertex.x, vertex.y, vertex.z);
                normals.push(0, 0, 1);
                uvs.push((vertex.x / radius + 1) / 2, (vertex.y / radius + 1) / 2);
                s++;
            }

            var i:int = 1;
            while (i <= segments)
            {
                indices.push(i, i + 1, 0);
                i++;
            }

            this.setIndex(new BufferAttribute(indices, 1));
            this.setAttribute("position", new BufferAttribute(vertices, 3));
            this.setAttribute("normal", new BufferAttribute(normals, 3));
            this.setAttribute("uv", new BufferAttribute(uvs, 2));
        }
    }
}