// asaot.three.geometries.CylinderGeometry -- closed/open cylinder attribute factory.
//
// Borrows the topology of three.js src/geometries/CylinderGeometry.js (r187):
// a torso grid of (heightSegments+1) x (radialSegments+1) vertices with the
// slope-corrected normal, plus two independently-UV'd caps, each cap getting its
// own centre vertex per radial segment so the disc can carry radial UVs.
//
// DIVERGENCES (three-api-design.md §16):
//   D-fn     generateTorso/generateCap are JS nested closures sharing `scope`,
//            `index`, `indexArray`, `groupStart` and the four buffers. AS3 has no
//            nested functions, so they become private methods over instance
//            fields promoted in the constructor and cleared before returning
//            (same shape as BoxGeometry.buildPlane).
//   D-group  materialIndex 0/1/2 for torso/top-cap/bottom-cap, exactly as
//            three.js (a multi-material disc still needs groups).
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.Vector3;

    public class CylinderGeometry extends BufferGeometry
    {
        // Shared generator state (three.js keeps these as closure locals).
        private var _indices:Vector.<Number>;
        private var _vertices:Vector.<Number>;
        private var _normals:Vector.<Number>;
        private var _uvs:Vector.<Number>;
        private var _index:int;
        private var _indexArray:Vector.<Vector.<Number>>;
        private var _groupStart:int;

        // Constructor arguments needed by both generators.
        private var _radiusTop:Number;
        private var _radiusBottom:Number;
        private var _height:Number;
        private var _radialSegments:int;
        private var _heightSegments:int;
        private var _thetaStart:Number;
        private var _thetaLength:Number;

        public function CylinderGeometry(radiusTop:Number = 1, radiusBottom:Number = 1, height:Number = 1,
                                         radialSegments:int = 32, heightSegments:int = 1, openEnded:Boolean = false,
                                         thetaStart:Number = 0, thetaLength:Number = Math.PI * 2)
        {
            super();

            radialSegments = Math.floor(radialSegments);
            heightSegments = Math.floor(heightSegments);

            this._indices = new Vector.<Number>();
            this._vertices = new Vector.<Number>();
            this._normals = new Vector.<Number>();
            this._uvs = new Vector.<Number>();
            this._index = 0;
            this._indexArray = new Vector.<Vector.<Number>>();
            this._groupStart = 0;

            this._radiusTop = radiusTop;
            this._radiusBottom = radiusBottom;
            this._height = height;
            this._radialSegments = radialSegments;
            this._heightSegments = heightSegments;
            this._thetaStart = thetaStart;
            this._thetaLength = thetaLength;

            this.generateTorso();

            if (openEnded == false)
            {
                // A zero-radius cap would produce degenerate triangles, so
                // three.js skips it (this is how ConeGeometry reuses us).
                if (radiusTop > 0) this.generateCap(true);
                if (radiusBottom > 0) this.generateCap(false);
            }

            this.setIndex(new BufferAttribute(this._indices, 1));
            this.setAttribute("position", new BufferAttribute(this._vertices, 3));
            this.setAttribute("normal", new BufferAttribute(this._normals, 3));
            this.setAttribute("uv", new BufferAttribute(this._uvs, 2));

            this._indices = null;
            this._vertices = null;
            this._normals = null;
            this._uvs = null;
            this._indexArray = null;
        }

        // three.js CylinderGeometry.js:127 generateTorso.
        private function generateTorso():void
        {
            var normal:Vector3 = new Vector3();
            var vertex:Vector3 = new Vector3();
            var groupCount:int = 0;

            var radialSegments:int = this._radialSegments;
            var heightSegments:int = this._heightSegments;
            var radiusTop:Number = this._radiusTop;
            var radiusBottom:Number = this._radiusBottom;
            var height:Number = this._height;
            var thetaStart:Number = this._thetaStart;
            var thetaLength:Number = this._thetaLength;
            var halfHeight:Number = height / 2;

            // The normal's y component follows the side's slope so a tapered
            // cylinder (cone) gets correctly tilted normals.
            var slope:Number = (radiusBottom - radiusTop) / height;

            var y:int = 0;
            while (y <= heightSegments)
            {
                var indexRow:Vector.<Number> = new Vector.<Number>();
                var v:Number = y / heightSegments;
                var radius:Number = v * (radiusBottom - radiusTop) + radiusTop;

                var x:int = 0;
                while (x <= radialSegments)
                {
                    var u:Number = x / radialSegments;
                    var theta:Number = u * thetaLength + thetaStart;
                    var sinTheta:Number = Math.sin(theta);
                    var cosTheta:Number = Math.cos(theta);

                    vertex.x = radius * sinTheta;
                    vertex.y = -v * height + halfHeight;
                    vertex.z = radius * cosTheta;
                    this._vertices.push(vertex.x, vertex.y, vertex.z);

                    normal.set(sinTheta, slope, cosTheta).normalize();
                    this._normals.push(normal.x, normal.y, normal.z);

                    this._uvs.push(u, 1 - v);
                    indexRow.push(this._index);
                    this._index++;
                    x++;
                }

                this._indexArray.push(indexRow);
                y++;
            }

            x = 0;
            while (x < radialSegments)
            {
                y = 0;
                while (y < heightSegments)
                {
                    var a:int = this._indexArray[y][x];
                    var b:int = this._indexArray[y + 1][x];
                    var c:int = this._indexArray[y + 1][x + 1];
                    var d:int = this._indexArray[y][x + 1];

                    // With a zero-radius end, the triangles that collapse onto
                    // the apex are skipped (radiusTop>0||y!=0 / radiusBottom>0||
                    // y!=heightSegments-1), matching three.js exactly.
                    if (radiusTop > 0 || y != 0)
                    {
                        this._indices.push(a, b, d);
                        groupCount += 3;
                    }
                    if (radiusBottom > 0 || y != heightSegments - 1)
                    {
                        this._indices.push(b, c, d);
                        groupCount += 3;
                    }
                    y++;
                }
                x++;
            }

            this.addGroup(this._groupStart, groupCount, 0);
            this._groupStart += groupCount;
        }

        // three.js CylinderGeometry.js:227 generateCap.
        private function generateCap(top:Boolean):void
        {
            var centerIndexStart:int = this._index;
            var groupCount:int = 0;

            var radialSegments:int = this._radialSegments;
            var thetaStart:Number = this._thetaStart;
            var thetaLength:Number = this._thetaLength;
            var halfHeight:Number = this._height / 2;
            var radius:Number = top ? this._radiusTop : this._radiusBottom;
            var sign:Number = top ? 1 : -1;

            // One centre vertex PER radial segment: the disc needs a distinct UV
            // at every spoke, so the centre cannot be shared.
            var x:int = 1;
            while (x <= radialSegments)
            {
                this._vertices.push(0, halfHeight * sign, 0);
                this._normals.push(0, sign, 0);
                this._uvs.push(0.5, 0.5);
                this._index++;
                x++;
            }

            var centerIndexEnd:int = this._index;

            x = 0;
            while (x <= radialSegments)
            {
                var u:Number = x / radialSegments;
                var theta:Number = u * thetaLength + thetaStart;
                var cosTheta:Number = Math.cos(theta);
                var sinTheta:Number = Math.sin(theta);

                this._vertices.push(radius * sinTheta, halfHeight * sign, radius * cosTheta);
                this._normals.push(0, sign, 0);
                this._uvs.push(cosTheta * 0.5 + 0.5, sinTheta * 0.5 * sign + 0.5);
                this._index++;
                x++;
            }

            x = 0;
            while (x < radialSegments)
            {
                var c:int = centerIndexStart + x;
                var i:int = centerIndexEnd + x;
                if (top)
                {
                    this._indices.push(i, i + 1, c);
                }
                else
                {
                    this._indices.push(i + 1, i, c);
                }
                groupCount += 3;
                x++;
            }

            this.addGroup(this._groupStart, groupCount, top ? 1 : 2);
            this._groupStart += groupCount;
        }
    }
}