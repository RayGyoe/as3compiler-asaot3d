// asaot.three.helpers.SkeletonHelper -- draws a bone hierarchy as line segments.
//
// Borrows src/helpers/SkeletonHelper.js (r187): one line per bone whose PARENT is
// also a bone, both endpoints taken from the bones' WORLD matrices and pushed
// back into the ROOT's local space (that is what makes the helper follow a model
// that is itself moved/scaled around the scene); `matrix` aliases
// `root.matrixWorld` with matrixAutoUpdate = false, so the helper inherits the
// root's transform without a second copy of it; setColors() repaints the
// per-segment gradient (blue at the bone, green at its parent in three.js).
//
// TWO PORT-SPECIFIC POINTS:
//
//   D149  The colour attribute only renders because M26 added the per-vertex
//         colour variant to the line program (va3 -> v1, `diffuseColor *= vColor`).
//         Stage3D has no LINES primitive at all -- every segment is expanded into
//         a screen-space quad by the vertex program (§16) -- so "vertex colour on
//         a line" is a real feature here, not a shader freebie.
//
//   D150  The bounding sphere is recomputed on every update. three.js computes it
//         once, so a helper whose bones move can be wrongly frustum-culled there;
//         our cull test would do the same. Bone counts are tens, not thousands, so
//         recomputing is cheap and keeps culling honest. Recorded in §29.
package asaot.three.helpers
{
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Object3D;
    import asaot.three.materials.LineBasicMaterial;
    import asaot.three.math.Color;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector3;
    import asaot.three.objects.LineSegments;

    public class SkeletonHelper extends LineSegments
    {
        public var isSkeletonHelper:Boolean = true;
        public var type:String = "SkeletonHelper";

        // The object being visualised, and the bones found under it (the root
        // itself included when it is a Bone, exactly like getBoneList()).
        public var root:Object3D;
        public var bones:Vector.<Object3D>;

        // Preallocated scratch. three.js uses module-level singletons; AS3 has no
        // module scope, so they live on the instance -- still zero allocation per
        // frame, which is the rule that actually matters (AGENTS.md memory
        // red-line).
        private var _vector:Vector3 = new Vector3();
        private var _boneMatrix:Matrix4 = new Matrix4();
        private var _matrixWorldInv:Matrix4 = new Matrix4();

        public function SkeletonHelper(object:Object3D)
        {
            super();

            var list:Vector.<Object3D> = new Vector.<Object3D>();
            SkeletonHelper.collectBones(object, list);
            this.bones = list;
            this.root = object;

            this.geometry = SkeletonHelper.buildGeometry(list);
            this.material = SkeletonHelper.buildMaterial();

            // Inherit the root's world transform by ALIASING its matrix (three.js
            // does the same); with matrixAutoUpdate off, updateMatrixWorld copies
            // this matrix into matrixWorld instead of recomposing from
            // position/quaternion/scale.
            this.matrix = object.matrixWorld;
            this.matrixAutoUpdate = false;

            this.setColors(new Color(0x0000ff), new Color(0x00ff00));
        }

        // three.js getBoneList(): the object itself counts when it is a Bone, then
        // every descendant. Order is the depth-first traversal order, and it is
        // what makes the segment list stable frame to frame.
        public static function collectBones(object:Object3D, out:Vector.<Object3D>):void
        {
            if (object == null) return;
            if (object.isBone) out.push(object);
            var children:Vector.<Object3D> = object.children;
            var i:int;
            for (i = 0; i < children.length; i++) SkeletonHelper.collectBones(children[i], out);
        }

        // Number of SEGMENTS: one per bone whose parent is also a bone.
        public static function segmentCount(bones:Vector.<Object3D>):int
        {
            var n:int = 0;
            var i:int;
            for (i = 0; i < bones.length; i++)
            {
                var parent:Object3D = bones[i].parent;
                if (parent != null && parent.isBone) n++;
            }
            return n;
        }

        private static function buildGeometry(bones:Vector.<Object3D>):BufferGeometry
        {
            var segments:int = SkeletonHelper.segmentCount(bones);
            var geometry:BufferGeometry = new BufferGeometry();
            // All zeroes: the first updateMatrixWorld fills the real positions.
            var positions:Vector.<Number> = new Vector.<Number>(segments * 2 * 3, true);
            var colors:Vector.<Number> = new Vector.<Number>(segments * 2 * 3, true);
            geometry.setAttribute("position", new BufferAttribute(positions, 3));
            geometry.setAttribute("color", new BufferAttribute(colors, 3));
            return geometry;
        }

        // depthTest/depthWrite off + transparent + toneMapped off are exactly
        // three.js's helper material: the skeleton must be readable THROUGH the
        // character, and its authored colours must not be re-graded by ACES.
        private static function buildMaterial():LineBasicMaterial
        {
            var material:LineBasicMaterial = new LineBasicMaterial(0xffffff);
            material.vertexColors = true;
            material.depthTest = false;
            material.depthWrite = false;
            material.toneMapped = false;
            material.transparent = true;
            return material;
        }

        // Rewrites the per-segment gradient: colour1 at the bone, colour2 at its
        // parent (SkeletonHelper.js setColors).
        public function setColors(color1:Color, color2:Color):SkeletonHelper
        {
            var colorAttribute:BufferAttribute = this.geometry.getAttribute('color');
            if (colorAttribute == null) return this;
            var i:int = 0;
            while (i < colorAttribute.count)
            {
                colorAttribute.setXYZ(i, color1.r, color1.g, color1.b);
                if (i + 1 < colorAttribute.count)
                {
                    colorAttribute.setXYZ(i + 1, color2.r, color2.g, color2.b);
                }
                i += 2;
            }
            colorAttribute.needsUpdate = true;
            return this;
        }

        // Positions first, then the normal matrix bookkeeping. The ORDER matters:
        // three.js reads the bones' matrixWorld values that this frame's scene
        // traversal has already produced for the ROOT subtree, so the helper must
        // be added AFTER the model in the scene to stay in step.
        override public function updateMatrixWorld(force:Boolean = false):void
        {
            this._update();
            super.updateMatrixWorld(force);
        }

        private function _update():void
        {
            var bones:Vector.<Object3D> = this.bones;
            var geometry:BufferGeometry = this.geometry;
            if (geometry == null) return;

            var position:BufferAttribute = geometry.getAttribute('position');
            if (position == null) return;

            this._matrixWorldInv.copy(this.root.matrixWorld);
            this._matrixWorldInv.invert();

            var p:Vector.<Number> = position.array;
            var j:int = 0;
            var i:int;
            for (i = 0; i < bones.length; i++)
            {
                var bone:Object3D = bones[i];
                var parent:Object3D = bone.parent;
                if (parent == null || !parent.isBone) continue;

                this._boneMatrix.multiplyMatrices(this._matrixWorldInv, bone.matrixWorld);
                this._vector.setFromMatrixPosition(this._boneMatrix);
                p[j * 3 + 0] = this._vector.x;
                p[j * 3 + 1] = this._vector.y;
                p[j * 3 + 2] = this._vector.z;

                this._boneMatrix.multiplyMatrices(this._matrixWorldInv, parent.matrixWorld);
                this._vector.setFromMatrixPosition(this._boneMatrix);
                p[(j + 1) * 3 + 0] = this._vector.x;
                p[(j + 1) * 3 + 1] = this._vector.y;
                p[(j + 1) * 3 + 2] = this._vector.z;

                j += 2;
            }

            // Bumps the version the seam's line buffers watch, so the expanded
            // quads are rebuilt from these positions on the next draw.
            position.needsUpdate = true;

            // D150: keep the cull sphere in step with the bones.
            geometry.computeBoundingSphere();
        }
    }
}