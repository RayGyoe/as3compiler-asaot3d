// asaot.three.objects.SkinnedMesh -- a Mesh deformed by a Skeleton.
//
// Borrows src/objects/SkinnedMesh.js (r187):
//   * bindMode (attached/detached), bindMatrix / bindMatrixInverse and
//     updateMatrixWorld()'s re-derivation of the inverse;
//   * bind(), normalizeSkinWeights();
//   * applyBoneTransform():  base = bindMatrix * position;
//                            out  = bindMatrixInverse * sum_j w_j * (boneWorld_j * boneInverse_j) * base;
//     which is exactly what skinning_vertex.glsl.js computes on the GPU.
//
// DEFORMATION STRATEGY (D84, three-core plan §17.4):
//   GPU skinning needs either relative constant addressing (`vc[a0.x]`, to index
//   a bone-matrix palette per vertex) or a float texture holding the palette.
//   The AGAL translator has neither -- table lookups of constants are not
//   translated, and Stage3D exposes no float texture format -- so this class
//   runs the same arithmetic on the CPU and writes the result back into the
//   geometry's position/normal attributes. Morph targets run first (three.js
//   order: morph_vertex then skinning_vertex), then skinning consumes the
//   morphed positions.
//
//   The cost is O(vertices * influences) per frame on the CPU instead of on the
//   GPU. That is a deliberate, documented trade-off: the alternative would be a
//   silently wrong skeleton or a renderer that cannot draw glTF skinned meshes at
//   all. See three-api-design.md §17.4 for the measurements on the M12 demo.
package asaot.three.objects
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.materials.Material;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector3;

    public class SkinnedMesh extends Mesh
    {
        public static const AttachedBindMode:String = "attached";
        public static const DetachedBindMode:String = "detached";

        public var isSkinnedMesh:Boolean = true;
        public var bindMode:String = AttachedBindMode;

        public var bindMatrix:Matrix4;
        public var bindMatrixInverse:Matrix4;

        public var skeleton:Skeleton = null;

        private var _hasBind:Boolean = false;
        private var _scratchMatrix:Matrix4 = new Matrix4();

        public function SkinnedMesh(geometry:BufferGeometry = null, material:Material = null)
        {
            super(geometry, material);
            this.bindMatrix = new Matrix4();
            this.bindMatrixInverse = new Matrix4();
        }

        // SkinnedMesh.js:bind.
        public function bind(skeleton:Skeleton, bindMatrix:Matrix4 = null):void
        {
            this.skeleton = skeleton;

            if (bindMatrix == null)
            {
                this.updateMatrixWorld(true);
                this.bindMatrix.copy(this.matrixWorld);
                this.bindMatrixInverse.copy(this.matrixWorld).invert();
            }
            else
            {
                this.bindMatrix.copy(bindMatrix);
                this.bindMatrixInverse.copy(bindMatrix).invert();
            }

            this._hasBind = true;
        }

        public override function updateMatrixWorld(force:Boolean = false):void
        {
            super.updateMatrixWorld(force);

            if (this.bindMode == AttachedBindMode)
            {
                // the bind matrix inverse tracks the mesh's current world matrix
                this.bindMatrixInverse.copy(this.matrixWorld).invert();
            }
            else if (this.bindMode == DetachedBindMode)
            {
                this.bindMatrixInverse.copy(this.bindMatrix).invert();
            }
        }

        // SkinnedMesh.js:normalizeSkinWeights -- glTF exporters do emit weights
        // that do not sum to 1; without this the mesh shrinks toward the origin.
        public function normalizeSkinWeights():void
        {
            var geometry:BufferGeometry = this.geometry;
            if (geometry == null) return;

            var skinWeight:BufferAttribute = geometry.getAttribute("skinWeight");
            if (skinWeight == null) return;

            var count:int = skinWeight.count;
            var array:Vector.<Number> = skinWeight.array;

            for (var i:int = 0; i < count; i++)
            {
                var o:int = i * 4;
                var s:Number = array[o] + array[o + 1] + array[o + 2] + array[o + 3];
                if (s != 0)
                {
                    var inv:Number = 1 / s;
                    array[o] = array[o] * inv;
                    array[o + 1] = array[o + 1] * inv;
                    array[o + 2] = array[o + 2] * inv;
                    array[o + 3] = array[o + 3] * inv;
                }
            }

            skinWeight.needsUpdate = true;
        }

        // SkinnedMesh.js:applyBoneTransform -- the CPU reference implementation,
        // kept public because the M12 probe asserts against it directly.
        public function applyBoneTransform(index:int, target:Vector3):Vector3
        {
            var geometry:BufferGeometry = this.geometry;
            var skinIndex:BufferAttribute = geometry.getAttribute("skinIndex");
            var skinWeight:BufferAttribute = geometry.getAttribute("skinWeight");

            if (skinIndex == null || skinWeight == null || this.skeleton == null)
            {
                return target;
            }

            var bi0:int = int(skinIndex.array[index * 4]);
            var bi1:int = int(skinIndex.array[index * 4 + 1]);
            var bi2:int = int(skinIndex.array[index * 4 + 2]);
            var bi3:int = int(skinIndex.array[index * 4 + 3]);

            var w0:Number = skinWeight.array[index * 4];
            var w1:Number = skinWeight.array[index * 4 + 1];
            var w2:Number = skinWeight.array[index * 4 + 2];
            var w3:Number = skinWeight.array[index * 4 + 3];

            var base:Vector3 = target.clone();
            base.applyMatrix4(this.bindMatrix);

            var out:Vector3 = new Vector3(0, 0, 0);
            var scratch:Vector3 = new Vector3();

            this._accumulateBone(out, base, scratch, bi0, w0);
            this._accumulateBone(out, base, scratch, bi1, w1);
            this._accumulateBone(out, base, scratch, bi2, w2);
            this._accumulateBone(out, base, scratch, bi3, w3);

            out.applyMatrix4(this.bindMatrixInverse);
            target.copy(out);

            return target;
        }

        private function _accumulateBone(out:Vector3, base:Vector3, scratch:Vector3,
                                         boneIndex:int, weight:Number):void
        {
            if (weight == 0) return;
            if (boneIndex < 0 || boneIndex >= this.skeleton.bones.length) return;

            var matrix:Matrix4 = this._scratchMatrix;
            matrix.multiplyMatrices(this.skeleton.bones[boneIndex].matrixWorld,
                                    this.skeleton.boneInverses[boneIndex]);

            scratch.copy(base);
            scratch.applyMatrix4(matrix);
            out.addScaledVector(scratch, weight);
        }

        // ------------------------------------------------------------------
        // Rendering hook: morph, then skin, then write back to the attributes.
        // ------------------------------------------------------------------

        public override function updateDeform(frameId:int):void
        {
            if (frameId == this._deformFrame) return;
            this._deformFrame = frameId;

            var geometry:BufferGeometry = this.geometry;
            if (geometry == null) return;

            var position:BufferAttribute = geometry.getAttribute("position");
            if (position == null) return;

            var skinIndex:BufferAttribute = geometry.getAttribute("skinIndex");
            var skinWeight:BufferAttribute = geometry.getAttribute("skinWeight");
            if (skinIndex == null || skinWeight == null || this.skeleton == null)
            {
                super.updateDeform(frameId);
                return;
            }

            this.captureBindPose();

            // --- stage 1: morph (or plain bind pose) into the scratch buffer ---
            if (this.hasMorph())
            {
                this.writeMorphedAttributes(this._deformPosition, this._deformNormal);
            }
            else
            {
                var nValues:int = this._basePosition.length;
                for (var c:int = 0; c < nValues; c++)
                {
                    this._deformPosition[c] = this._basePosition[c];
                    if (this._deformNormal != null && this._baseNormal != null)
                    {
                        this._deformNormal[c] = this._baseNormal[c];
                    }
                }
            }

            // --- stage 2: skin ---
            this.skeleton.update();
            this._skinIntoAttributes(geometry, position, skinIndex, skinWeight);

            position.needsUpdate = true;

            var normal:BufferAttribute = geometry.getAttribute("normal");
            if (normal != null) normal.needsUpdate = true;
        }

        private function _skinIntoAttributes(geometry:BufferGeometry, position:BufferAttribute,
                                             skinIndex:BufferAttribute, skinWeight:BufferAttribute):void
        {
            var boneMatrices:Vector.<Number> = this.skeleton.boneMatrices;
            var nBones:int = this.skeleton.bones.length;

            var bind:Vector.<Number> = this.bindMatrix.elements;
            var bindInv:Vector.<Number> = this.bindMatrixInverse.elements;

            var srcPos:Vector.<Number> = this._deformPosition;
            var srcNrm:Vector.<Number> = this._deformNormal;
            var dstPos:Vector.<Number> = position.array;

            var normal:BufferAttribute = geometry.getAttribute("normal");
            var dstNrm:Vector.<Number> = (normal != null) ? normal.array : null;
            if (dstNrm != null && srcNrm == null) dstNrm = null;

            var indexArray:Vector.<Number> = skinIndex.array;
            var weightArray:Vector.<Number> = skinWeight.array;

            var count:int = position.count;

            var b0:Number = bind[0], b4:Number = bind[4], b8:Number = bind[8], b12:Number = bind[12];
            var b1:Number = bind[1], b5:Number = bind[5], b9:Number = bind[9], b13:Number = bind[13];
            var b2:Number = bind[2], b6:Number = bind[6], b10:Number = bind[10], b14:Number = bind[14];

            var i0:Number = bindInv[0], i4:Number = bindInv[4], i8:Number = bindInv[8], i12:Number = bindInv[12];
            var i1:Number = bindInv[1], i5:Number = bindInv[5], i9:Number = bindInv[9], i13:Number = bindInv[13];
            var i2:Number = bindInv[2], i6:Number = bindInv[6], i10:Number = bindInv[10], i14:Number = bindInv[14];

            for (var v:int = 0; v < count; v++)
            {
                var p3:int = v * 3;
                var w4:int = v * 4;

                var px:Number = srcPos[p3];
                var py:Number = srcPos[p3 + 1];
                var pz:Number = srcPos[p3 + 2];

                // bind-space position
                var bx:Number = b0 * px + b4 * py + b8 * pz + b12;
                var by:Number = b1 * px + b5 * py + b9 * pz + b13;
                var bz:Number = b2 * px + b6 * py + b10 * pz + b14;

                var sx:Number = 0;
                var sy:Number = 0;
                var sz:Number = 0;

                var nx:Number = 0;
                var ny:Number = 0;
                var nz:Number = 0;

                var hasNormal:Boolean = (dstNrm != null);
                var tx:Number = 0;
                var ty:Number = 0;
                var tz:Number = 0;
                if (hasNormal)
                {
                    tx = srcNrm[p3];
                    ty = srcNrm[p3 + 1];
                    tz = srcNrm[p3 + 2];
                }

                for (var k:int = 0; k < 4; k++)
                {
                    var weight:Number = weightArray[w4 + k];
                    if (weight == 0) continue;

                    var bone:int = int(indexArray[w4 + k]);
                    if (bone < 0 || bone >= nBones) continue;

                    var o:int = bone * 16;
                    var m0:Number = boneMatrices[o];
                    var m4:Number = boneMatrices[o + 4];
                    var m8:Number = boneMatrices[o + 8];
                    var m12:Number = boneMatrices[o + 12];
                    var m1:Number = boneMatrices[o + 1];
                    var m5:Number = boneMatrices[o + 5];
                    var m9:Number = boneMatrices[o + 9];
                    var m13:Number = boneMatrices[o + 13];
                    var m2:Number = boneMatrices[o + 2];
                    var m6:Number = boneMatrices[o + 6];
                    var m10:Number = boneMatrices[o + 10];
                    var m14:Number = boneMatrices[o + 14];

                    sx += weight * (m0 * bx + m4 * by + m8 * bz + m12);
                    sy += weight * (m1 * bx + m5 * by + m9 * bz + m13);
                    sz += weight * (m2 * bx + m6 * by + m10 * bz + m14);

                    if (hasNormal)
                    {
                        // mat3 of the same skinMatrix, applied to a direction
                        nx += weight * (m0 * tx + m4 * ty + m8 * tz);
                        ny += weight * (m1 * tx + m5 * ty + m9 * tz);
                        nz += weight * (m2 * tx + m6 * ty + m10 * tz);
                    }
                }

                // back to mesh-local space
                dstPos[p3] = i0 * sx + i4 * sy + i8 * sz + i12;
                dstPos[p3 + 1] = i1 * sx + i5 * sy + i9 * sz + i13;
                dstPos[p3 + 2] = i2 * sx + i6 * sy + i10 * sz + i14;

                if (hasNormal)
                {
                    dstNrm[p3] = i0 * nx + i4 * ny + i8 * nz;
                    dstNrm[p3 + 1] = i1 * nx + i5 * ny + i9 * nz;
                    dstNrm[p3 + 2] = i2 * nx + i6 * ny + i10 * nz;
                }
            }
        }
    }
}