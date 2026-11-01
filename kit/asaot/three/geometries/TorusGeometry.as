// asaot.three.geometries.TorusGeometry -- donut, revolved about the Z axis.
//
// Borrows src/geometries/TorusGeometry.js (r187): a (radialSegments+1) x
// (tubularSegments+1) grid; each vertex's normal is the direction from the
// tube's centre circle to the vertex. `arc` trims the donut into a C shape while
// `thetaStart`/`thetaLength` rotate/trim the tube cross-section.
//
// NOTE the torus lies in the XY plane with its hole along Z (three.js r187 rest
//ructured the parametric form to exactly this), NOT the older XYZ-swapped
// layout -- so a TorusGeometry dropped into a scene faces the +Z camera by
// default.
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.Vector3;

    public class TorusGeometry extends BufferGeometry
    {
        public function TorusGeometry(radius:Number = 1, tube:Number = 0.4,
                                      radialSegments:int = 12, tubularSegments:int = 48,
                                      arc:Number = Math.PI * 2,
                                      thetaStart:Number = 0, thetaLength:Number = Math.PI * 2)
        {
            super();

            radialSegments = Math.floor(radialSegments);
            tubularSegments = Math.floor(tubularSegments);

            var indices:Vector.<Number> = new Vector.<Number>();
            var vertices:Vector.<Number> = new Vector.<Number>();
            var normals:Vector.<Number> = new Vector.<Number>();
            var uvs:Vector.<Number> = new Vector.<Number>();

            var center:Vector3 = new Vector3();
            var vertex:Vector3 = new Vector3();
            var normal:Vector3 = new Vector3();

            var j:int = 0;
            while (j <= radialSegments)
            {
                var v:Number = thetaStart + (j / radialSegments) * thetaLength;
                var i:int = 0;
                while (i <= tubularSegments)
                {
                    var u:Number = i / tubularSegments * arc;

                    vertex.x = (radius + tube * Math.cos(v)) * Math.cos(u);
                    vertex.y = (radius + tube * Math.cos(v)) * Math.sin(u);
                    vertex.z = tube * Math.sin(v);
                    vertices.push(vertex.x, vertex.y, vertex.z);

                    center.x = radius * Math.cos(u);
                    center.y = radius * Math.sin(u);
                    normal.subVectors(vertex, center).normalize();
                    normals.push(normal.x, normal.y, normal.z);

                    uvs.push(i / tubularSegments, j / radialSegments);
                    i++;
                }
                j++;
            }

            j = 1;
            while (j <= radialSegments)
            {
                var i2:int = 1;
                while (i2 <= tubularSegments)
                {
                    var a:int = (tubularSegments + 1) * j + i2 - 1;
                    var b:int = (tubularSegments + 1) * (j - 1) + i2 - 1;
                    var c:int = (tubularSegments + 1) * (j - 1) + i2;
                    var d:int = (tubularSegments + 1) * j + i2;

                    indices.push(a, b, d);
                    indices.push(b, c, d);
                    i2++;
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