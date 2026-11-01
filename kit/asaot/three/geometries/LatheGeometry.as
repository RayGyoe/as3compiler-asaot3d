// asaot.three.geometries.LatheGeometry -- surface of revolution around the Y axis.
//
// Borrows src/geometries/LatheGeometry.js (r187): a 2D polyline (`points`, as
// Vector2 where x is the radius and y the height) revolved `segments` times about
// Y. Vertex normals are computed from the polyline's segment directions, averaged
// at interior points, which is what makes a lathed vase look smooth instead of
// faceted.
//
// The three.js code has two details worth flagging, both mirrored here:
//   * `prevNormal` is copied BEFORE `normal.normalize()`, so the accumulation at
//     interior points adds an unnormalized neighbour. That is three.js's actual
//     behaviour (it is not a branch we are free to "fix" without changing every
//     lathed silhouette), so §16 records it as an inherited quirk.
//   * `normal.z` is always `dy * 0.0` == 0: the profile normal has no Z because
//     the profile itself is 2D.
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.MathUtils;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;

    public class LatheGeometry extends BufferGeometry
    {
        public function LatheGeometry(points:Vector.<Vector2> = null, segments:int = 12,
                                      phiStart:Number = 0, phiLength:Number = Math.PI * 2)
        {
            super();

            if (points == null)
            {
                points = new Vector.<Vector2>();
                points.push(new Vector2(0, -0.5));
                points.push(new Vector2(0.5, 0));
                points.push(new Vector2(0, 0.5));
            }

            segments = Math.floor(segments);
            phiLength = MathUtils.clamp(phiLength, 0, Math.PI * 2);

            var indices:Vector.<Number> = new Vector.<Number>();
            var vertices:Vector.<Number> = new Vector.<Number>();
            var uvs:Vector.<Number> = new Vector.<Number>();
            var initNormals:Vector.<Number> = new Vector.<Number>();
            var normals:Vector.<Number> = new Vector.<Number>();

            var inverseSegments:Number = 1.0 / segments;
            var vertex:Vector3 = new Vector3();
            var normal:Vector3 = new Vector3();
            var curNormal:Vector3 = new Vector3();
            var prevNormal:Vector3 = new Vector3();

            var dx:Number = 0;
            var dy:Number = 0;
            var j:int;
            var pointCount:int = points.length;

            // ---- profile normals ----
            j = 0;
            while (j <= pointCount - 1)
            {
                if (j == 0)
                {
                    // first point: unidirectional segment normal
                    dx = points[j + 1].x - points[j].x;
                    dy = points[j + 1].y - points[j].y;
                    normal.x = dy * 1.0;
                    normal.y = -dx;
                    normal.z = dy * 0.0;
                    prevNormal.copy(normal);
                    normal.normalize();
                    initNormals.push(normal.x, normal.y, normal.z);
                }
                else if (j == pointCount - 1)
                {
                    // last point: reuse the previous segment normal
                    prevNormal.normalize();
                    initNormals.push(prevNormal.x, prevNormal.y, prevNormal.z);
                }
                else
                {
                    // interior: average the neighbouring segment normals
                    dx = points[j + 1].x - points[j].x;
                    dy = points[j + 1].y - points[j].y;
                    normal.x = dy * 1.0;
                    normal.y = -dx;
                    normal.z = dy * 0.0;
                    curNormal.copy(normal);
                    normal.x += prevNormal.x;
                    normal.y += prevNormal.y;
                    normal.z += prevNormal.z;
                    normal.normalize();
                    initNormals.push(normal.x, normal.y, normal.z);
                    prevNormal.copy(curNormal);
                }
                j++;
            }

            // ---- revolve ----
            var i:int = 0;
            while (i <= segments)
            {
                var phi:Number = phiStart + i * inverseSegments * phiLength;
                var sin:Number = Math.sin(phi);
                var cos:Number = Math.cos(phi);

                j = 0;
                while (j <= pointCount - 1)
                {
                    vertex.x = points[j].x * sin;
                    vertex.y = points[j].y;
                    vertex.z = points[j].x * cos;
                    vertices.push(vertex.x, vertex.y, vertex.z);

                    uvs.push(i / segments, j / (pointCount - 1));

                    // Rotate the (dy, -dx) profile normal into 3D: x and z both
                    // scale by initNormals.x * sin/cos, y passes through. The
                    // three.js source reads initNormals[3*j+0] twice -- once for
                    // x and once for z -- and that is intentional (the radial
                    // component rotates as a unit).
                    normals.push(initNormals[3 * j + 0] * sin,
                                 initNormals[3 * j + 1],
                                 initNormals[3 * j + 0] * cos);
                    j++;
                }
                i++;
            }

            // ---- indices ----
            i = 0;
            while (i < segments)
            {
                j = 0;
                while (j < pointCount - 1)
                {
                    var base:int = j + i * pointCount;
                    var a:int = base;
                    var b:int = base + pointCount;
                    var c:int = base + pointCount + 1;
                    var d:int = base + 1;

                    indices.push(a, b, d);
                    indices.push(c, d, b);
                    j++;
                }
                i++;
            }

            this.setIndex(new BufferAttribute(indices, 1));
            this.setAttribute("position", new BufferAttribute(vertices, 3));
            this.setAttribute("uv", new BufferAttribute(uvs, 2));
            this.setAttribute("normal", new BufferAttribute(normals, 3));
        }
    }
}