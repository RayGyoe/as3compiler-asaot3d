// asaot.three.scenes.Fog -- linear (near/far) fog.
//
// Borrows src/scenes/Fog.js (r187): name/color/near/far plus `isFog`. The color
// is a Color in the LINEAR working space (Color.setHex decodes the authored hex
// exactly like every other material color, D30); the renderer mixes it into the
// final linear radiance before tone mapping, which is the order three.js uses
// (fog_fragment.glsl.js runs before tonemapping_fragment).
//
// M20 makes Scene.fog a real feature: before this milestone the field was inert
// and the renderer printed a one-shot diagnostic (three-api-design.md §22.5).
package asaot.three.scenes
{
    import asaot.three.math.Color;

    public class Fog
    {
        public var name:String;
        public var color:Color;
        public var near:Number;
        public var far:Number;
        public var isFog:Boolean = true;

        public function Fog(color:int = 0xffffff, near:Number = 1, far:Number = 1000)
        {
            this.name = '';
            this.color = new Color(color);
            this.near = near;
            this.far = far;
        }
    }
}