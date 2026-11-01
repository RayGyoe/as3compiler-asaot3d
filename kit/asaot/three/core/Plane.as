// asaot.three.core.Plane -- infinite plane in Hessian normal form, three.js style.
//
// Borrows src/math/Plane.js (r187): `normal` + signed `constant`, with
// distanceToPoint / intersectsBox / intersectsSphere. Only the subset M11 needs
// (frustum planes + culling tests) is ported; the line/projection helpers
// (projectPoint, intersectLine, applyMatrix4, coplanarPoint) are not.
//
// Placed in core/ (not math/) for the same reason as Box3: intersectsBox and
// intersectsSphere take Box3/Sphere, which live here -- putting Plane in math/
// would create a math->core reverse package dependency.
package asaot.three.core
{
    import asaot.three.math.Vector3;

    public class Plane
    {
        public var normal:Vector3;
        public var constant:Number;

        public function Plane(normal:Vector3 = null, constant:Number = 0)
        {
            this.normal = (normal != null) ? normal : new Vector3(1, 0, 0);
            this.constant = constant;
        }

        // three.js Plane.js:56.
        public function set(normal:Vector3, constant:Number):Plane
        {
            this.normal.copy(normal);
            this.constant = constant;
            return this;
        }

        // three.js Plane.js:66 -- set the four Hessian components directly.
        // Frustum.setFromProjectionMatrix calls this then .normalize().
        public function setComponents(x:Number, y:Number, z:Number, w:Number):Plane
        {
            this.normal.set(x, y, z);
            this.constant = w;
            return this;
        }

        // three.js Plane.js:92.
        public function setFromNormalAndCoplanarPoint(normal:Vector3, point:Vector3):Plane
        {
            this.normal.copy(normal);
            this.constant = -point.dot(this.normal);
            return this;
        }

        // three.js Plane.js:129.
        public function copy(plane:Plane):Plane
        {
            this.normal.copy(plane.normal);
            this.constant = plane.constant;
            return this;
        }

        // three.js Plane.js:143 -- normalize normal and scale constant with it.
        // The renderer calls this on every plane extracted from a projection
        // matrix (Frustum.setFromProjectionMatrix does `.normalize()` inline).
        public function normalize():Plane
        {
            var inverseNormalLength:Number = 1.0 / this.normal.length();
            this.normal.multiplyScalar(inverseNormalLength);
            this.constant *= inverseNormalLength;
            return this;
        }

        // three.js Plane.js:230.
        public function negate():Plane
        {
            this.constant *= -1;
            this.normal.negate();
            return this;
        }

        // three.js Plane.js:175 -- signed distance; positive = normal side.
        public function distanceToPoint(point:Vector3):Number
        {
            return this.normal.dot(point) + this.constant;
        }

        // three.js Plane.js:283 -- sphere-vs-plane (sphere is OUTSIDE when the
        // center is farther than the radius on the negative side).
        public function intersectsSphere(sphere:Sphere):Boolean
        {
            return this.distanceToPoint(sphere.center) <= sphere.radius;
        }

        // three.js Plane.js:271 -- box-vs-plane via the "corner at max distance"
        // trick: pick, per axis, the box corner that lies farthest along the
        // plane normal. If even that corner is behind the plane, the whole box
        // is outside.
        public function intersectsBox(box:Box3):Boolean
        {
            var x:Number = (this.normal.x > 0) ? box.max.x : box.min.x;
            var y:Number = (this.normal.y > 0) ? box.max.y : box.min.y;
            var z:Number = (this.normal.z > 0) ? box.max.z : box.min.z;
            return (this.normal.x * x + this.normal.y * y + this.normal.z * z + this.constant) >= 0;
        }
    }
}