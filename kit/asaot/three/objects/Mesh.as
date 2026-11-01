// asaot.three.objects.Mesh -- renderable object holding geometry + material.
//
// Borrows src/objects/Mesh.js (r187): two strong references, `geometry` and
// `material`, that the renderer (seam layer) reads to emit draw calls, plus the
// M12 morph-target surface (`morphTargetInfluences` / `morphTargetDictionary` /
// `updateMorphTargets()`).
//
// MORPH TARGETS (M12):
//   three.js applies morphs in the vertex shader (morphtarget_vertex.glsl.js) by
//   summing per-target attributes weighted by `morphTargetInfluences`. Our AGAL
//   programs have a fixed vertex attribute set (va0 position / va1 normal /
//   va2 uv) and no way to bind a variable number of extra streamline streams, so
//   the same arithmetic runs on the CPU here and writes back into the geometry's
//   own `position` / `normal` attributes (D84, three-api-design.md §17.4).
//   The bind-pose copy taken on first deform is what keeps the operation
//   idempotent.
package asaot.three.objects
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Face;
    import asaot.three.core.Intersection;
    import asaot.three.core.Object3D;
    import asaot.three.core.Raycaster;
    import asaot.three.core.Sphere;
    import asaot.three.materials.Material;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Ray;
    import asaot.three.math.Triangle;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;

    import flash.utils.Dictionary;

    public class Mesh extends Object3D
    {
        public var geometry:BufferGeometry = null;
        public var material:Material = null;
        public var isMesh:Boolean = true;

        // ---- morph targets (M12) ----
        public var morphTargetInfluences:Vector.<Number> = null;
        public var morphTargetDictionary:Dictionary = null;

        // Pristine bind-pose copies; null until the first deform.
        protected var _basePosition:Vector.<Number> = null;
        protected var _baseNormal:Vector.<Number> = null;

        // Per-frame scratch (morphed, before any skinning).
        protected var _deformPosition:Vector.<Number> = null;
        protected var _deformNormal:Vector.<Number> = null;

        // Frame stamp: the renderer draws a mesh once per shadow pass and once
        // in the main pass; deforming twice would be wasted work.
        public var _deformFrame:int = -1;

        // ---- picking scratch (M14) ----
        // Raycaster hits run once per click, but a single hit walks every triangle
        // of the mesh, so the per-triangle path must not allocate (AGENTS.md).
        // These are per-instance: two meshes can be visited inside one traversal.
        private var _pickSphere:Sphere = new Sphere();
        private var _pickRay:Ray = new Ray();
        private var _pickInverse:Matrix4 = new Matrix4();
        private var _pickHitAt:Vector3 = new Vector3();
        private var _pickInterPoint:Vector3 = new Vector3();
        private var _pickWorldPoint:Vector3 = new Vector3();
        private var _pickVA:Vector3 = new Vector3();
        private var _pickVB:Vector3 = new Vector3();
        private var _pickVC:Vector3 = new Vector3();
        private var _pickBary:Vector3 = new Vector3();
        private var _pickDistance:Number = 0;

        public function Mesh(geometry:BufferGeometry = null, material:Material = null)
        {
            super();
            this.geometry = geometry;
            this.material = material;
        }

        // Mesh.js:updateMorphTargets. Builds the influence vector (one slot per
        // target, zeroed) and the name -> index dictionary from
        // geometry.morphAttributes.
        public function updateMorphTargets():void
        {
            var geometry:BufferGeometry = this.geometry;
            if (geometry == null || geometry.morphAttributes == null) return;

            var positionTargets:Vector.<BufferAttribute> = geometry.morphAttributes["position"];
            if (positionTargets == null || positionTargets.length == 0) return;

            var n:int = positionTargets.length;

            this.morphTargetInfluences = new Vector.<Number>(n, true);
            this.morphTargetDictionary = new Dictionary();

            for (var i:int = 0; i < n; i++)
            {
                var name:String = positionTargets[i].name;
                if (name == null || name == "") name = "morphTarget" + i;
                this.morphTargetDictionary[name] = i;
            }
        }

        public function hasMorph():Boolean
        {
            var geometry:BufferGeometry = this.geometry;
            if (geometry == null || this.morphTargetInfluences == null) return false;
            var targets:Vector.<BufferAttribute> = geometry.morphAttributes["position"];
            return (targets != null && targets.length > 0);
        }

        // Copies the geometry's current position/normal arrays aside so that the
        // deform can be recomputed from a stable base every frame.
        protected function captureBindPose():void
        {
            var geometry:BufferGeometry = this.geometry;
            var position:BufferAttribute = geometry.getAttribute("position");
            if (position == null) return;

            var n:int = position.count * 3;
            if (this._basePosition == null || this._basePosition.length != n)
            {
                this._basePosition = new Vector.<Number>(n);
                this._deformPosition = new Vector.<Number>(n);
                for (var i:int = 0; i < n; i++) this._basePosition[i] = position.array[i];
            }

            var normal:BufferAttribute = geometry.getAttribute("normal");
            if (normal != null && normal.count * 3 == n)
            {
                if (this._baseNormal == null || this._baseNormal.length != n)
                {
                    this._baseNormal = new Vector.<Number>(n);
                    this._deformNormal = new Vector.<Number>(n);
                    for (var j:int = 0; j < n; j++) this._baseNormal[j] = normal.array[j];
                }
            }
        }

        // outPos/outNormal := bind pose + sum( influence * delta ). Handles both
        // glTF's relative (delta) targets and three.js's absolute mode.
        protected function writeMorphedAttributes(outPos:Vector.<Number>, outNormal:Vector.<Number>):void
        {
            var geometry:BufferGeometry = this.geometry;
            var n:int = this._basePosition.length;

            for (var i:int = 0; i < n; i++)
            {
                outPos[i] = this._basePosition[i];
                if (outNormal != null && this._baseNormal != null) outNormal[i] = this._baseNormal[i];
            }

            var influences:Vector.<Number> = this.morphTargetInfluences;
            if (influences == null) return;

            var relative:Boolean = geometry.morphTargetsRelative;

            this._accumulateMorph(geometry, "position", influences, relative, outPos);
            if (outNormal != null && this._baseNormal != null)
            {
                this._accumulateMorph(geometry, "normal", influences, relative, outNormal);
            }
        }

        private function _accumulateMorph(geometry:BufferGeometry, attributeName:String,
                                          influences:Vector.<Number>, relative:Boolean,
                                          out:Vector.<Number>):void
        {
            var targets:Vector.<BufferAttribute> = geometry.morphAttributes[attributeName];
            if (targets == null) return;

            var nTargets:int = targets.length;
            var nValues:int = out.length;

            for (var t:int = 0; t < nTargets; t++)
            {
                if (t >= influences.length) break;
                var weight:Number = influences[t];
                if (weight == 0) continue;

                var array:Vector.<Number> = targets[t].array;
                var count:int = (array.length < nValues) ? array.length : nValues;

                if (relative)
                {
                    for (var i:int = 0; i < count; i++) out[i] += array[i] * weight;
                }
                else
                {
                    // absolute target: out := mix( out, target, weight )
                    var inv:Number = 1 - weight;
                    for (var j:int = 0; j < count; j++) out[j] = out[j] * inv + array[j] * weight;
                }
            }
        }

        // ---- picking (M14) ---------------------------------------------------

        // Mesh.js:184 -- the vertex `index` in LOCAL space. three.js adds the morph
        // targets here (getVertexPosition); we do not, because our morphs are
        // already summed into the position attribute by updateDeform (D84), and
        // adding them again would double-count every influence. Consequence: a
        // pick made BEFORE the first render sees the bind pose, so a frame-driven
        // app picks the pose it last drew -- which is also what the user sees.
        public function getVertexPosition(index:int, target:Vector3):Vector3
        {
            var position:BufferAttribute = this.geometry.getAttribute("position");
            return target.set(position.getX(index), position.getY(index), position.getZ(index));
        }

        // Mesh.js:246. The bounds tests are not an optimisation detail: without the
        // bounding-sphere reject, a 100k-triangle mesh that the ray misses by a
        // metre would still be walked triangle by triangle on every pointer move.
        override public function raycast(raycaster:Raycaster, intersects:Vector.<Intersection>):Boolean
        {
            var geometry:BufferGeometry = this.geometry;
            var material:Material = this.material;
            if (geometry == null || material == null) return true;

            var position:BufferAttribute = geometry.getAttribute("position");
            if (position == null) return true;

            // World-space bounding sphere first (computed lazily, as three.js does).
            if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
            if (geometry.boundingSphere != null && !geometry.boundingSphere.isEmpty())
            {
                // Copy before transforming: Sphere holds a REFERENCE to its center,
                // so applying the world matrix to geometry.boundingSphere itself
                // would corrupt the local bounds (and the next frame's culling).
                this._pickSphere.copy(geometry.boundingSphere);
                this._pickSphere.applyMatrix4(this.matrixWorld);

                this._pickRay.copy(raycaster.ray).recast(raycaster.near);
                if (!this._pickSphere.containsPoint(this._pickRay.origin))
                {
                    if (this._pickRay.intersectSphere(this._pickSphere, this._pickHitAt) == null) return true;
                    var reach:Number = raycaster.far - raycaster.near;
                    if (this._pickRay.origin.distanceToSquared(this._pickHitAt) > reach * reach) return true;
                }
            }

            // Everything below runs in the mesh's LOCAL space, which is what makes
            // one geometry reusable by many meshes at different transforms.
            this._pickInverse.copy(this.matrixWorld).invert();
            this._pickRay.copy(raycaster.ray).applyMatrix4(this._pickInverse);

            if (geometry.boundingBox != null && !this._pickRay.intersectsBox(geometry.boundingBox)) return true;

            var index:BufferAttribute = geometry.index;
            var uv:BufferAttribute = geometry.getAttribute("uv");
            var normal:BufferAttribute = geometry.getAttribute("normal");

            var start:int = geometry.drawRange.start;
            if (start < 0) start = 0;
            var rangeCount:int = geometry.drawRange.count; // -1 = to the end (D7)

            var i:int;
            var end:int;
            var a:int, b:int, c:int;

            if (index != null)
            {
                end = index.count;
                if (rangeCount >= 0 && start + rangeCount < end) end = start + rangeCount;
                i = start;
                while (i + 2 < end)
                {
                    a = int(index.getX(i));
                    b = int(index.getX(i + 1));
                    c = int(index.getX(i + 2));
                    this._checkTriangle(raycaster, intersects, material, uv, normal, a, b, c, i);
                    i += 3;
                }
            }
            else
            {
                end = position.count;
                if (rangeCount >= 0 && start + rangeCount < end) end = start + rangeCount;
                i = start;
                while (i + 2 < end)
                {
                    this._checkTriangle(raycaster, intersects, material, uv, normal, i, i + 1, i + 2, i);
                    i += 3;
                }
            }

            return true;
        }

        // One candidate triangle: intersection + interpolated attributes. Mirrors
        // Mesh.js:checkGeometryIntersection. `vertexIndex` is the buffer index the
        // triangle starts at, which is what three.js calls `faceIndex`.
        private function _checkTriangle(raycaster:Raycaster, intersects:Vector.<Intersection>,
                                        material:Material, uv:BufferAttribute, normal:BufferAttribute,
                                        a:int, b:int, c:int, vertexIndex:int):void
        {
            this.getVertexPosition(a, this._pickVA);
            this.getVertexPosition(b, this._pickVB);
            this.getVertexPosition(c, this._pickVC);

            if (!this._checkIntersection(raycaster, material)) return;

            var hit:Intersection = new Intersection();
            hit.distance = this._pickDistance;
            hit.point = this._pickWorldPoint.clone();
            hit.object = this;

            var bary:Vector3 = new Vector3();
            Triangle.getBarycoord(this._pickInterPoint, this._pickVA, this._pickVB, this._pickVC, bary);
            hit.barycoord = bary;

            if (uv != null)
            {
                hit.uv = new Vector2(uv.getX(a) * bary.x + uv.getX(b) * bary.y + uv.getX(c) * bary.z,
                                     uv.getY(a) * bary.x + uv.getY(b) * bary.y + uv.getY(c) * bary.z);
            }

            if (normal != null)
            {
                var nx:Number = normal.getX(a) * bary.x + normal.getX(b) * bary.y + normal.getX(c) * bary.z;
                var ny:Number = normal.getY(a) * bary.x + normal.getY(b) * bary.y + normal.getY(c) * bary.z;
                var nz:Number = normal.getZ(a) * bary.x + normal.getZ(b) * bary.y + normal.getZ(c) * bary.z;
                var n:Vector3 = new Vector3(nx, ny, nz);
                // Flip to the ray's side: an interpolated normal that points away
                // from the camera is useless for a hover highlight.
                if (n.dot(this._pickRay.direction) > 0) n.multiplyScalar(-1);
                hit.normal = n;
            }

            var face:Face = new Face(a, b, c);
            Triangle.getNormal(this._pickVA, this._pickVB, this._pickVC, face.normal);
            hit.face = face;
            hit.faceIndex = int(vertexIndex / 3);

            intersects.push(hit);
        }

        // Mesh.js:checkIntersection. `material.side` decides the winding used for
        // culling: FrontSide keeps triangles whose normal faces the ray, BackSide
        // reverses the winding (so the INSIDE of a box becomes pickable), and
        // DoubleSide accepts either. Hitting through a back face is the difference
        // between "the rays pass through this cube" and "the cube is solid".
        private function _checkIntersection(raycaster:Raycaster, material:Material):Boolean
        {
            var hit:Vector3;
            if (material.side == Material.BackSide)
            {
                hit = this._pickRay.intersectTriangle(this._pickVC, this._pickVB, this._pickVA, true, this._pickInterPoint);
            }
            else
            {
                hit = this._pickRay.intersectTriangle(this._pickVA, this._pickVB, this._pickVC,
                                                     material.side == Material.FrontSide, this._pickInterPoint);
            }
            if (hit == null) return false;

            this._pickWorldPoint.copy(hit).applyMatrix4(this.matrixWorld);
            this._pickDistance = raycaster.ray.origin.distanceTo(this._pickWorldPoint);
            if (this._pickDistance < raycaster.near || this._pickDistance > raycaster.far) return false;
            return true;
        }

        // Called by the seam renderer once per drawn frame. Writes the morphed
        // values back into the geometry attributes and bumps their version so the
        // vertex buffers are re-uploaded.
        public function updateDeform(frameId:int):void
        {
            if (frameId == this._deformFrame) return;
            this._deformFrame = frameId;

            var geometry:BufferGeometry = this.geometry;
            if (geometry == null || !this.hasMorph()) return;

            this.captureBindPose();

            var position:BufferAttribute = geometry.getAttribute("position");
            if (position == null) return;

            this.writeMorphedAttributes(this._deformPosition, this._deformNormal);

            var n:int = this._deformPosition.length;
            for (var i:int = 0; i < n; i++) position.array[i] = this._deformPosition[i];
            position.needsUpdate = true;

            var normal:BufferAttribute = geometry.getAttribute("normal");
            if (normal != null && this._deformNormal != null && normal.count * 3 == n)
            {
                for (var j:int = 0; j < n; j++) normal.array[j] = this._deformNormal[j];
                normal.needsUpdate = true;
            }
        }
    }
}