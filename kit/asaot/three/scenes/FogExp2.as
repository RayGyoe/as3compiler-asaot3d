// asaot.three.scenes.FogExp2 -- exponential-squared fog.
//
// Borrows src/scenes/FogExp2.js (r187): name/color/density plus `isFogExp2`.
// three.js computes `1 - exp(-density^2 * depth^2)` in fog_fragment.glsl.js:6,
// which this backend reproduces with AGAL's natural-exponential `exp` (there is
// no `ex2` opcode; see D48 for the same const-conversion trick in the env BRDF).
package asaot.three.scenes
{
    import asaot.three.math.Color;

    public class FogExp2
    {
        public var name:String;
        public var color:Color;
        public var density:Number;
        public var isFogExp2:Boolean = true;

        public function FogExp2(color:int = 0xffffff, density:Number = 0.00025)
        {
            this.name = '';
            this.color = new Color(color);
            this.density = density;
        }
    }
}