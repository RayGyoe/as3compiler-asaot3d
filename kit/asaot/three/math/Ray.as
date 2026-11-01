// asaot.three.math.Ray -- origin + unit direction, three.js style.
//
// Borrows src/math/Ray.js (r187): the intersection helpers Raycaster/Mesh.raycast
// need (at/recast/applyMatrix4, distanceSqToPoint, intersectSphere/Plane/Box) and
// the WATERTIGHT ray/triangle test of Woop/Benthin/Wald, JCGT 2(1) 2013, which is
// r187's `intersectTriangle` (Ray.js:538). The watertight form matters here: the
// projection axis and the shear are chosen so a ray hitting a shared edge
// evaluates the edge function identically for both adjacent triangles, so a
// picking ray can never fall through the seam between two coplanar faces and
// report "nothing under the cursor" (the classic barycentric-sign gap).
//
// DIVERGENCES (three-api-design.md §19):
//   D94  no `distanceSqToSegment`/`intersectsPlane` -- M14 has no line/points
//        picking, so the segment path is not ported (registered, not silently
//        dropped: LineSegments.raycast is simply absent).
//   D95  `target` arguments are required (not optional). AS3 has no default
//        `undefined` object, and allocating one per intersection would be an
//        arena leak in the picking hot path.
package asaot.three.math
{
    import asaot.three.core.Box3;
    import asaot.three.core.Plane;
    import asaot.three.core.Sphere;

    public class Ray
    {
        public var origin:Vector3;
        public var direction:Vector3;

        // Module-level scratch (three.js uses module-scoped temporaries too, for
        // the same reason: these calls run once per triangle).
        private static var _vector:Vector3 = new Vector3();

        public function Ray(origin:Vector3 = null, direction:Vector3 = null)
        {
            this.origin = (origin != null) ? origin : new Vector3();
            this.direction = (direction != null) ? direction : new Vector3(0, 0, -1);
        }

        public function set(origin:Vector3, direction:Vector3):Ray
        {
            this.origin.copy(origin);
            this.direction.copy(direction);
            return this;
        }

        public function copy(ray:Ray):Ray
        {
            this.origin.copy(ray.origin);
            this.direction.copy(ray.direction);
            return this;
        }

        public function clone():Ray
        {
            return new Ray().copy(this);
        }

        // Ray.js:78 -- the point `t` units along the ray, written into `target`.
        public function at(t:Number, target:Vector3):Vector3
        {
            return target.copy(this.origin).addScaledVector(this.direction, t);
        }

        // Ray.js:95 -- aim the ray at a world-space point.
        public function lookAt(v:Vector3):Ray
        {
            this.direction.copy(v).sub(this.origin).normalize();
            return this;
        }

        // Ray.js:104 -- slide the origin `t` units along the ray. Mesh.raycast
        // uses it to start the bounds test at `near` instead of the camera.
        public function recast(t:Number):Ray
        {
            this.origin.copy(this.at(t, Ray._vector));
            return this;
        }

        public function distanceToPoint(point:Vector3):Number
        {
            return Math.sqrt(this.distanceSqToPoint(point));
        }

        // Ray.js:153 -- squared distance to the closest approach. A point BEHIND
        // the origin measures to the origin itself (the ray is a half line).
        public function distanceSqToPoint(point:Vector3):Number
        {
            var directionDistance:Number = Ray._vector.subVectors(point, this.origin).dot(this.direction);
            if (directionDistance < 0) return this.origin.distanceToSquared(point);

            Ray._vector.copy(this.origin).addScaledVector(this.direction, directionDistance);
            return Ray._vector.distanceToSquared(point);
        }

        // Ray.js:307 -- the entry point in front of the origin, or the EXIT point
        // when the origin is already inside the sphere (never a point behind).
        public function intersectSphere(sphere:Sphere, target:Vector3):Vector3
        {
            if (sphere.radius < 0) return null;

            Ray._vector.subVectors(sphere.center, this.origin);
            var tca:Number = Ray._vector.dot(this.direction);
            var d2:Number = Ray._vector.dot(Ray._vector) - tca * tca;
            var radius2:Number = sphere.radius * sphere.radius;
            if (d2 > radius2) return null;

            var thc:Number = Math.sqrt(radius2 - d2);
            var t0:Number = tca - thc;
            var t1:Number = tca + thc;

            if (t1 < 0) return null;
            if (t0 < 0) return this.at(t1, target);
            return this.at(t0, target);
        }

        // Ray.js:344.
        public function intersectsSphere(sphere:Sphere):Boolean
        {
            if (sphere.radius < 0) return false;
            return this.distanceSqToPoint(sphere.center) <= (sphere.radius * sphere.radius);
        }

        // Ray.js:360 -- distance along the ray to the plane, or null. Returns 0
        // for a coplanar origin, null for a parallel miss (as three.js does; the
        // two are intentionally different).
        public function distanceToPlane(plane:Plane):Number
        {
            var denominator:Number = plane.normal.dot(this.direction);
            if (denominator == 0)
            {
                if (plane.distanceToPoint(this.origin) == 0) return 0;
                return NaN; // AS3 stand-in for three.js's `null`: NaN is not ">= 0", so callers see a miss
            }

            var t:Number = -(this.origin.dot(plane.normal) + plane.constant) / denominator;
            return (t >= 0) ? t : NaN;
        }

        public function intersectPlane(plane:Plane, target:Vector3):Vector3
        {
            var t:Number = this.distanceToPlane(plane);
            if (t != t) return null;
            return this.at(t, target);
        }

        // Ray.js:449 -- slab test; returns the entry point (or the exit point when
        // the origin is inside). Non-finite inverse components are handled by the
        // isNaN comparisons, exactly as in r187 (a direction of exactly 0 makes
        // 1/0 = Infinity and the products become +/-Infinity or NaN).
        public function intersectBox(box:Box3, target:Vector3):Vector3
        {
            var tmin:Number, tmax:Number, tymin:Number, tymax:Number, tzmin:Number, tzmax:Number;

            var invdirx:Number = 1 / this.direction.x;
            var invdiry:Number = 1 / this.direction.y;
            var invdirz:Number = 1 / this.direction.z;
            var ox:Number = this.origin.x, oy:Number = this.origin.y, oz:Number = this.origin.z;

            if (invdirx >= 0)
            {
                tmin = (box.min.x - ox) * invdirx;
                tmax = (box.max.x - ox) * invdirx;
            }
            else
            {
                tmin = (box.max.x - ox) * invdirx;
                tmax = (box.min.x - ox) * invdirx;
            }

            if (invdiry >= 0)
            {
                tymin = (box.min.y - oy) * invdiry;
                tymax = (box.max.y - oy) * invdiry;
            }
            else
            {
                tymin = (box.max.y - oy) * invdiry;
                tymax = (box.min.y - oy) * invdiry;
            }

            if ((tmin > tymax) || (tymin > tmax)) return null;
            if (tymin > tmin || tmin != tmin) tmin = tymin;
            if (tymax < tmax || tmax != tmax) tmax = tymax;

            if (invdirz >= 0)
            {
                tzmin = (box.min.z - oz) * invdirz;
                tzmax = (box.max.z - oz) * invdirz;
            }
            else
            {
                tzmin = (box.max.z - oz) * invdirz;
                tzmax = (box.min.z - oz) * invdirz;
            }

            if ((tmin > tzmax) || (tzmin > tmax)) return null;
            if (tzmin > tmin || tmin != tmin) tmin = tzmin;
            if (tzmax < tmax || tmax != tmax) tmax = tzmax;

            if (tmax < 0) return null;
            return this.at(tmin >= 0 ? tmin : tmax, target);
        }

        public function intersectsBox(box:Box3):Boolean
        {
            return this.intersectBox(box, Ray._vector) != null;
        }

        // Ray.js:538 -- watertight ray/triangle intersection (see the file header).
        // `backfaceCulling` is what Mesh.raycast derives from material.side.
        public function intersectTriangle(a:Vector3, b:Vector3, c:Vector3,
                                          backfaceCulling:Boolean, target:Vector3):Vector3
        {
            var dx:Number = this.direction.x, dy:Number = this.direction.y, dz:Number = this.direction.z;
            var ox:Number = this.origin.x, oy:Number = this.origin.y, oz:Number = this.origin.z;

            var aox:Number = a.x - ox, aoy:Number = a.y - oy, aoz:Number = a.z - oz;
            var box_:Number = b.x - ox, boy:Number = b.y - oy, boz:Number = b.z - oz;
            var cox:Number = c.x - ox, coy:Number = c.y - oy, coz:Number = c.z - oz;

            var adx:Number = Math.abs(dx), ady:Number = Math.abs(dy), adz:Number = Math.abs(dz);

            var dkx:Number, dky:Number, dkz:Number;
            var akx:Number, aky:Number, akz:Number;
            var bkx:Number, bky:Number, bkz:Number;
            var ckx:Number, cky:Number, ckz:Number;

            if (adx >= ady && adx >= adz)
            {
                dkz = dx; akz = aox; bkz = box_; ckz = cox;
                if (dx >= 0)
                {
                    dkx = dy; dky = dz;
                    akx = aoy; aky = aoz; bkx = boy; bky = boz; ckx = coy; cky = coz;
                }
                else
                {
                    dkx = dz; dky = dy;
                    akx = aoz; aky = aoy; bkx = boz; bky = boy; ckx = coz; cky = coy;
                }
            }
            else if (ady >= adz)
            {
                dkz = dy; akz = aoy; bkz = boy; ckz = coy;
                if (dy >= 0)
                {
                    dkx = dz; dky = dx;
                    akx = aoz; aky = aox; bkx = boz; bky = box_; ckx = coz; cky = cox;
                }
                else
                {
                    dkx = dx; dky = dz;
                    akx = aox; aky = aoz; bkx = box_; bky = boz; ckx = cox; cky = coz;
                }
            }
            else
            {
                dkz = dz; akz = aoz; bkz = boz; ckz = coz;
                if (dz >= 0)
                {
                    dkx = dx; dky = dy;
                    akx = aox; aky = aoy; bkx = box_; bky = boy; ckx = cox; cky = coy;
                }
                else
                {
                    dkx = dy; dky = dx;
                    akx = aoy; aky = aox; bkx = boy; bky = box_; ckx = coy; cky = cox;
                }
            }

            if (dkz == 0) return null;

            var sx:Number = dkx / dkz, sy:Number = dky / dkz, sz:Number = 1 / dkz;

            var ax:Number = akx - sx * akz, ay:Number = aky - sy * akz;
            var bx:Number = bkx - sx * bkz, by:Number = bky - sy * bkz;
            var cx:Number = ckx - sx * ckz, cy:Number = cky - sy * ckz;

            var u:Number = cx * by - cy * bx;
            var v:Number = ax * cy - ay * cx;
            var w:Number = bx * ay - by * ax;

            if (backfaceCulling)
            {
                if (u < 0 || v < 0 || w < 0) return null;
            }
            else
            {
                if ((u < 0 || v < 0 || w < 0) && (u > 0 || v > 0 || w > 0)) return null;
            }

            var det:Number = u + v + w;
            if (det == 0) return null;

            var tScaled:Number = sz * (u * akz + v * bkz + w * ckz);
            if (det > 0 ? tScaled < 0 : tScaled > 0) return null;

            return this.at(tScaled / det, target);
        }

        // Ray.js:671.
        public function applyMatrix4(matrix4:Matrix4):Ray
        {
            this.origin.applyMatrix4(matrix4);
            this.direction.transformDirection(matrix4);
            return this;
        }

        public function equals(ray:Ray):Boolean
        {
            return ray.origin.equals(this.origin) && ray.direction.equals(this.direction);
        }
    }
}