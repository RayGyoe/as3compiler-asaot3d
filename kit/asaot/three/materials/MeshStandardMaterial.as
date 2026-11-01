// asaot.three.materials.MeshStandardMaterial -- metallic-roughness PBR material.
//
// Borrows src/materials/MeshStandardMaterial.js (r187) parameter surface only:
// color/roughness/metalness/emissive(+Intensity)/emissiveMap/aoMap(+Intensity)/
// map/normalMap/roughnessMap/metalnessMap/envMap(+Intensity)/wireframe/
// flatShading/normalScale.
// M19 wires the two that used to be dead: `flatShading` selects a derivative-
// based face normal in the standard/punctual fragment (FLAT_SHADED in three.js),
// and `wireframe` draws the triangle edges instead of the surface. See
// three-api-design.md §24 for both, including the wireframe divergences.
// The GLSL shader body is NOT borrowed -- the PBR lighting is machine-generated
// as AGAL in the seam layer (three-api-design.md §9). M2 wired `map` (base-color
// sampling); M4 wires normalMap/normalScale/roughnessMap/metalnessMap sampling
// (D31-D33, R8); M8 follow-up wires emissiveMap (fs5) and aoMap (fs6); M9 wires
// envMap (fs7) for image-based reflection.
package asaot.three.materials
{
    import asaot.three.math.Color;
    import asaot.three.math.Vector2;
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.Texture;

    public class MeshStandardMaterial extends Material
    {
        public var color:Color;               // diffuse base color
        public var roughness:Number;          // [0,1], GGX perceptual roughness
        public var metalness:Number;          // [0,1], metallic-roughness workflow
        public var emissive:Color;
        public var emissiveIntensity:Number;

        public var map:Texture;               // base-color texture (null = unlit color)
        public var normalMap:Texture;
        public var normalScale:Vector2;       // (1,1); normal map xy multiplier (MeshStandardMaterial.js:238)
        public var roughnessMap:Texture;
        public var metalnessMap:Texture;
        // M8 follow-up: fs5 emissive texel multiplies emissive*emissiveIntensity
        // (emissivemap_fragment.glsl.js:6), fs6 texel.r attenuates the ambient
        // (indirect diffuse) term (aomap_fragment.glsl.js).
        public var emissiveMap:Texture;
        public var aoMap:Texture;
        public var aoMapIntensity:Number;     // [0,1] blend toward no-occlusion, default 1

        // M9: image-based lighting. `envMap` is a CubeTexture (three.js's
        // MeshStandardMaterial.envMap, MeshStandardMaterial.js:104); when null
        // the renderer falls back to scene.environment
        // (WebGLRenderer's material.envMap || scene.environment). The intensity
        // scales both the reflected radiance and the diffuse irradiance
        // (envmap_physical_pars_fragment.glsl.js:108,120).
        public var envMap:CubeTexture;
        public var envMapIntensity:Number;    // default 1

        public var wireframe:Boolean;
        // Rendered width in DEVICE pixels (three.js MeshStandardMaterial.js
        // `wireframeLinewidth = 1`). Stage3D has no line primitive, so the
        // renderer expands each triangle edge into a screen-space quad and this
        // value is the quad's half width -- honoured at every size, like the
        // M11 LineBasicMaterial.linewidth enhancement (E-linewidth).
        public var wireframeLinewidth:Number;
        public var flatShading:Boolean;

        public function MeshStandardMaterial()
        {
            super();
            this.color = new Color(0xffffff);
            this.roughness = 1.0;
            this.metalness = 0.0;
            this.emissive = new Color(0x000000);
            this.emissiveIntensity = 1.0;
            this.map = null;
            this.normalMap = null;
            this.normalScale = new Vector2(1, 1);
            this.roughnessMap = null;
            this.metalnessMap = null;
            this.emissiveMap = null;
            this.aoMap = null;
            this.aoMapIntensity = 1.0;
            this.envMap = null;
            this.envMapIntensity = 1.0;
            this.wireframe = false;
            this.wireframeLinewidth = 1;
            this.flatShading = false;
        }
    }
}
