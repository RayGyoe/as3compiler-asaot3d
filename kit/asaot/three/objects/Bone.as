// asaot.three.objects.Bone -- a joint in a skeleton.
//
// Borrows src/objects/Bone.js (r187): Object3D with `isBone = true`. The class is
// a marker only -- all of the skinning math lives in Skeleton (bone matrix
// palette) and SkinnedMesh (vertex transform).
package asaot.three.objects
{
    import asaot.three.core.Object3D;

    public class Bone extends Object3D
    {
        public var type:String = "Bone";

        public function Bone()
        {
            super();
            // M26: the flag moved to Object3D so SkeletonHelper can test any node
            // (three.js reads `object.isBone` and gets undefined elsewhere).
            this.isBone = true;
        }
    }
}