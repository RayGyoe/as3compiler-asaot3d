// asaot.three.lights.PointLight -- light from a single point in all directions.
//
// Borrows src/lights/PointLight.js (r187): color/intensity + distance/decay
// (Frostbite physically-based attenuation). isPointLight=true for type tests.
// shadow is out of scope (PointLightShadow lands with M7's shadow pipeline).
package asaot.three.lights
{
    public class PointLight extends Light
    {
        // Maximum range of the light; 0 means no limit (inverse-square to
        // infinity). Non-zero adds the smooth Frostbite window cutoff.
        public var distance:Number;

        // How fast the light dims along distance; 2 = physically correct
        // inverse-square (PointLight.js:47).
        public var decay:Number;

        public function PointLight(color:int = 0xffffff, intensity:Number = 1, distance:Number = 0, decay:Number = 2)
        {
            super(color, intensity);
            this.distance = distance;
            this.decay = decay;
        }
    }
}
