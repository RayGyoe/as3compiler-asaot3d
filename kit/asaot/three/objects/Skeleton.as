// asaot.three.objects.Skeleton -- a set of bones plus their bind-pose inverses.
//
// Borrows src/objects/Skeleton.js (r187):
//   * bones / boneInverses / boneMatrices (a flat row-major-free 4x4-per-bone
//     palette, same element order as Matrix4.elements);
//   * init() -> calculateInverses() when no inverses are supplied;
//   * update(): boneMatrices[b] = bone.matrixWorld * boneInverses[b] -- the
//     "offset from bind pose" that skinning multiplies into each vertex;
//   * getBoneByName() and pose() (reset every bone to its bind pose).
//
// DIVERGENCES:
//   D85  `boneTexture`/`computeBoneTexture()` is not borrowed: Stage3D has no
//        float texture format, so the palette cannot be uploaded as a texture
//        (and AGAL1 has no relative constant addressing to index a vc array).
//        See D84 for the CPU skinning consequence.
//   D86  boneMatrices is a Vector.<Number>, not a Float32Array (D67).
package asaot.three.objects
{
    import asaot.three.core.Object3D;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;

    public class Skeleton
    {
        public var uuid:String;
        public var bones:Vector.<Object3D>;
        public var boneInverses:Vector.<Matrix4>;
        public var boneMatrices:Vector.<Number>;

        public function Skeleton(bones:Vector.<Object3D> = null, boneInverses:Vector.<Matrix4> = null)
        {
            this.bones = (bones != null) ? bones : new Vector.<Object3D>();
            this.boneInverses = (boneInverses != null) ? boneInverses : new Vector.<Matrix4>();
            this.init();
        }

        public function init():void
        {
            var bones:Vector.<Object3D> = this.bones;
            var boneInverses:Vector.<Matrix4> = this.boneInverses;

            this.boneMatrices = new Vector.<Number>(bones.length * 16, true);

            if (boneInverses.length == 0)
            {
                this.calculateInverses();
            }
            else if (bones.length != boneInverses.length)
            {
                // Skeleton.js: "Number of inverse bone matrices does not match
                // amount of bones" -- fall back to identity so skinning degrades
                // to "follow the bone's world transform" instead of NaN.
                this.boneInverses = new Vector.<Matrix4>(bones.length, true);
                for (var i:int = 0; i < bones.length; i++) this.boneInverses[i] = new Matrix4();
            }
        }

        public function calculateInverses():void
        {
            var bones:Vector.<Object3D> = this.bones;
            var n:int = bones.length;

            this.boneInverses = new Vector.<Matrix4>(n, true);
            for (var i:int = 0; i < n; i++)
            {
                var inverse:Matrix4 = new Matrix4();
                if (bones[i] != null) inverse.copy(bones[i].matrixWorld);
                inverse.invert();
                this.boneInverses[i] = inverse;
            }
        }

        public function pose():void
        {
            var bones:Vector.<Object3D> = this.bones;
            var boneInverses:Vector.<Matrix4> = this.boneInverses;

            var position:Vector3 = new Vector3();
            var quaternion:Quaternion = new Quaternion();
            var scale:Vector3 = new Vector3();

            // pass 1: recover the bind-time world matrices
            for (var i:int = 0; i < bones.length; i++)
            {
                var bone:Object3D = bones[i];
                if (bone == null) continue;
                bone.matrixWorld.copy(boneInverses[i]).invert();
            }

            // pass 2: derive each bone's LOCAL matrix from its parent's bind-time
            // world matrix. Decomposing matrixWorld directly (as an earlier
            // revision did) is only right for root bones: a child bone would get
            // its parent's transform baked into its local TRS.
            for (var k:int = 0; k < bones.length; k++)
            {
                var child:Object3D = bones[k];
                if (child == null) continue;

                var parent:Object3D = child.parent;
                if (parent != null && parent is Bone)
                {
                    child.matrix.copy(parent.matrixWorld).invert();
                    child.matrix.multiply(child.matrixWorld);
                }
                else
                {
                    child.matrix.copy(child.matrixWorld);
                }

                child.matrix.decompose(child.position, child.quaternion, child.scale);
                child.matrixWorldNeedsUpdate = true;
            }
        }

        public function update():void
        {
            var bones:Vector.<Object3D> = this.bones;
            var boneInverses:Vector.<Matrix4> = this.boneInverses;
            var boneMatrices:Vector.<Number> = this.boneMatrices;

            if (boneMatrices == null) return;

            var offset:Matrix4 = new Matrix4();

            for (var i:int = 0; i < bones.length; i++)
            {
                var bone:Object3D = bones[i];

                if (bone != null)
                {
                    offset.multiplyMatrices(bone.matrixWorld, boneInverses[i]);
                }
                else
                {
                    offset.identity();
                }

                // three.js: Matrix4.toArray( boneMatrices, i * 16 )
                offset.toArray(boneMatrices, i * 16);
            }
        }

        public function getBoneByName(name:String):Object3D
        {
            for (var i:int = 0; i < this.bones.length; i++)
            {
                var bone:Object3D = this.bones[i];
                if (bone != null && bone.name == name) return bone;
            }
            return null;
        }
    }
}