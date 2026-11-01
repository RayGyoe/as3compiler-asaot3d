// asaot.three.lights.DirectionalLight -- light from an infinitely distant point.
//
// Borrows src/lights/DirectionalLight.js (r187): position defaults to
// Object3D.DEFAULT_UP (0,1,0) and light travels toward `target` (default
// origin), so the direction is target.position - position. shadow (M7) carries
// the DirectionalLightShadow config for the shadow-mapping prepass.
package asaot.three.lights
{
    import asaot.three.core.Object3D;
    import asaot.three.lights.DirectionalLightShadow;

    public class DirectionalLight extends Light
    {
        public var target:Object3D;
        public var shadow:DirectionalLightShadow;

        public function DirectionalLight(color:int = 0xffffff, intensity:Number = 1)
        {
            super(color, intensity);
            // three.js copies Object3D.DEFAULT_UP into position (DirectionalLight.js:55).
            this.position.set(0, 1, 0);
            this.target = new Object3D();
            this.shadow = new DirectionalLightShadow();
        }
    }
}
