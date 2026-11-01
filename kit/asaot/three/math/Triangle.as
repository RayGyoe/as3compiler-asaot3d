// asaot.three.math.Triangle -- the two static triangle helpers picking needs.
//
// Borrows src/math/Triangle.js (r187): getNormal (`:66`), getBarycoord (`:94`) and
// isFrontFacing (`:223`). The instance half of that class (set/clone/copy/
// getArea/getMidpoint/containsPoint/...) is NOT ported -- M14 does not need it,
// and claiming an API we never exercise is worse than not having it (D97).
//
// All three are STATIC and allocation-free apart from module-level scratch, so
// Mesh.raycast can call them once per candidate triangle without growing the
// arena (AGENTS.md memory rule).
package asaot.three.math
{
    public class Triangle
    {
        private static var _v0:Vector3 = new Vector3();
        private static var _v1:Vector3 = new Vector3();
        private static var _v2:Vector3 = new Vector3();

        // Triangle.js:66 -- normal of (a-b) x (c-b). A degenerate triangle has no
        // normal and yields (0,0,0) rather than a NaN unit vector.
        public static function getNormal(a:Vector3, b:Vector3, c:Vector3, target:Vector3):Vector3
        {
            target.subVectors(c, b);
            Triangle._v0.subVectors(a, b);
            target.cross(Triangle._v0);

            var lenSq:Number = target.lengthSq();
            if (lenSq > 0) return target.multiplyScalar(1 / Math.sqrt(lenSq));
            return target.set(0, 0, 0);
        }

        // Triangle.js:94 -- barycentric weights of `point` w.r.t. the triangle,
        // stored as (1-u-v, v, u). Returns null for a collinear/singular triangle
        // (denominator exactly 0), which is the same "no valid coordinates" answer
        // three.js gives.
        public static function getBarycoord(point:Vector3, a:Vector3, b:Vector3, c:Vector3,
                                            target:Vector3):Vector3
        {
            Triangle._v0.subVectors(c, a);
            Triangle._v1.subVectors(b, a);
            Triangle._v2.subVectors(point, a);

            var dot00:Number = Triangle._v0.dot(Triangle._v0);
            var dot01:Number = Triangle._v0.dot(Triangle._v1);
            var dot02:Number = Triangle._v0.dot(Triangle._v2);
            var dot11:Number = Triangle._v1.dot(Triangle._v1);
            var dot12:Number = Triangle._v1.dot(Triangle._v2);

            var denom:Number = dot00 * dot11 - dot01 * dot01;
            if (denom == 0)
            {
                target.set(0, 0, 0);
                return null;
            }

            var invDenom:Number = 1 / denom;
            var u:Number = (dot11 * dot02 - dot01 * dot12) * invDenom;
            var v:Number = (dot00 * dot12 - dot01 * dot02) * invDenom;
            return target.set(1 - u - v, v, u);
        }

        // Triangle.js:223 -- strictly front facing w.r.t. `direction`.
        public static function isFrontFacing(a:Vector3, b:Vector3, c:Vector3, direction:Vector3):Boolean
        {
            Triangle._v0.subVectors(c, b);
            Triangle._v1.subVectors(a, b);
            return Triangle._v0.cross(Triangle._v1).dot(direction) < 0;
        }
    }
}