// asaot.three.lights.AmbientLight -- uniform, direction-less light.
//
// Borrows src/lights/AmbientLight.js (r187): no fields beyond the base Light
// (color + intensity). Its position/rotation in the scene graph are ignored.
package asaot.three.lights
{
    public class AmbientLight extends Light
    {
        public function AmbientLight(color:int = 0xffffff, intensity:Number = 1)
        {
            super(color, intensity);
            // No isAmbientLight flag: AS3 has the `is` operator for type tests,
            // so the renderer distinguishes light kinds by `light is AmbientLight`
            // instead of three.js's JS runtime flags.
        }
    }
}
