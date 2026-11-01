// asaot.three.geometries.EdgesGeometry -- silhouette/hard-edge line segments.
//
// Borrows src/geometries/EdgesGeometry.js (r187): every triangle edge is
// hashed by its (quantized) endpoint positions. When the SAME edge appears in
// two triangles with normals differing by more than `thresholdAngle`, it is a
// hard edge and both vertices are emitted; an edge that appears only once is a
// boundary and is emitted too. Edges shared by coplanar faces are dropped, which
// is what makes a box render as 12 lines instead of 36.
//
// Output is a non-indexed `position` attribute of vertex PAIRS -- it is meant for
// LineSegments, not for drawTriangles.
//
// DIVERGENCES (three-api-design.md §16):
//   D62  three.js stores edges in a `Map` keyed by string and marks a matched
//        pair by `set(key, null)`, relying on Map insertion order for output
//        order. as-aot's Dictionary has no insertion order and returns null both
//        for "absent" and "stored null", so this port keeps an explicit
//        `_edgeOrder` vector (creation order = three.js's insertion order) plus
//        `_edgeIndex` (key -> position) and `_edgeConsumed` (key -> true) to
//        reproduce `has()` / `get()` exactly.
//   D63  `thresholdAngle` is in DEGREES (three.js does the same, converting with
//        DEG2RAD internally).
package asaot.three.geometries
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.math.MathUtils;
    import asaot.three.math.Vector3;
    import flash.utils.Dictionary;

    public class EdgesGeometry extends BufferGeometry
    {
        private var _edgeOrder:Vector.<EdgeRecord>;
        private var _edgeIndex:Dictionary;      // hash -> int (index into _edgeOrder)
        private var _edgeConsumed:Dictionary;   // hash -> true
        private var _vertices:Vector.<Number>;

        public function EdgesGeometry(geometry:BufferGeometry = null, thresholdAngle:Number = 1)
        {
            super();

            if (geometry == null) return;

            var precision:Number = Math.pow(10, 4);
            var thresholdDot:Number = Math.cos(MathUtils.degToRad(thresholdAngle));

            var indexAttr:BufferAttribute = geometry.getIndex();
            var positionAttr:BufferAttribute = geometry.getAttribute("position");
            if (positionAttr == null) return;

            var indexCount:int = (indexAttr != null) ? indexAttr.count : positionAttr.count;

            this._edgeOrder = new Vector.<EdgeRecord>();
            this._edgeIndex = new Dictionary();
            this._edgeConsumed = new Dictionary();
            this._vertices = new Vector.<Number>();

            var a:Vector3 = new Vector3();
            var b:Vector3 = new Vector3();
            var c:Vector3 = new Vector3();
            var normal:Vector3 = new Vector3();
            var hashes:Vector.<String> = new Vector.<String>(3, true);
            var idx:Vector.<int> = new Vector.<int>(3, true);

            var i:int = 0;
            while (i < indexCount)
            {
                if (indexAttr != null)
                {
                    idx[0] = int(indexAttr.getX(i));
                    idx[1] = int(indexAttr.getX(i + 1));
                    idx[2] = int(indexAttr.getX(i + 2));
                }
                else
                {
                    idx[0] = i;
                    idx[1] = i + 1;
                    idx[2] = i + 2;
                }

                a.set(positionAttr.getX(idx[0]), positionAttr.getY(idx[0]), positionAttr.getZ(idx[0]));
                b.set(positionAttr.getX(idx[1]), positionAttr.getY(idx[1]), positionAttr.getZ(idx[1]));
                c.set(positionAttr.getX(idx[2]), positionAttr.getY(idx[2]), positionAttr.getZ(idx[2]));

                // three.js Triangle.getNormal: (c-b) x (a-b), normalized.
                normal.subVectors(c, b);
                var ab:Vector3 = new Vector3().subVectors(a, b);
                normal.cross(ab);
                var normalLenSq:Number = normal.lengthSq();
                if (normalLenSq > 0) normal.multiplyScalar(1 / Math.sqrt(normalLenSq));

                hashes[0] = EdgesGeometry._hash(a, precision);
                hashes[1] = EdgesGeometry._hash(b, precision);
                hashes[2] = EdgesGeometry._hash(c, precision);

                // A triangle with two coincident vertices contributes no edge.
                if (hashes[0] == hashes[1] || hashes[1] == hashes[2] || hashes[2] == hashes[0])
                {
                    i += 3;
                    continue;
                }

                var verts:Vector.<Vector3> = new Vector.<Vector3>(3, true);
                verts[0] = a;
                verts[1] = b;
                verts[2] = c;

                var j:int = 0;
                while (j < 3)
                {
                    var jNext:int = (j + 1) % 3;
                    var hash:String = hashes[j] + "_" + hashes[jNext];
                    var reverseHash:String = hashes[jNext] + "_" + hashes[j];

                    if (this._isPending(reverseHash))
                    {
                        var sibling:EdgeRecord = this._edgeOrder[int(this._edgeIndex[reverseHash])];
                        if (normal.dot(sibling.normal) <= thresholdDot)
                        {
                            var v0:Vector3 = verts[j];
                            var v1:Vector3 = verts[jNext];
                            this._vertices.push(v0.x, v0.y, v0.z);
                            this._vertices.push(v1.x, v1.y, v1.z);
                        }
                        // matched pair consumed -- three.js sets the Map slot to
                        // null; we also flag the record so the final pass can
                        // skip it without a reverse key lookup.
                        sibling.consumed = true;
                        this._edgeConsumed[reverseHash] = true;
                    }
                    else if (!this._hasEdge(hash))
                    {
                        var rec:EdgeRecord = new EdgeRecord();
                        rec.index0 = idx[j];
                        rec.index1 = idx[jNext];
                        rec.normal.set(normal.x, normal.y, normal.z);
                        this._edgeIndex[hash] = this._edgeOrder.length;
                        this._edgeOrder.push(rec);
                    }

                    j++;
                }

                i += 3;
            }

            // Unmatched (boundary) edges, in creation order -- three.js's final
            // `for (const edge of edgeData.values()) if (edge) ...` pass.
            var k:int = 0;
            var n:int = this._edgeOrder.length;
            var vv:Vector3 = new Vector3();
            while (k < n)
            {
                var e:EdgeRecord = this._edgeOrder[k];
                if (!e.consumed)
                {
                    vv.set(positionAttr.getX(e.index0), positionAttr.getY(e.index0), positionAttr.getZ(e.index0));
                    this._vertices.push(vv.x, vv.y, vv.z);
                    vv.set(positionAttr.getX(e.index1), positionAttr.getY(e.index1), positionAttr.getZ(e.index1));
                    this._vertices.push(vv.x, vv.y, vv.z);
                }
                k++;
            }

            this.setAttribute("position", new BufferAttribute(this._vertices, 3));

            this._edgeOrder = null;
            this._edgeIndex = null;
            this._edgeConsumed = null;
            this._vertices = null;
        }

        private static function _hash(v:Vector3, precision:Number):String
        {
            return Math.round(v.x * precision) + "," + Math.round(v.y * precision) + ","
                 + Math.round(v.z * precision);
        }

        // `edgeData.has(key)` -- present whether pending or consumed (D62).
        private function _hasEdge(key:String):Boolean
        {
            return (this._edgeIndex[key] != null) || (this._edgeConsumed[key] != null);
        }

        // `edgeData.get(key)` being truthy -- i.e. present AND not consumed.
        private function _isPending(key:String):Boolean
        {
            return (this._edgeIndex[key] != null) && (this._edgeConsumed[key] == null);
        }
    }
}