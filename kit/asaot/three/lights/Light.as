// asaot.three.lights.Light -- light base class, three.js style.
//
// Borrows src/lights/Light.js (r187): color + intensity. It extends Object3D so
// a light has a transform in the scene graph (position matters for
// DirectionalLight/PointLight; AmbientLight ignores it).
package asaot.three.lights
{
    import asaot.three.core.Object3D;
    import asaot.three.math.Color;

    public class Light extends Object3D
    {
        public var color:Color;
        public var intensity:Number;

        public function Light(color:int = 0xffffff, intensity:Number = 1)
        {
            super();
            this.color = new Color(color);
            this.intensity = intensity;
        }
    }
}
