// asaot.three.geometries.RingGeometry -- flat annulus in the XY plane.
//
// Borrows src/geometries/RingGeometry.js (r187): `phiSegments+1` concentric
// rings of `thetaSegments+1` vertices, stitched into quads. UVs are the position
// projected against the OUTER radius only, so inner and outer rings of a texture
// stay aligned.
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.Vector3;

    public class RingGeometry extends BufferGeometry
    {
        public function RingGeometry(innerRadius:Number = 0.5, outerRadius:Number = 1,
                                     thetaSegments:int = 32, phiSegments:int = 1,
                                     thetaStart:Number = 0, thetaLength:Number = Math.PI * 2)
        {
            super();

            thetaSegments = Math.max(3, thetaSegments);
            phiSegments = Math.max(1, phiSegments);

            var indices:Vector.<Number> = new Vector.<Number>();
            var vertices:Vector.<Number> = new Vector.<Number>();
            var normals:Vector.<Number> = new Vector.<Number>();
            var uvs:Vector.<Number> = new Vector.<Number>();

            var vertex:Vector3 = new Vector3();
            var radius:Number = innerRadius;
            var radiusStep:Number = (outerRadius - innerRadius) / phiSegments;

            var j:int = 0;
            while (j <= phiSegments)
            {
                var i:int = 0;
                while (i <= thetaSegments)
                {
                    var segment:Number = thetaStart + i / thetaSegments * thetaLength;

                    vertex.x = radius * Math.cos(segment);
                    vertex.y = radius * Math.sin(segment);
                    vertices.push(vertex.x, vertex.y, vertex.z);
                    normals.push(0, 0, 1);
                    uvs.push((vertex.x / outerRadius + 1) / 2, (vertex.y / outerRadius + 1) / 2);
                    i++;
                }
                radius += radiusStep;
                j++;
            }

            j = 0;
            while (j < phiSegments)
            {
                var thetaSegmentLevel:int = j * (thetaSegments + 1);
                i = 0;
                while (i < thetaSegments)
                {
                    var segment2:int = i + thetaSegmentLevel;
                    var a:int = segment2;
                    var b:int = segment2 + thetaSegments + 1;
                    var c:int = segment2 + thetaSegments + 2;
                    var d:int = segment2 + 1;

                    indices.push(a, b, d);
                    indices.push(b, c, d);
                    i++;
                }
                j++;
            }

            this.setIndex(new BufferAttribute(indices, 1));
            this.setAttribute("position", new BufferAttribute(vertices, 3));
            this.setAttribute("normal", new BufferAttribute(normals, 3));
            this.setAttribute("uv", new BufferAttribute(uvs, 2));
        }
    }
}