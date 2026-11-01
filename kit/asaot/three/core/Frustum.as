// asaot.three.core.Frustum -- six-plane camera frustum, three.js style.
//
// Borrows src/math/Frustum.js (r187): six planes (left/right/top/bottom/far/near)
// extracted from a projection matrix by Gribb-Hartmann row addition, plus the
// conservative intersectsSphere / intersectsBox / containsPoint tests and
// intersectsObject (bounding-sphere test against object.matrixWorld).
//
// DIVERGENCES (three-api-design.md §16):
//   D55  `setFromProjectionMatrix(m, coordinateSystem)` defaults to
//        ZeroToOneCoordinateSystem, NOT WebGLCoordinateSystem. asaot3d's
//        Matrix4.makePerspective/makeOrthographic already emit a [0,1] depth
//        range (the Stage3D/Metal convention), so the near plane is row2 alone
//        (`me2, me6, me10, me14`) rather than row3 + row2. Passing
//        WebGLCoordinateSystem would put the near plane at the wrong depth.
//   D56  `planes` is a Vector.<Plane> (D-index: JS arrays -> Vector).
//   D57  `intersectsSprite` and `reversedDepth` are not ported (no Sprite in
//        this engine; reversed depth is not a backend it targets).
package asaot.three.core
{
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector3;
    import asaot.three.objects.Mesh;

    public class Frustum
    {
        // Coordinate-system selects the near-plane extraction (src/constants.js:1648,1656).
        public static const WebGLCoordinateSystem:int = 2000;      // NDC z in [-1, 1]
        public static const ZeroToOneCoordinateSystem:int = 2001;  // NDC z in [0, 1] (Metal)

        public var planes:Vector.<Plane>;

        // Scratch reused by intersectsObject/intersectsBox (three.js uses module
        // locals _sphere/_vector; AS3 keeps them as fields so the per-frame
        // cull loop allocates nothing).
        private var _sphere:Sphere = new Sphere();
        private var _vector:Vector3 = new Vector3();

        public function Frustum()
        {
            this.planes = new Vector.<Plane>(6, true);
            for (var i:int = 0; i < 6; i++) this.planes[i] = new Plane();
        }

        // three.js Frustum.js:111. The six planes are read straight out of the
        // projection matrix's rows: for a clip-space condition `a·x <= b`, the
        // plane is the row difference. Rows here are `me[3],me[7],me[11],me[15]`
        // (row 3, the w row) minus/plus rows 0/1/2.
        public function setFromProjectionMatrix(m:Matrix4, coordinateSystem:int = Frustum.ZeroToOneCoordinateSystem):Frustum
        {
            var planes:Vector.<Plane> = this.planes;
            var me:Vector.<Number> = m.elements;
            var me0:Number = me[0], me1:Number = me[1], me2:Number = me[2], me3:Number = me[3];
            var me4:Number = me[4], me5:Number = me[5], me6:Number = me[6], me7:Number = me[7];
            var me8:Number = me[8], me9:Number = me[9], me10:Number = me[10], me11:Number = me[11];
            var me12:Number = me[12], me13:Number = me[13], me14:Number = me[14], me15:Number = me[15];

            // left  = row3 - row0   (x >= -w)
            planes[0].setComponents(me3 - me0, me7 - me4, me11 - me8, me15 - me12).normalize();
            // right = row3 + row0   (x <=  w)
            planes[1].setComponents(me3 + me0, me7 + me4, me11 + me8, me15 + me12).normalize();
            // top   = row3 + row1
            planes[2].setComponents(me3 + me1, me7 + me5, me11 + me9, me15 + me13).normalize();
            // bottom= row3 - row1
            planes[3].setComponents(me3 - me1, me7 - me5, me11 - me9, me15 - me13).normalize();
            // far   = row3 - row2   (z <= w)
            planes[4].setComponents(me3 - me2, me7 - me6, me11 - me10, me15 - me14).normalize();

            if (coordinateSystem == Frustum.WebGLCoordinateSystem)
            {
                // near = row3 + row2 (z >= -w)
                planes[5].setComponents(me3 + me2, me7 + me6, me11 + me10, me15 + me14).normalize();
            }
            else
            {
                // near = row2 (z >= 0)  -- Metal/D3D [0,1] depth (D55)
                planes[5].setComponents(me2, me6, me10, me14).normalize();
            }

            return this;
        }

        // three.js Frustum.js:206 -- conservative sphere test. A sphere is
        // outside only when a SINGLE plane rejects it, so the result can be a
        // false positive but never a false negative: safe for culling.
        public function intersectsSphere(sphere:Sphere):Boolean
        {
            var planes:Vector.<Plane> = this.planes;
            var center:Vector3 = sphere.center;
            var negRadius:Number = -sphere.radius;
            for (var i:int = 0; i < 6; i++)
            {
                if (planes[i].distanceToPoint(center) < negRadius) return false;
            }
            return true;
        }

        // three.js Frustum.js:245.
        public function intersectsBox(box:Box3):Boolean
        {
            var planes:Vector.<Plane> = this.planes;
            for (var i:int = 0; i < 6; i++)
            {
                var plane:Plane = planes[i];
                _vector.x = (plane.normal.x > 0) ? box.max.x : box.min.x;
                _vector.y = (plane.normal.y > 0) ? box.max.y : box.min.y;
                _vector.z = (plane.normal.z > 0) ? box.max.z : box.min.z;
                if (plane.distanceToPoint(_vector) < 0) return false;
            }
            return true;
        }

        // three.js Frustum.js:285.
        public function containsPoint(point:Vector3):Boolean
        {
            var planes:Vector.<Plane> = this.planes;
            for (var i:int = 0; i < 6; i++)
            {
                if (planes[i].distanceToPoint(point) < 0) return false;
            }
            return true;
        }

        // three.js Frustum.js:145 -- test a Mesh's bounding sphere in world
        // space. Returns true for a mesh with no geometry (nothing to reject on)
        // so a caller that misuses the test never loses geometry.
        public function intersectsObject(object:Mesh):Boolean
        {
            var geometry:BufferGeometry = object.geometry;
            if (geometry == null) return true;
            if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
            var bs:Sphere = geometry.boundingSphere;
            if (bs == null || bs.isEmpty()) return true;

            _sphere.copy(bs).applyMatrix4(object.matrixWorld);
            return this.intersectsSphere(_sphere);
        }

        // three.js Frustum.js:129.
        public function copy(frustum:Frustum):Frustum
        {
            for (var i:int = 0; i < 6; i++) this.planes[i].copy(frustum.planes[i]);
            return this;
        }
    }
}