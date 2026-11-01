// asaot.three.lights.SpotLight -- light from a point, along a cone.
//
// Borrows src/lights/SpotLight.js (r187): color/intensity + distance/angle/
// penumbra/decay + target. The cone points from position to target (default
// origin). isSpotLight=true for type tests. shadow is out of scope (M7).
package asaot.three.lights
{
    import asaot.three.core.Object3D;

    public class SpotLight extends Light
    {
        // The spot points from position to target (SpotLight.js:63). Default
        // origin, matching DirectionalLight.
        public var target:Object3D;

        // Maximum range; 0 = no limit (same Frostbite window as PointLight).
        public var distance:Number;

        // Maximum angle of dispersion from the light's direction, upper bound
        // PI/2 (SpotLight.js:86).
        public var angle:Number;

        // Fraction of the cone softened at the edge, [0,1] (SpotLight.js:93).
        public var penumbra:Number;

        // Distance dimming exponent; 2 = physically correct (SpotLight.js:100).
        public var decay:Number;

        public function SpotLight(color:int = 0xffffff, intensity:Number = 1, distance:Number = 0, angle:Number = 1.0471975511965976, penumbra:Number = 0, decay:Number = 2)
        {
            super(color, intensity);
            // three.js copies Object3D.DEFAULT_UP into position (SpotLight.js:57).
            this.position.set(0, 1, 0);
            this.target = new Object3D();
            this.distance = distance;
            this.angle = angle;
            this.penumbra = penumbra;
            this.decay = decay;
        }
    }
}
