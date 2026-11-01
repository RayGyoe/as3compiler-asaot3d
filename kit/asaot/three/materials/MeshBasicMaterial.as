// asaot.three.materials.MeshBasicMaterial -- unlit color material.
//
// Borrows src/materials/MeshBasicMaterial.js (r187): color (default 0xffffff),
// map, wireframe. No lights are sampled. M1 shipped this as "pure color" and
// left `map` out on purpose (D16); M20 finally wires it, because a glTF
// material carrying KHR_materials_unlit was decoded into a MeshBasicMaterial
// and then had its `baseColorTexture` dropped on the floor -- an unlit textured
// model rendered as a flat color with no diagnostic at all.
//
// The map is sampled in the unlit fragment (fs0), multiplied by `color` exactly
// like map_fragment.glsl.js (`diffuseColor *= sampledDiffuseColor`), honours the
// texture's uv transform (vc40/vc41, the same M18 block the shadow cutout
// program uses) and its colorSpace decode bit.
package asaot.three.materials
{
    import asaot.three.math.Color;
    import asaot.three.textures.Texture;

    public class MeshBasicMaterial extends Material
    {
        public var color:Color;
        // M20: base-color texture (null = flat color). UV transform and sRGB
        // decoding follow the same rules as MeshStandardMaterial.map (M17/M18).
        public var map:Texture;
        public var wireframe:Boolean;
        // Device-pixel edge width (three.js MeshBasicMaterial.js
        // `wireframeLinewidth = 1`); see MeshStandardMaterial.wireframeLinewidth.
        public var wireframeLinewidth:Number;

        public function MeshBasicMaterial()
        {
            super();
            this.color = new Color(0xffffff);
            this.map = null;
            this.wireframe = false;
            this.wireframeLinewidth = 1;
        }
    }
}