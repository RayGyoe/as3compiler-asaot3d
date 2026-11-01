// asaot.three.math.Spherical -- spherical coordinates (radius, phi, theta).
//
// Borrows src/math/Spherical.js (r187) verbatim: phi is measured from +Y (the
// polar angle) and theta around +Y from +Z, so the Cartesian round trip is
//   x = r sin(phi) sin(theta)   y = r cos(phi)   z = r sin(phi) cos(theta)
//
// M14 needs it because OrbitControls stores the camera offset this way while it
// orbits: theta/phi get the mouse deltas, the clamps are applied in angle space,
// and only then is the offset converted back to Cartesian (OrbitControls.js
// `update()`). Doing the rotation in Cartesian space instead would let the
// distance drift as the deltas accumulate.
//
// `makeSafe()` keeps phi away from the poles so the conversion back cannot lose
// the azimuth: at phi = 0 or PI the x/z components of the offset are exactly 0
// and theta becomes unrecoverable (the camera would be stuck looking straight
// down). three.js clamps to [EPS, PI - EPS] with EPS = 1e-6 (`Spherical.js:84`).
package asaot.three.math
{
    public class Spherical
    {
        public var radius:Number;
        public var phi:Number;
        public var theta:Number;

        public function Spherical(radius:Number = 1, phi:Number = 0, theta:Number = 0)
        {
            this.radius = radius;
            this.phi = phi;
            this.theta = theta;
        }

        public function set(radius:Number, phi:Number, theta:Number):Spherical
        {
            this.radius = radius;
            this.phi = phi;
            this.theta = theta;
            return this;
        }

        public function clone():Spherical
        {
            return new Spherical(this.radius, this.phi, this.theta);
        }

        public function copy(s:Spherical):Spherical
        {
            this.radius = s.radius;
            this.phi = s.phi;
            this.theta = s.theta;
            return this;
        }

        // Spherical.js:84.
        public function makeSafe():Spherical
        {
            var EPS:Number = 0.000001;
            this.phi = Math.max(EPS, Math.min(Math.PI - EPS, this.phi));
            return this;
        }

        // Spherical.js:100.
        public function setFromVector3(v:Vector3):Spherical
        {
            return this.setFromCartesianCoords(v.x, v.y, v.z);
        }

        // Spherical.js:114. theta = atan2(x, z) and phi = acos(clamped y/r);
        // a zero-length offset has no azimuth and no polar angle (both 0).
        public function setFromCartesianCoords(x:Number, y:Number, z:Number):Spherical
        {
            this.radius = Math.sqrt(x * x + y * y + z * z);
            if (this.radius == 0)
            {
                this.theta = 0;
                this.phi = 0;
            }
            else
            {
                this.theta = Math.atan2(x, z);
                this.phi = Math.acos(Math.max(-1, Math.min(1, y / this.radius)));
            }
            return this;
        }
    }
}