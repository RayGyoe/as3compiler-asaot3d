// asaot.three.scenes.Scene -- scene root, three.js style.
//
// Borrows src/scenes/Scene.js (r187): the root node identity plus background/
// fog/environment slots. `environment` is a CubeTexture used as the default
// image-based light for every MeshStandardMaterial that does not carry its own
// envMap (Scene.js:44; WebGLRenderer resolves `material.envMap ||
// scene.environment`).
//
// M20: `background` accepts a Color, a CubeTexture (skybox) or a Texture
// (full-viewport quad), and `fog` accepts Fog (linear) or FogExp2 -- both are
// consumed by AGALRenderer now (three-api-design.md §25). The slots stay typed
// as Object because AS3 has no union types and an `is` test is the same check a
// typed field would need anyway.
package asaot.three.scenes
{
    import asaot.three.core.Object3D;
    import asaot.three.extras.PrefilteredEnvironment;
    import asaot.three.textures.CubeTexture;

    public class Scene extends Object3D
    {
        public var background:Object = null;   // Color / CubeTexture / Texture
        public var fog:Object = null;          // Fog / FogExp2
        public var environment:CubeTexture = null;

        // M25-R1 (D174): a PRE-FILTERED environment -- six roughness levels of the
        // same bake (extras/EnvironmentPrefilter). When set, the renderer lights
        // standard materials from the level matching each material's roughness
        // and takes the diffuse term from the roughest level, instead of sampling
        // the sharp cube and blending toward the normal (the M9 stand-in).
        //
        // `environment` stays the plain slot and is still what
        // `scene.background` wants; a demo normally sets both:
        //
        //     var ladder:PrefilteredEnvironment = EnvironmentPrefilter.bake(img, 64);
        //     scene.environment = ladder.sharpCube;
        //     scene.environmentPrefiltered = ladder;
        //     scene.background = ladder.sharpCube;
        //
        // A material that carries its own `envMap` is NOT pre-filtered by this
        // (its cube has no ladder); it keeps the M9 path, which is the documented
        // asymmetry of D174.
        public var environmentPrefiltered:PrefilteredEnvironment = null;

        // three.js Scene.environmentIntensity (Scene.js:60, r165+): a scene-wide
        // multiplier on the environment light, applied ON TOP of the material's
        // own envMapIntensity. M25 folds it into the environment intensity the
        // renderer already uploads (fc10.x), so it costs no new constant.
        public var environmentIntensity:Number = 1.0;

        // three.js Scene.backgroundIntensity (Scene.js:69): same knob for the
        // background image/skybox.
        public var backgroundIntensity:Number = 1.0;

        // three.js Scene.backgroundBlurriness (Scene.js:78): 0 = sharp, 1 = fully
        // blurred. three.js reaches it by sampling a PMREM (prefiltered) chain at
        // a fixed roughness; this backend has no explicit-LOD cube sampling (AGAL
        // `tex` has no LOD operand and `tld` is vertex-stage only), so a mip
        // ladder could not be addressed even if one existed. M25 therefore
        // approximates the blur with a small cone of taps in the skybox program
        // (D156) -- an approximation that is documented, not silent. Float render
        // targets are NOT the reason: the opt-in `standard` rung has them
        // (three-api-design.md 36.1); the missing piece is per-fragment LOD.
        public var backgroundBlurriness:Number = 0.0;

        public var isScene:Boolean = true;

        public function Scene()
        {
            super();
        }
    }
}
