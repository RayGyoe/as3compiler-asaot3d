// asaot.three.core.Sphere -- bounding sphere, three.js style.
//
// Borrows the design of three.js src/math/Sphere.js (r187): center + radius, with
// radius < 0 meaning "empty". Placed in core/ to sit alongside Box3 (its only
// consumer in M1 was BufferGeometry.computeBoundingSphere; M11 adds
// Frustum.intersectsObject, which grows the sphere by the object's world
// transform).
package asaot.three.core
{
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector3;

    public class Sphere
    {
        public var center:Vector3;
        public var radius:Number;

        public function Sphere(center:Vector3 = null, radius:Number = -1)
        {
            this.center = (center != null) ? center : new Vector3();
            this.radius = radius;
        }

        // three.js Sphere.js:54.
        public function set(center:Vector3, radius:Number):Sphere
        {
            this.center.copy(center);
            this.radius = radius;
            return this;
        }

        // three.js Sphere.js:124 -- empty iff radius < 0.
        public function isEmpty():Boolean
        {
            return this.radius < 0;
        }

        // three.js Sphere.js:135.
        public function makeEmpty():Sphere
        {
            this.center.set(0, 0, 0);
            this.radius = -1;
            return this;
        }

        // three.js Sphere.js:71.
        public function copy(sphere:Sphere):Sphere
        {
            this.center.copy(sphere.center);
            this.radius = sphere.radius;
            return this;
        }

        // three.js Sphere.js:containsPoint -- surface counts as inside.
        public function containsPoint(point:Vector3):Boolean
        {
            return point.distanceToSquared(this.center) <= (this.radius * this.radius);
        }

        // three.js Sphere.js:79 -- transform the center and grow the radius by
        // the matrix's largest axis scale. An affine transform can only scale a
        // sphere up along some axis, so a conservative (never-smaller) radius is
        // exactly what culling needs: it must never produce a false negative.
        public function applyMatrix4(matrix:Matrix4):Sphere
        {
            this.center.applyMatrix4(matrix);
            this.radius = this.radius * matrix.getMaxScaleOnAxis();
            return this;
        }
    }
}
