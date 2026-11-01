// asaot.three.core.BufferGeometry -- GPU geometry (attribute buffers + index), three.js style.
//
// Borrows the design of three.js src/core/BufferGeometry.js (r187): a name->attribute
// map, an optional index buffer, draw groups, and drawRange, plus computeBoundingBox /
// computeBoundingSphere. It holds NO rendering state (that lives in the seam layer).
//
// DIVERGENCES (three-api-design.md §8):
//   D1  `attributes` is a Dictionary (String key -> BufferAttribute), not a JS {}.
//       as-aot's Dictionary keys strings by value (as_v_eq strcmp), matching the
//       string-key access here.
//   D5  `groups` is a Vector.<GeometryGroup> and `drawRange` is a DrawRange struct,
//       not JS object literals.
//   D7  `drawRange.count = -1` is the "render to end" sentinel, not JS Infinity.
//   D-index the index buffer is a Vector.<Number> with itemSize=1 (see BufferAttribute).
//   D64 `attributeNames` is an explicit ordered list of the attribute keys.
//       JS's `Object.keys(attributes)` returns insertion order for string keys,
//       and mergeGeometries relies on that order to lay out the merged buffers;
//       as-aot's Dictionary does not guarantee enumeration order, so the order is
//       recorded as it is created.
package asaot.three.core
{
    import asaot.three.math.MathUtils;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;
    import flash.utils.Dictionary;

    public class BufferGeometry
    {
        public var attributes:Dictionary;
        // D64: attribute keys in insertion order (the JS `Object.keys` order).
        public var attributeNames:Vector.<String>;
        public var index:BufferAttribute;         // null = non-indexed
        public var groups:Vector.<GeometryGroup>;
        public var boundingBox:Box3;              // null until computeBoundingBox()
        public var boundingSphere:Sphere;         // null until computeBoundingSphere()
        public var drawRange:DrawRange;
        public var name:String = "";
        public var uuid:String;

        // ---- morph targets (M12, BufferGeometry.js:morphAttributes) ----
        //`morphAttributes.position` / `.normal` / `.color` map to a Vector of
        // BufferAttribute, one per morph target. glTF stores DELTAS, hence
        //`morphTargetsRelative = true` (GLTFLoader sets it); the CPU morph path in
        // Mesh.updateDeform adds `delta * influence` on top of the base attribute.
        public var morphAttributes:Dictionary;
        public var morphTargetsRelative:Boolean = false;

        public function BufferGeometry()
        {
            this.attributes = new Dictionary();
            this.attributeNames = new Vector.<String>();
            this.groups = new Vector.<GeometryGroup>();
            this.index = null;
            this.boundingBox = null;
            this.boundingSphere = null;
            this.drawRange = new DrawRange();
            this.morphAttributes = new Dictionary();
            this.uuid = MathUtils.generateUUID();
        }

        // ---- index (three.js BufferGeometry.js:230) ----
        public function getIndex():BufferAttribute
        {
            return this.index;
        }

        public function setIndex(index:BufferAttribute):BufferGeometry
        {
            this.index = index;
            return this;
        }

        // ---- attribute accessors (three.js BufferGeometry.js:280-330) ----
        public function getAttribute(name:String):BufferAttribute
        {
            return this.attributes[name];
        }

        public function setAttribute(name:String, attribute:BufferAttribute):BufferGeometry
        {
            this.attributes[name] = attribute;
            // D64: record first assignment so mergeGeometries can reproduce JS's
            // insertion-ordered Object.keys walk.
            if (this._indexOfName(name) < 0) this.attributeNames.push(name);
            return this;
        }

        public function deleteAttribute(name:String):BufferGeometry
        {
            // M1 keeps "null means absent" as the single missing-key convention:
            // getAttribute returns null, hasAttribute tests null, and delete assigns
            // null. three.js `delete`s the key (so read-back is undefined); we store
            // only non-null BufferAttributes, so a null value is a safe sentinel with
            // identical call-site behavior (a null attribute is treated as missing).
            this.attributes[name] = null;
            // D64: a deleted key must also disappear from the ordered name list,
            // otherwise mergeGeometries would see an attribute that no longer
            // exists (JS `delete` drops it from Object.keys too).
            var pos:int = this._indexOfName(name);
            if (pos >= 0) this.attributeNames.splice(pos, 1);
            return this;
        }

        private function _indexOfName(name:String):int
        {
            var n:int = this.attributeNames.length;
            for (var i:int = 0; i < n; i++)
            {
                if (this.attributeNames[i] == name) return i;
            }
            return -1;
        }

        public function hasAttribute(name:String):Boolean
        {
            return this.attributes[name] != null;
        }

        // ---- groups (three.js BufferGeometry.js:335-360) ----
        public function addGroup(start:int, count:int, materialIndex:int = 0):void
        {
            this.groups.push(new GeometryGroup(start, count, materialIndex));
        }

        public function clearGroups():void
        {
            this.groups = new Vector.<GeometryGroup>();
        }

        // ---- draw range (three.js BufferGeometry.js:363) ----
        public function setDrawRange(start:int, count:int):void
        {
            this.drawRange.start = start;
            this.drawRange.count = count;
        }

        // ---- bounding volumes (three.js BufferGeometry.js:643/718) ----
        public function computeBoundingBox():void
        {
            if (this.boundingBox == null) this.boundingBox = new Box3();
            var position:BufferAttribute = this.attributes["position"];
            if (position != null)
            {
                this.boundingBox.setFromBufferAttribute(position);
            }
            else
            {
                this.boundingBox.makeEmpty();
            }
        }

        // ---- tangent computation (three.js BufferGeometry.js:837-975) ----
        //
        // M4 borrows the Lengyel per-vertex tangent algorithm (Gram-Schmidt
        // orthogonalization + handedness in the w component). It requires an
        // indexed geometry with position/normal/uv; degenerate-uv triangles are
        // silently skipped (three.js's isFinite(r) guard). This feeds the
        // USE_TANGENT normal-map path (R8): AGAL has no derivative ops, so the
        // derivative-based getTangentFrame path is not available.
        //
        // three.js nests handleTriangle/handleVertex closures; AS3 has none, so
        // per D13 they are lifted to private methods sharing _ct* instance fields.

        private var _ctPosition:BufferAttribute;
        private var _ctNormal:BufferAttribute;
        private var _ctUv:BufferAttribute;
        private var _ctTan1:Vector.<Vector3>;
        private var _ctTan2:Vector.<Vector3>;
        private var _ctUsed:Vector.<int>;
        private var _ctVA:Vector3 = new Vector3();
        private var _ctVB:Vector3 = new Vector3();
        private var _ctVC:Vector3 = new Vector3();
        private var _ctUvA:Vector2 = new Vector2();
        private var _ctUvB:Vector2 = new Vector2();
        private var _ctUvC:Vector2 = new Vector2();
        private var _ctSdir:Vector3 = new Vector3();
        private var _ctTdir:Vector3 = new Vector3();
        private var _ctTmp:Vector3 = new Vector3();
        private var _ctTmp2:Vector3 = new Vector3();
        private var _ctN:Vector3 = new Vector3();
        private var _ctN2:Vector3 = new Vector3();
        private var _ctTangent:BufferAttribute;

        // computeVertexNormals working set (three.js uses locals + a module
        // Vector3; AS3 has no nested functions, so these are instance fields
        // shared by computeVertexNormals and normalizeNormals -- D13).
        private var _cnPA:Vector3 = new Vector3();
        private var _cnPB:Vector3 = new Vector3();
        private var _cnPC:Vector3 = new Vector3();
        private var _cnCB:Vector3 = new Vector3();
        private var _cnAB:Vector3 = new Vector3();
        private var _cnNrm:Vector3 = new Vector3();

        public function computeTangents():void
        {
            var position:BufferAttribute = this.attributes["position"];
            var normal:BufferAttribute = this.attributes["normal"];
            var uv:BufferAttribute = this.attributes["uv"];
            var index:BufferAttribute = this.index;
            if (index == null || position == null || normal == null || uv == null) return;

            var tangent:BufferAttribute = this.attributes["tangent"];
            if (tangent == null || tangent.count != position.count)
            {
                tangent = new BufferAttribute(new Vector.<Number>(4 * position.count), 4);
                this.setAttribute("tangent", tangent);
            }

            var tan1:Vector.<Vector3> = new Vector.<Vector3>();
            var tan2:Vector.<Vector3> = new Vector.<Vector3>();
            var used:Vector.<int> = new Vector.<int>(position.count, true);
            var i:int;
            for (i = 0; i < position.count; i++)
            {
                tan1.push(new Vector3());
                tan2.push(new Vector3());
                used[i] = 0;
            }

            this._ctPosition = position;
            this._ctNormal = normal;
            this._ctUv = uv;
            this._ctTan1 = tan1;
            this._ctTan2 = tan2;
            this._ctUsed = used;
            this._ctTangent = tangent;

            var groups:Vector.<GeometryGroup> = this.groups;
            if (groups.length == 0)
            {
                var j:int = 0;
                while (j < index.count)
                {
                    this._ctTriangle(int(index.getX(j)), int(index.getX(j + 1)), int(index.getX(j + 2)));
                    j += 3;
                }
            }
            else
            {
                var g:int;
                for (g = 0; g < groups.length; g++)
                {
                    var group:GeometryGroup = groups[g];
                    var start:int = group.start;
                    var jl:int = start + group.count;
                    j = start;
                    while (j < jl)
                    {
                        this._ctTriangle(int(index.getX(j)), int(index.getX(j + 1)), int(index.getX(j + 2)));
                        j += 3;
                    }
                }
            }

            for (i = 0; i < position.count; i++)
            {
                if (used[i] != 0) this._ctVertex(i);
            }

            this._ctPosition = null;
            this._ctNormal = null;
            this._ctUv = null;
            this._ctTan1 = null;
            this._ctTan2 = null;
            this._ctUsed = null;
            this._ctTangent = null;
        }

        // three.js handleTriangle (BufferGeometry.js:885-914): accumulate the
        // Lengyel sdir/tdir per vertex. `used` marks vertices owned by at least
        // one non-degenerate triangle.
        private function _ctTriangle(a:int, b:int, c:int):void
        {
            var used:Vector.<int> = this._ctUsed;
            used[a] = 1;
            used[b] = 1;
            used[c] = 1;

            var position:BufferAttribute = this._ctPosition;
            var uv:BufferAttribute = this._ctUv;

            this._ctVA.set(position.getX(a), position.getY(a), position.getZ(a));
            this._ctVB.set(position.getX(b), position.getY(b), position.getZ(b));
            this._ctVC.set(position.getX(c), position.getY(c), position.getZ(c));

            this._ctUvA.set(uv.getX(a), uv.getY(a));
            this._ctUvB.set(uv.getX(b), uv.getY(b));
            this._ctUvC.set(uv.getX(c), uv.getY(c));

            this._ctVB.sub(this._ctVA);
            this._ctVC.sub(this._ctVA);
            this._ctUvB.sub(this._ctUvA);
            this._ctUvC.sub(this._ctUvA);

            var r:Number = 1.0 / (this._ctUvB.x * this._ctUvC.y - this._ctUvC.x * this._ctUvB.y);

            // silently ignore degenerate uv triangles (three.js isFinite guard)
            if (!isFinite(r)) return;

            this._ctSdir.copy(this._ctVB).multiplyScalar(this._ctUvC.y)
                .addScaledVector(this._ctVC, -this._ctUvB.y).multiplyScalar(r);
            this._ctTdir.copy(this._ctVC).multiplyScalar(this._ctUvB.x)
                .addScaledVector(this._ctVB, -this._ctUvC.x).multiplyScalar(r);

            var tan1:Vector.<Vector3> = this._ctTan1;
            var tan2:Vector.<Vector3> = this._ctTan2;
            tan1[a].add(this._ctSdir);
            tan1[b].add(this._ctSdir);
            tan1[c].add(this._ctSdir);
            tan2[a].add(this._ctTdir);
            tan2[b].add(this._ctTdir);
            tan2[c].add(this._ctTdir);
        }

        // three.js handleVertex (BufferGeometry.js:955-971): Gram-Schmidt
        // orthogonalize the accumulated tangent against the vertex normal and
        // derive handedness as the w component.
        private function _ctVertex(v:int):void
        {
            var normal:BufferAttribute = this._ctNormal;
            this._ctN.set(normal.getX(v), normal.getY(v), normal.getZ(v));
            this._ctN2.copy(this._ctN);

            var t:Vector3 = this._ctTan1[v];

            // Gram-Schmidt orthogonalize: tmp = normalize(t - n * (n . t))
            this._ctTmp.copy(t);
            this._ctTmp.sub(this._ctN.multiplyScalar(this._ctN.dot(t))).normalize();

            // handedness: w = sign((n2 x t) . tan2)
            this._ctTmp2.crossVectors(this._ctN2, t);
            var test:Number = this._ctTmp2.dot(this._ctTan2[v]);
            var w:Number = (test < 0.0) ? -1.0 : 1.0;

            this._ctTangent.setXYZW(v, this._ctTmp.x, this._ctTmp.y, this._ctTmp.z, w);
        }

        // ---- bounding volumes (three.js BufferGeometry.js:643/718) ----
        // computeVertexNormals (three.js BufferGeometry.js:997): accumulate
        // per-face cross products into per-vertex normals, then normalize. The
        // indexed branch covers suzanne-style models that ship position + index
        // only (examples/models/json/*). Vector3.fromBufferAttribute is inlined
        // as set(getX(), getY(), getZ()) -- D35: adding it would pull a
        // math->core import into the math package.
        public function computeVertexNormals():void
        {
            var index:BufferAttribute = this.index;
            var positionAttribute:BufferAttribute = this.getAttribute("position");

            if (positionAttribute != null)
            {
                var normalAttribute:BufferAttribute = this.getAttribute("normal");

                if (normalAttribute == null || normalAttribute.count != positionAttribute.count)
                {
                    normalAttribute = new BufferAttribute(new Vector.<Number>(positionAttribute.count * 3), 3);
                    this.setAttribute("normal", normalAttribute);
                }
                else
                {
                    // reset existing normals to zero
                    for (var z:int = 0; z < normalAttribute.count; z++) normalAttribute.setXYZ(z, 0, 0, 0);
                }

                if (index != null)
                {
                    // indexed elements
                    for (var i:int = 0; i < index.count; i += 3)
                    {
                        var vA:int = int(index.getX(i + 0));
                        var vB:int = int(index.getX(i + 1));
                        var vC:int = int(index.getX(i + 2));

                        this._cnPA.set(positionAttribute.getX(vA), positionAttribute.getY(vA), positionAttribute.getZ(vA));
                        this._cnPB.set(positionAttribute.getX(vB), positionAttribute.getY(vB), positionAttribute.getZ(vB));
                        this._cnPC.set(positionAttribute.getX(vC), positionAttribute.getY(vC), positionAttribute.getZ(vC));

                        this._cnCB.subVectors(this._cnPC, this._cnPB);
                        this._cnAB.subVectors(this._cnPA, this._cnPB);
                        this._cnCB.cross(this._cnAB);

                        this._cnNrm.set(normalAttribute.getX(vA), normalAttribute.getY(vA), normalAttribute.getZ(vA));
                        this._cnNrm.add(this._cnCB);
                        normalAttribute.setXYZ(vA, this._cnNrm.x, this._cnNrm.y, this._cnNrm.z);

                        this._cnNrm.set(normalAttribute.getX(vB), normalAttribute.getY(vB), normalAttribute.getZ(vB));
                        this._cnNrm.add(this._cnCB);
                        normalAttribute.setXYZ(vB, this._cnNrm.x, this._cnNrm.y, this._cnNrm.z);

                        this._cnNrm.set(normalAttribute.getX(vC), normalAttribute.getY(vC), normalAttribute.getZ(vC));
                        this._cnNrm.add(this._cnCB);
                        normalAttribute.setXYZ(vC, this._cnNrm.x, this._cnNrm.y, this._cnNrm.z);
                    }
                }
                else
                {
                    // non-indexed elements (unconnected triangle soup)
                    for (var j:int = 0; j < positionAttribute.count; j += 3)
                    {
                        this._cnPA.set(positionAttribute.getX(j + 0), positionAttribute.getY(j + 0), positionAttribute.getZ(j + 0));
                        this._cnPB.set(positionAttribute.getX(j + 1), positionAttribute.getY(j + 1), positionAttribute.getZ(j + 1));
                        this._cnPC.set(positionAttribute.getX(j + 2), positionAttribute.getY(j + 2), positionAttribute.getZ(j + 2));

                        this._cnCB.subVectors(this._cnPC, this._cnPB);
                        this._cnAB.subVectors(this._cnPA, this._cnPB);
                        this._cnCB.cross(this._cnAB);

                        normalAttribute.setXYZ(j + 0, this._cnCB.x, this._cnCB.y, this._cnCB.z);
                        normalAttribute.setXYZ(j + 1, this._cnCB.x, this._cnCB.y, this._cnCB.z);
                        normalAttribute.setXYZ(j + 2, this._cnCB.x, this._cnCB.y, this._cnCB.z);
                    }
                }

                this.normalizeNormals();

                normalAttribute.needsUpdate = true;
            }
        }

        // normalizeNormals (three.js BufferGeometry.js:1073): every normal gets
        // unit length -- the lighting-correctness step computeVertexNormals ends
        // with.
        public function normalizeNormals():void
        {
            var normals:BufferAttribute = this.getAttribute("normal");
            if (normals == null) return;

            for (var i:int = 0; i < normals.count; i++)
            {
                this._cnNrm.set(normals.getX(i), normals.getY(i), normals.getZ(i));
                this._cnNrm.normalize();
                normals.setXYZ(i, this._cnNrm.x, this._cnNrm.y, this._cnNrm.z);
            }

            normals.needsUpdate = true;
        }

        public function computeBoundingSphere():void
        {
            if (this.boundingSphere == null) this.boundingSphere = new Sphere();
            var position:BufferAttribute = this.attributes["position"];
            if (position != null)
            {
                var center:Vector3 = this.boundingSphere.center;
                var box:Box3 = new Box3().setFromBufferAttribute(position);
                box.getCenter(center);

                // Tighter-than-box radius: max distance from center over all vertices
                // (three.js BufferGeometry.js:790-806).
                var maxRadiusSq:Number = 0;
                var v:Vector3 = new Vector3();
                var i:int = 0;
                while (i < position.count)
                {
                    v.set(position.getX(i), position.getY(i), position.getZ(i));
                    var d:Number = center.distanceToSquared(v);
                    if (d > maxRadiusSq) maxRadiusSq = d;
                    i++;
                }
                this.boundingSphere.radius = Math.sqrt(maxRadiusSq);
            }
            else
            {
                this.boundingSphere.makeEmpty();
            }
        }
    }
}
