// asaot.three.AGALRenderer -- Stage3D renderer that machine-generates AGAL.
//
// The default renderer backend (three-api-design.md §9, AGAL-first). It walks
// the scene graph, computes each mesh's model-view-projection matrix, uploads
// the geometry's position/normal/uv attributes to GPU buffers, and draws with a
// material-kind-specific AGAL program:
//
//   * MeshBasicMaterial  -> unlit color (M1)
//   * MeshStandardMaterial -> metallic-roughness PBR: GGX micro-facet specular
//     (D_GGX / V_GGX_SmithCorrelated / F_Schlick) + Lambert diffuse, lit by one
//     directional light + accumulated ambient light, sampling map/normalMap/
//     roughnessMap/metalnessMap textures (M2 + M4).
//
// M4 (texture map family, R8): the standard fragment program is assembled as
// AGAL2 (version 2) and samples FOUR textures unconditionally -- fs0 base
// color, fs1 normal map, fs2 roughness map, fs3 metalness map. Unbound
// material slots bind 1x1 NEUTRAL textures instead (white for color/roughness/
// metalness, (0.5,0.5,1) for the normal map), so every combination is one
// program with identity-texel semantics -- the same trick three.js uses with
// its empty textures, but without 16 material variants. This also fixes the
// M2 semantic gap where a mapped material ignored `color`: the fragment now
// always multiplies baseColor * sampledDiffuseColor (map_fragment.glsl.js:14).
//
// M8 follow-up adds two more unconditional samples by the same rule: fs5
// emissive (emissivemap_fragment.glsl.js:6) and fs6 ambient occlusion
// (aomap_fragment.glsl.js). fs4 carries the shadow map only for the shadow
// variant, so the samplers in use are fs0-fs3 + fs5 + fs6 plus fs4 on the
// shadow pass -- six of the sixteen AGAL2 sampler slots.
//
// M9 (image-based lighting) adds the seventh: fs7, a CUBE sampler holding the
// environment map (`material.envMap || scene.environment`). It is sampled twice
// by the standard fragment -- once at the reflection direction R for specular
// radiance, once at the shading normal N for diffuse irradiance. No PMREM
// pre-filtering exists in this backend (no float render targets, so no mip
// chain of pre-convolved radiance), so the two features a pre-filtered env map
// would supply are approximated instead: roughness blends R toward N by
// roughness^2 (what three.js does on top of the prefilter), and the specular
// energy split uses Karis's analytic EnvBRDFApprox rather than sampling a DFG
// LUT texture (three.js reads BRDF_LUT; the analytic form saves a sampler and
// ~8 bytes of constant upload per draw). Both approximations are recorded in
// three-api-design.md D48.
//
// R8 (normal mapping): AGAL has no derivative opcodes in profile 1, but AGAL2
// does (ddx/ddy, assembler OP_VERSION2; the translator emits dfdx/dfdy for
// MSL). We therefore take three.js's DEFAULT tangent-frame path --
// getTangentFrame via screen-space derivatives of the world position and uv
// (normalmap_pars_fragment.glsl.js:20-40), computed in WORLD space because
// our lighting is world-space (three.js computes it in view space because
// WebGLRenderer lights in view space). No tangent attribute is required,
// which is why BufferGeometry.computeTangents() (BufferGeometry.js:837) is
// provided for API parity but not consumed by this renderer.
//
// AGAL2 relaxes the AGAL1 limits that shaped M2: 26 fragment temporaries
// (ft0-ft25), 64 fragment constants (fc0-fc63), 10 varyings (v0-v9), 16
// samplers (fs0-fs15). The translator's decode cap is 400 instructions
// (runtime.ts; raised from the AGAL1-baseline 200 in M10 when the standard
// fragment reached 168/200 and tone mapping needed 17 more).
//
// M10 (tone mapping + transparency) adds three things to every lighting
// program: a tone-map block applied to the final LINEAR color right before the
// R7 sRGB encode (three.js tonemapping_fragment.glsl.js:9 -- tone map first,
// then transfer-function), an alpha-test discard (`kil`), and the material
// opacity written into oc.w instead of hard-coded 1.0. Tone mapping is
// NoToneMapping by default, exactly like three.js r187's default, so a
// renderer that never touches `toneMapping` emits the pre-M10 programs.
//
// Key semantic facts (pinned against as-aot's Stage3D seam, see AGENTS.md):
//   * Matrix3D.rawData is column-major; AGAL's `dp4 op.x, va0, vcN` computes
//     dot(vcN, va0), so vcN must hold the matrix ROW N. setProgramConstantsFromMatrix
//     with transposedMatrix=true copies in transposed order (each math row into a
//     register), which is what a column-major Matrix4 needs for dp4 to apply
//     translation correctly (matches shmup-stage3d's usage).
//   * The normal matrix (inverse-transpose of the model matrix, 3x3) is uploaded
//     by hand via setProgramConstantsFromVector: each of its three ROWS becomes
//     one vc register (dp3 ignores the w channel, so translation never leaks
//     into the normal).
//   * IndexBuffer3D.uploadFromVector takes Vector.<uint>, so the geometry's
//     Vector.<Number> index attribute is widened here (D11 defers precision to
//     this seam layer).
//
// The PBR fragment program is an AGAL1 program (8 ft temporaries), so the GGX
// terms are hand register-allocated: N/V stay in ft0/ft1, the four dot products
// are packed into ft3's channels, and V*D is parked in ft4.w across the diffuse
// stage (which is why the stages are ordered diffuse-before-specular).
//
// R7/D170 (output color space): three.js r187 defaults outputColorSpace =
// SRGBColorSpace (WebGLRenderer.js:313), so the final color is encoded to
// sRGB before it reaches the backbuffer. AGAL has no built-in transfer
// function, so srgbEncodeBlock/srgbDecodeBlock spell out the sRGB curve:
//   enc = 1.055*x^(1/2.4) - 0.055        dec = ((c+0.055)/1.055)^2.4
// Exact above the curve's knee (c > 0.04045 / L > 0.0031308), and still an
// exact round trip below it (dec/enc are mutual inverses, which the sRGB
// background quad relies on). D170 replaced the earlier pow(x,2.2) /
// pow(x,1/2.2) pair: at display 25/255 those two differ by 3.6x in LINEAR
// radiance (pow(0.098,2.2)=0.0056 vs exact 0.0071), which is exactly what
// made a dark textured floor read +28% in display space -- see
// three-api-design.md §32.10. This pairs with the input decode in Color
// (sRGB -> linear setHex, §12 D30): render in linear working space, encode
// on output, matching three.js's default color management end to end.
package asaot.three
{
    import com.adobe.utils.AGALMiniAssembler;

    import flash.display3D.Context3D;
    // AGALTranslator exists only under as-aot (it bridges to the Metal/GLSL/HLSL
    // translator so a bad program fails at BUILD time with a readable message).
    // AIR has no such class, and a static reference compiles but throws #1065 at
    // runtime -- that is how the first end-to-end AIR run died -- so it is
    // resolved dynamically and skipped when absent.
    import flash.utils.getDefinitionByName;
    import flash.display3D.Context3DProgramType;
    import flash.display3D.Context3DTextureFormat;
    import flash.display3D.Context3DVertexBufferFormat;
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.Program3D;
    import flash.display3D.VertexBuffer3D;
    // mxmlc resolves a type through its import, not through a qualified name:
    // a `flash.display3D.textures.Texture` declaration fails ("找不到类型")
    // unless some class of that package is imported. Texture/CubeTexture cannot
    // be imported under their simple names here -- asaot.three.textures.Texture
    // and .CubeTexture already own those -- so an unused sibling type opens the
    // package instead. as-aot resolves flash.* builtins implicitly: no-op there.
    import flash.display3D.textures.RectangleTexture;
    import flash.display.BitmapData;
    import flash.utils.Dictionary;
    import flash.geom.Matrix;
    import flash.geom.Matrix3D;

    import asaot.three.cameras.Camera;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Frustum;
    import asaot.three.core.Object3D;
    import asaot.three.core.Sphere;
    import asaot.three.cameras.OrthographicCamera;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.lights.DirectionalLightShadow;
    import asaot.three.lights.Light;
    import asaot.three.lights.LightProbe;
    import asaot.three.lights.PointLight;
    import asaot.three.lights.SpotLight;
    import asaot.three.math.Color;
    import asaot.three.math.Matrix3;
    import asaot.three.math.Matrix4;
    import asaot.three.math.SphericalHarmonics3;
    import asaot.three.math.Vector3;
    import asaot.three.materials.Material;
    import asaot.three.materials.LineBasicMaterial;
    import asaot.three.materials.MeshBasicMaterial;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.LineSegments;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Fog;
    import asaot.three.scenes.FogExp2;
    import asaot.three.scenes.Scene;
    import asaot.three.extras.LightProbeGenerator;
    import asaot.three.extras.PrefilteredEnvironment;
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.Texture;

    import flash.display3D.AGALTranslator;

    public class AGALRenderer implements IRenderer
    {
        // AGAL version every program is assembled with, and it is NOT cosmetic.
        //
        // Measured on adl 51.4.1 (temp/airprobe: one upload per version x profile):
        //   profile          v1  v2  v3  v4
        //   baseline         -   -   -   -
        //   baselineExtended -   -   -   -
        //   standard         -   OK  -   -
        //   standardExtended -   OK  OK  -
        //   enhanced         -   OK  OK  OK
        // A version the current Context3D profile does not allow fails at upload with
        // #3725 and renders nothing, so the profile requested in Stage3DApp
        // ("enhanced") and this constant are ONE decision, not two. Version 4 is the
        // highest AIR accepts, and its register file is what the 8-slot texture set
        // plus the fog constants need; as-aot's translator accepts 1..4 (v4 has the
        // same 0xA0/0xA1 encoding and instruction slots, and we emit no v4-only op).
        public static const AGAL_VERSION:int = 4;

        private var _context:Context3D;
        // Diagnostic switch (off by default): dump the assembled fragment
        // program text -- AGAL plus the backend translation -- once per rebuilt
        // standard program, so a sampling or translation defect can be read off
        // the real instruction order instead of guessed at. Set it before the
        // first frame that builds the program (`dumpFragSource = true`).
        // Introduced by apps/cubeface-m25; also used by the walk-m26 env /
        // metalness investigation.
        public static var dumpFragSource:Boolean = false;
        // Diagnostic switch (off by default): bypass the mirror cube fetch and
        // write |R| straight into the radiance term, so a black patch reads as
        // "R is NaN/invalid here" rather than "the cube sample returned 0".
        public static var debugReflect:Boolean = false;

        private var _assembler:AGALMiniAssembler;

        // Two programs: unlit color (M1) and the single standard PBR program
        // (M2/M4). No per-map variants: neutral 1x1 textures make every map
        // combination valid against the same program (R8).
        private var _basicProgram:Program3D;
        // M13: the standard program is a family keyed by (directional lights,
        // shadow-casting directional lights). Built lazily on first use and
        // cached, so a scene that never uses two lights pays for one variant.
        private var _standardVariants:Dictionary;
        private var _standardProgram:Program3D;
        // M6 punctual-light programs: one point light per additive pass and one
        // spot light per additive pass. Kept as separate programs because
        // unrolling several lights into one fragment program would need ~50
        // instructions per light plus a per-light constant block, and each
        // additive pass must also blend into the same buffer (three.js sums the
        // punctual contributions inside its single shader).
        //
        // M17: keyed by "<spot>:<decodeMask>" -- the punctual programs sample the
        // base-color map (fs0), so a material whose map is sRGB needs the decoded
        // variant. Lazy, like _standardVariants.
        private var _punctualVariants:Dictionary;

        // M11: line-segment program. Stage3D has no line primitive, so each
        // segment is expanded into a screen-space quad by the vertex shader
        // (see _buildLineProgram). One program serves every LineSegments draw.
        private var _lineProgram:Program3D;
        // M26: line variants by (vertexColors, toneMapped). SkeletonHelper asks
        // for the (true,false) corner; every pre-M26 line draw keeps using
        // _lineProgram, i.e. the exact AGAL it used before.
        private var _lineVariants:Dictionary;

        // M7 shadow-mapping: a depth-only program writes the [0,1] NDC depth
        // into the shadow map color (the Stage3D depth surface is render-target
        // only, not shader-readable, so the depth is re-encoded through color --
        // recorded in three-borrow-map R11). The standard pass samples that
        // color texture and compares depths for the directional light.
        //
        // M13: one map PER shadow-casting directional light (up to
        // MAX_SHADOW_LIGHTS), so the three per-map slots are vectors indexed by
        // shadow light. `_shadowProgram` is the position-only depth program and
        // `_shadowAlphaProgram` the cutout variant that samples the base-color
        // texel and `kil`s below `alphaTest` (three.js renders casters with a
        // depth material that honours alphaTest -- D89).
        private var _shadowProgram:Program3D;
        private var _shadowAlphaProgram:Program3D;
        private var _shadowMaps:Vector.<flash.display3D.textures.Texture>;
        private var _shadowMapW:Vector.<int>;
        private var _shadowMapH:Vector.<int>;
        private var _shadowVP:Matrix4;
        private var _shadowBias:Matrix4;
        private var _shadowMatrix:Matrix4;
        private var _shadowMatrix3D:Matrix3D;
        private var _shadowPassDepthConst:Vector.<Number>; // shadow program fc0
        // alpha shadow fc0 = (alphaTest, opacity, 1, 0)
        private var _shadowPassAlphaConst:Vector.<Number>;
        // fc1 of either depth program = (255, 1/255, 0, 1): M13 depth packing
        private var _shadowPackConst:Vector.<Number>;
        private var _shadowPassActive:int;                 // 0 plain program, 1 alpha-test program
        // fc24/fc25/fc26 are uploaded as one 12-float block: the two PCF
        // kernels (radius/mapSize, 1/9) and the second light's bias row.
        private var _shadowAuxConst:Vector.<Number>;
        private var _shadowNormalBias:Vector.<Number>; // vc20 = (normalBias,0,0,0)
        private var _receiveVec:Vector.<Number>;       // vc22 = (receiveShadow,0,0,0)

        // 1x1 neutral textures for unbound material slots (R8): white for the
        // base-color/roughness/metalness/emissive maps (multiply-by-1 identity,
        // and ao=1 for the occlusion slot) and (0.5,0.5,1) for the normal map
        // (texel*2-1 = (0,0,1) = identity normal).
        private var _neutralWhiteBmp:BitmapData;
        private var _neutralNormalBmp:BitmapData;
        private var _neutralWhite:flash.display3D.textures.Texture;
        private var _neutralNormal:flash.display3D.textures.Texture;
        // M9: 8x8 all-white cube bound at fs7 when the draw has no environment
        // map. The fragment still samples fs7 unconditionally (like the 1x1
        // neutral textures), and fc10.x = 0 zeroes the result, so an
        // environment-less material costs one texture fetch and no program
        // variant.
        private var _neutralCube:flash.display3D.textures.CubeTexture;
        private var _cubeCache:Dictionary;      // CubeTexture -> GPUCubeResources
        private var _envCube:CubeTexture;       // scene.environment for this frame
        // M25-R1: scene.environmentPrefiltered for this frame (D174). Null means
        // the draw takes the M9 path: one sharp cube, specular radiance mixed
        // toward the normal by roughness^4.
        private var _scenePrefiltered:PrefilteredEnvironment;

        // M27: the scene's LightProbe(s) baked into ONE irradiance cube (D176),
        // plus the identity/version snapshot the bake was made from. `_probeCube`
        // is null when the scene carries no probe, and it is not bound at all when
        // the scene also has an environment (see _resolveLightProbes).
        private var _probeCube:CubeTexture;
        private var _probeCache:Vector.<LightProbe>;
        private var _probeVersionCache:Vector.<int>;
        private var _probeScratch:Vector.<LightProbe>;

        // `_warned` keeps one-time diagnostics so an unsupported request (e.g.
        // MirroredRepeatWrapping) is reported exactly once instead of every
        // frame, and never silently.
        //
        // (D177 retired fc36/`_decodeConst`: it was the D154 storage exponent of
        // an HDR bake, pow(x, 2.2). The bake now encodes with the sRGB OETF, so
        // there is exactly ONE transfer-function pair in the renderer.)
        private var _warned:Dictionary;
        // D170: fc41 = (1.055, 1/1.055, 0.055, 2.4) and fc42 = (1/2.4, 0, 0, 0),
        // the two registers every sRGB encode/decode pair in this renderer
        // reads. Uploaded beside every program's own constant block (the
        // constants a Stage3D program sees are per-program, so they cannot be
        // set once at init).
        private var _srgbConstVec:Vector.<Number>;
        // M17: scene.background -> clear color, converted from the Color's linear
        // working space to the sRGB-encoded values the back buffer holds.
        private var _clearVec:Vector.<Number>;
        // M18: the per-draw uv-transform constant block (vc40..vc51), six slots
        // of two rows. Owned by the renderer so a draw rewrites it in place
        // instead of allocating a Vector per frame (AGENTS.md memory red-line).
        private var _uvRows:Vector.<Number>;

        // M20: scene fog. `_fogMode` is resolved once per frame from Scene.fog
        // (0 = none, 1 = Fog linear, 2 = FogExp2) and joins the program variant
        // key, so an unfogged scene emits exactly the pre-M20 source.
        // `_fogConst` is fc37..fc40 (four registers):
        //   fc37 = (near, far, density, 1/(far-near) | log2(e))
        //   fc38 = (cameraPos.xyz, 1.0)
        //   fc39 = (cameraForward.xyz, 3.0)
        //   fc40 = (fogColor.rgb, 0)
        private var _fogMode:int;
        private var _fogConst:Vector.<Number>;

        // M20: background drawing. A CubeTexture background is a skybox (a unit
        // cube drawn with a rotation-only view matrix, three.js backgroundCube
        // shader) and a 2D Texture background is one clip-space quad (three.js
        // background shader). Both programs are built with the tone-mapping set
        // baked in, so they are rebuilt with the rest of the program set; the
        // decode variant skips tone mapping exactly like three.js
        // (`toneMapped = transfer !== SRGBTransfer`).
        private var _bgCubeProgramPlain:Program3D;
        private var _bgCubeProgramDecode:Program3D;
        // M25: the HDR skybox variant. A cube baked by EquirectangularToCube
        // carries gamma-encoded LINEAR radiance plus an hdrScale divisor, so the
        // program has to decode, multiply the radiance back up and THEN tone map
        // -- which is precisely the combination the two M20 variants are missing
        // (plain tone maps a linear texel it thinks is already linear; decode
        // skips tone mapping because three.js's sRGB backgrounds are toneMapped
        // = false). The blur variant adds the D156 tap cone for
        // scene.backgroundBlurriness.
        private var _bgCubeProgramHdr:Program3D;
        private var _bgCubeProgramHdrBlur:Program3D;
        private var _bgCubeProgramHdrBlur9:Program3D;
        private var _bgPlaneProgramPlain:Program3D;
        private var _bgPlaneProgramDecode:Program3D;
        private var _bgHdrConst:Vector.<Number>;   // fc2 = (hdrScale*intensity, blurRadius, 0, 0)
        private var _bgBlurriness:Number;          // scene.backgroundBlurriness this frame
        private var _bgIntensity:Number;           // scene.backgroundIntensity this frame
        // M25: scene.environmentIntensity for the draws of this frame.
        private var _sceneEnvIntensity:Number;
        private var _bgCubePositionBuffer:VertexBuffer3D;
        private var _bgCubeIndexBuffer:IndexBuffer3D;
        private var _bgQuadPositionBuffer:VertexBuffer3D;
        private var _bgQuadUvBuffer:VertexBuffer3D;
        private var _bgQuadIndexBuffer:IndexBuffer3D;
        private var _bgMatrix:Matrix4;
        private var _bgView:Matrix4;
        private var _bgMatrix3D:Matrix3D;
        private var _bgConst:Vector.<Number>;   // vc0 = (1,1,1,1) for the quad

        // M20: MeshBasicMaterial variants keyed by "<map>:<decode>:<fog>" --
        // the unlit program samples fs0 only when the material has a map, so a
        // colour-only basic draw keeps the M1 program byte for byte.
        private var _basicVariants:Dictionary;

        // Scratch matrices/vectors reused across frames (avoiding per-frame
        // allocation in the arena -- AGENTS.md memory red-line).
        private var _viewProjection:Matrix4;
        private var _mvp:Matrix4;
        private var _normalMatrix:Matrix3;
        private var _matrix3D:Matrix3D;
        private var _modelMatrix3D:Matrix3D;
        private var _cameraPos:Vector3;
        private var _lightDir:Vector3;
        private var _tmpA:Vector3;
        private var _tmpB:Vector3;

        // Upload payloads: normal matrix (3 rows = 12 floats) and the fragment
        // constants (9 registers = 36 floats) for the standard material.
        private var _normalVec:Vector.<Number>;
        private var _fragConst:Vector.<Number>;
        private var _colorVec:Vector.<Number>;
        private var _gammaVec:Vector.<Number>; // fc1.w: legacy 1/2.2, still
                                               // uploaded for the pre-D170
                                               // programs; the sRGB encode
                                               // reads fc42.y instead
        private var _shadowConst:Vector.<Number>; // shadow fragment fc0 = (0, 0, 0, 1): alpha only

        // M10 tone mapping / alpha. `_toneMapping` is baked into the fragment
        // sources at program-build time (three.js recompiles on a tone-mapping
        // change too), so the setter rebuilds the programs lazily on the next
        // render instead of paying for every variant up front.
        // `_toneVec` is fc14..fc21: (exposure, RRT a1, a2, b0), (b1, b2,
        // alphaTest, opacity), then the two ACES 3x3 matrices' rows.
        private var _toneMapping:int;
        private var _toneMappingExposure:Number;
        private var _programsDirty:Boolean;
        private var _toneVec:Vector.<Number>;

        // M10 transparent pass: meshes are collected once per frame so the
        // opaque and transparent draws can be ordered differently (three.js
        // projectObject/renderObjects). `_sortTransparent` holds Mesh refs and
        // `_sortDepth` the matching squared camera distance, in the same order.
        private var _opaqueMeshes:Vector.<Mesh>;
        private var _transparentMeshes:Vector.<Mesh>;
        private var _sortDepth:Vector.<Number>;

        // M11: line draws collected on the same scene walk as the meshes.
        private var _lineObjects:Vector.<LineSegments>;
        private var _lineCache:Dictionary;      // LineSegments -> GPULineResources
        // vc4 for the line program: (viewportWidth/2, viewportHeight/2,
        // lineWidth/2, -1). Rebuilt per draw because `linewidth` is per material.
        private var _lineViewport:Vector.<Number>;

        // M11: frustum culling. `_frustum` is refreshed from the camera's
        // projection matrix once per frame; `_culledCount` records how many
        // objects it removed so a probe/demo can prove the pass is live.
        private var _frustum:Frustum;
        private var _culledObjects:int;
        private var _drawCalls:int;
        // M12: monotonically increasing frame stamp. CPU deformed meshes
        // (morph targets / skinning) use it to run their vertex pass at most
        // once per frame even though the shadow prepass and the main pass both
        // touch the same mesh (see Mesh.updateDeform / D84).
        private var _frameId:int = 0;
        private var _triangleCount:int;
        // Scratch sphere for the LineSegments cull test (Frustum.intersectsObject
        // takes a Mesh; reusing its private scratch would couple the two).
        private var _cullSphere:Sphere = new Sphere();
        // three.js exposes frustum culling as a renderer-wide switch
        // (WebGLRenderer.js `this.info.autoReset`/`projectObject`'s
        // `camera`-independent `object.frustumCulled` test, plus the
        // renderer-level `_frustum` used only when a scene requests it). Here it
        // is an explicit opt-out so a demo can A/B the draw-call difference.
        public var frustumCullingEnabled:Boolean = true;

        // Collected lights for the current frame. M13: up to MAX_DIR_LIGHTS
        // directional lights are summed by the base pass, and the first
        // `_shadowLightCount` of them (shadow casters are collected FIRST) own a
        // shadow map. `_dirLight` aliases _dirLights[0] for the single-light
        // code paths that only need the primary light.
        private var _ambientColor:Color;
        private var _dirLights:Vector.<DirectionalLight>;
        private var _dirLight:DirectionalLight;
        private var _shadowLightCount:int;
        private var _pointLights:Vector.<PointLight>;
        private var _spotLights:Vector.<SpotLight>;

        // M13 caps. Two directional lights keep the base-pass fragment inside the
        // 400-instruction AGAL budget (229/400 with one PCF kernel, measured in
        // probes/shadow-smoke-m13).
        //
        // ONE shadow map per draw, not one per shadow-casting light: the eight
        // AGAL sampler slots are already fully spoken for by the standard
        // material (fs0 base, fs1 normal, fs2 roughness, fs3 metalness, fs4
        // shadow, fs5 emissive, fs6 AO, fs7 environment cube), so a second
        // shadow map has no unit to sample from and Stage3D offers no atlas or
        // viewport mechanism to pack two light frusta into one texture (D93).
        // A second directional light is therefore LIT but never shadowed.
        public static const MAX_DIR_LIGHTS:int = 2;
        public static const MAX_SHADOW_LIGHTS:int = 1;

        // PCF kernel: 3x3 taps scaled by DirectionalLightShadow.radius. The tap
        // offsets live in fc27..fc35 as a STATIC table (they never change), so a
        // draw only uploads the two scalars that scale them.
        public static const PCF_TAPS:int = 9;
        public static const PCF_OFFSET_BASE:int = 27;

        // The static 3x3 PCF tap grid, packed one (dx, dy, 0, 0) per register.
        // Public so probes/shadow-smoke-m13 can pin the tap geometry against the
        // snippet _shadowFactorBlock emits -- the two have to agree or the kernel
        // silently collapses to a point sample.
        public static function pcfOffsets():Vector.<Number>
        {
            var out:Vector.<Number> = new Vector.<Number>(PCF_TAPS * 4);
            var tap:int;
            for (tap = 0; tap < PCF_TAPS; tap++)
            {
                out[tap * 4] = (tap % 3) - 1;
                out[tap * 4 + 1] = int(tap / 3) - 1;
                out[tap * 4 + 2] = 0;
                out[tap * 4 + 3] = 0;
            }
            return out;
        }

        // Which pass the scene walk is emitting for right now: 0 = base
        // (standard program, ambient + directional), 1 = point light additive,
        // 2 = spot light additive. _activeLight holds the light for a punctual
        // pass so _renderStandard fills the right constants.
        // Stage3D gives every fragment program EIGHT sampler registers, fs0..fs7
        // -- not "fs0..fs15"; the standard program has all eight in use in the
        // shadow variant, which is why M25-R1 and M27 both had to fit inside the
        // existing slots (D175, D176).
        private static const MAX_SAMPLER_SLOTS:int = 8;

        private var _activePass:int;

        // Program3D -> bitmask of the generic vertex streams (va0 position,
        // va1 normal, va2 uv) the vertex program actually reads. AIR rejects a
        // draw with #3607 when a *set* stream is not read by the current
        // program, so the binding has to be exact -- as-aot tolerated the
        // surplus streams silently until this was measured on adl.
        private var _progStreams:Dictionary;
        private var _curStreamMask:int;
        // Bitmask of the fragment samplers (fs0..fs7) the current program
        // reads; unused slots are unbound before every draw.
        private var _progSamplers:Dictionary;
        private var _curSamplerMask:int;

        private var _activeLight:Light;

        // Per-mesh GPU resource cache: vertex/index buffers are (re)built only
        // when the corresponding attribute version changes.
        private var _cache:Dictionary;

        // Per-Texture GPU cache: the Stage3D texture is (re)uploaded only when
        // the Texture.version changes.
        private var _textureCache:Dictionary;

        public function AGALRenderer(context:Context3D)
        {
            this._context = context;
            this._assembler = new AGALMiniAssembler();

            this._viewProjection = new Matrix4();
            this._mvp = new Matrix4();
            this._normalMatrix = new Matrix3();
            this._matrix3D = new Matrix3D();
            this._modelMatrix3D = new Matrix3D();
            this._cameraPos = new Vector3();
            this._lightDir = new Vector3();
            this._tmpA = new Vector3();
            this._tmpB = new Vector3();

            this._shadowVP = new Matrix4();
            this._shadowBias = new Matrix4();
            this._shadowMatrix = new Matrix4();
            this._shadowMatrix3D = new Matrix3D();

            this._normalVec = new Vector.<Number>(12);
            this._fragConst = new Vector.<Number>(56);
            this._colorVec = new Vector.<Number>(4);
            this._gammaVec = new Vector.<Number>(4);
            this._gammaVec[3] = 1.0 / 2.2; // R7 output-encode exponent
            // D170: the sRGB transfer-function constants, shared by every
            // encode/decode site (see srgbEncodeBlock / srgbDecodeBlock).
            // fc41 = (1.055, 1/1.055, 0.055, 2.4)
            // fc42 = (1/2.4, 0, 0, 0)
            this._srgbConstVec = new Vector.<Number>(8);
            var sc:Array = AGALRenderer.SRGB_CONSTANTS;
            for (var sci:int = 0; sci < sc.length; sci++) this._srgbConstVec[sci] = Number(sc[sci]);
            for (sci = sc.length; sci < 8; sci++) this._srgbConstVec[sci] = 0;

            this._probeCache = new Vector.<LightProbe>();
            this._probeVersionCache = new Vector.<int>();
            this._probeScratch = new Vector.<LightProbe>();
            this._warned = new Dictionary();
            this._clearVec = new Vector.<Number>(4);
            this._clearVec[0] = 0;
            this._clearVec[1] = 0;
            this._clearVec[2] = 0;
            this._clearVec[3] = 1;
            // M18: identity rows until a draw fills them (a program sampled
            // before the first _fillUvRows would still get a sane transform).
            this._uvRows = new Vector.<Number>(AGALRenderer.UV_SLOTS * 8);
            var us:int;
            for (us = 0; us < AGALRenderer.UV_SLOTS; us++)
            {
                AGALRenderer.uvRowsInto(this._uvRows, us * 8, null);
            }

            // M20: fog + background state. `_fogMode = 0` until a scene with a
            // Fog/FogExp2 is rendered, which is what keeps every existing demo
            // on the pre-M20 program set.
            this._fogMode = 0;
            this._fogConst = new Vector.<Number>(16);
            this._bgMatrix = new Matrix4();
            this._bgView = new Matrix4();
            this._bgMatrix3D = new Matrix3D();
            this._bgConst = new Vector.<Number>(4);
            this._bgConst[0] = 1;
            this._bgConst[1] = 1;
            this._bgConst[2] = 1;
            this._bgConst[3] = 1;
            // M25: fc2 of the HDR skybox = (hdrScale * backgroundIntensity,
            // blurRadius in radians, 0, 0). Zeroed until a skybox fills it.
            this._bgHdrConst = new Vector.<Number>(4);
            this._bgHdrConst[0] = 1;
            this._bgBlurriness = 0;
            this._bgIntensity = 1;
            this._sceneEnvIntensity = 1;
            this._basicVariants = new Dictionary();

            // M10: tone-mapping / alpha constants (fc14..fc21). Filled once;
            // only the exposure slot and the per-draw alphaTest/opacity slots
            // are rewritten at draw time.
            this._toneMapping = AGALRenderer.NoToneMapping;
            this._toneMappingExposure = 1.0;
            this._programsDirty = false;
            this._toneVec = new Vector.<Number>(32);
            // RRTAndODTFit coefficients (tonemapping_pars_fragment.glsl.js:39-44).
            this._toneVec[1] = 0.0245786;      // a1
            this._toneVec[2] = -0.000090537;   // a2
            this._toneVec[3] = 0.983729;       // b0
            this._toneVec[4] = 0.4329510;      // b1
            this._toneVec[5] = 0.238081;       // b2
            // this._toneVec[6] = alphaTest (per draw), [7] = opacity (per draw)
            // ACESInputMat rows (the GLSL mat3 is column-major; dp3 needs rows).
            this._toneVec[8] = 0.59719;  this._toneVec[9] = 0.35458;  this._toneVec[10] = 0.04823;
            this._toneVec[12] = 0.07600; this._toneVec[13] = 0.90834; this._toneVec[14] = 0.01566;
            this._toneVec[16] = 0.02840; this._toneVec[17] = 0.13383; this._toneVec[18] = 0.83777;
            // ACESOutputMat rows.
            this._toneVec[20] = 1.60475;  this._toneVec[21] = -0.53108;  this._toneVec[22] = -0.07367;
            this._toneVec[24] = -0.10208; this._toneVec[25] = 1.10813;  this._toneVec[26] = -0.00605;
            this._toneVec[28] = -0.00327; this._toneVec[29] = -0.07276;  this._toneVec[30] = 1.07602;

            // M10 transparent pass lists (reused every frame).
            this._opaqueMeshes = new Vector.<Mesh>();
            this._transparentMeshes = new Vector.<Mesh>();
            this._sortDepth = new Vector.<Number>();

            // M11: line draws + frustum culling state.
            this._lineObjects = new Vector.<LineSegments>();
            this._lineCache = new Dictionary();
            // 8 floats = vc4 (viewport/width/halfwidth/-1) + vc5 (1/viewport).
            this._lineViewport = new Vector.<Number>(8);
            this._frustum = new Frustum();
            this._culledObjects = 0;
            this._drawCalls = 0;
            if (this._progStreams == null) this._progStreams = new Dictionary();
            if (this._progSamplers == null) this._progSamplers = new Dictionary();
            this._triangleCount = 0;

            // Shadow fragment fc0 = (0, 0, 0, 1): the depth program only uses
            // the output alpha (see _buildShadowProgram).
            this._shadowConst = new Vector.<Number>(4);
            this._shadowConst[0] = 0;
            this._shadowConst[1] = 0;
            this._shadowConst[2] = 0;
            this._shadowConst[3] = 1;
            // Alpha-cutout shadow program fc0 = (alphaTest, opacity, 1, 0):
            // uploaded per caster draw (D89).
            this._shadowPassAlphaConst = new Vector.<Number>(4);
            this._shadowPassAlphaConst[0] = 0;
            this._shadowPassAlphaConst[1] = 1;
            this._shadowPassAlphaConst[2] = 1;
            this._shadowPassAlphaConst[3] = 0;
            // fc1 of either depth program: (255, 1/255, 0, 1) -- the two packing
            // scales plus an unused channel and the map's output alpha.
            this._shadowPackConst = new Vector.<Number>(4);
            this._shadowPackConst[0] = 255;
            this._shadowPackConst[1] = 1 / 255;
            this._shadowPackConst[2] = 0;
            this._shadowPackConst[3] = 1;
            this._shadowPassActive = -1;
            this._shadowMaps = new Vector.<flash.display3D.textures.Texture>(AGALRenderer.MAX_SHADOW_LIGHTS);
            this._shadowMapW = new Vector.<int>(AGALRenderer.MAX_SHADOW_LIGHTS);
            this._shadowMapH = new Vector.<int>(AGALRenderer.MAX_SHADOW_LIGHTS);
            this._shadowAuxConst = new Vector.<Number>(20);
            this._shadowNormalBias = new Vector.<Number>(4);
            this._receiveVec = new Vector.<Number>(4);
            var s:int;
            for (s = 0; s < AGALRenderer.MAX_SHADOW_LIGHTS; s++)
            {
                this._shadowMaps[s] = null;
                this._shadowMapW[s] = 0;
                this._shadowMapH[s] = 0;
            }

            // M13: the PCF tap offsets are the same for every light and every
            // draw (a 3x3 grid in texel units, scaled by fc24 at use), so they
            // are uploaded once here into fc27..fc35.
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT,
                AGALRenderer.PCF_OFFSET_BASE, AGALRenderer.pcfOffsets(), AGALRenderer.PCF_TAPS);

            this._ambientColor = new Color(0x000000);
            this._dirLights = new Vector.<DirectionalLight>();
            this._dirLight = null;
            this._shadowLightCount = 0;
            this._pointLights = new Vector.<PointLight>();
            this._spotLights = new Vector.<SpotLight>();

            this._cache = new Dictionary();
            this._textureCache = new Dictionary();
            this._cubeCache = new Dictionary();
            this._envCube = null;
            this._scenePrefiltered = null;
            this._probeCube = null;

            // R8 neutral textures: 1x1 BitmapData uploaded once. setPixel32
            // takes ARGB; 0xFFFFFFFF is white, 0xFF8080FF is r=0.5/g=0.5/b=1.0.
            this._neutralWhiteBmp = new BitmapData(1, 1, false, 0);
            this._neutralWhiteBmp.setPixel32(0, 0, 0xFFFFFFFF);
            this._neutralNormalBmp = new BitmapData(1, 1, false, 0);
            this._neutralNormalBmp.setPixel32(0, 0, 0xFF8080FF);
            this._neutralWhite = this._context.createTexture(1, 1, Context3DTextureFormat.BGRA, false);
            this._neutralWhite.uploadFromBitmapData(this._neutralWhiteBmp, 0);
            this._neutralNormal = this._context.createTexture(1, 1, Context3DTextureFormat.BGRA, false);
            this._neutralNormal.uploadFromBitmapData(this._neutralNormalBmp, 0);

            // M9 neutral environment cube (8x8, six white faces). 8 is simply a
            // valid cube edge; the texel value is what matters and the sampler
            // is only ever multiplied by envMapIntensity = 0.
            this._neutralCube = this._context.createCubeTexture(8, Context3DTextureFormat.BGRA, false);
            var whiteFace:BitmapData = new BitmapData(8, 8, false, 0);
            whiteFace.setPixel32(0, 0, 0xFFFFFFFF);
            var side:int;
            for (side = 0; side < 6; side++)
            {
                AGALRenderer.uploadCubeChain(this._neutralCube, whiteFace, side);
            }

            // M10: programs are built lazily on the first render. `toneMapping`
            // is baked into the fragment sources, and an author who sets it
            // right after construction (every demo does) would otherwise pay for
            // one full program set that is immediately discarded.
            this._programsDirty = true;
        }

        public function render(scene:Scene, camera:Camera):void
        {
            // M10: tone mapping is baked into the fragment sources, so a change
            // to `toneMapping` rebuilds the program set here (once) rather than
            // at assignment time -- a renderer that never renders pays nothing.
            if (this._programsDirty) this._rebuildPrograms();

            // Ensure world matrices and the camera's inverse world matrix are
            // current before computing MVP matrices.
            scene.updateMatrixWorld(true);
            camera.updateMatrixWorld(true);
            camera.updateMatrixWorldInverse();

            this._viewProjection.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
            this._cameraPos.setFromMatrixPosition(camera.matrixWorld);

            // M11: refresh the culling frustum from the VIEW-PROJECTION matrix
            // (three.js WebGLRenderer.js does `_projScreenMatrix.multiplyMatrices(
            // camera.projectionMatrix, camera.matrixWorldInverse)` and hands THAT
            // to Frustum.setFromProjectionMatrix). Extraction must see the camera
            // transform, otherwise the six planes describe camera space while the
            // test feeds world-space bounding spheres -- which silently culls most
            // of the scene. The coordinate system is our [0,1] depth default
            // (Frustum D55), matching Matrix4.makePerspective's output.
            if (this.frustumCullingEnabled) this._frustum.setFromProjectionMatrix(this._viewProjection);

            // Per-frame statistics, reset here so a caller reading them after
            // render() sees this frame's numbers.
            this._drawCalls = 0;
            this._triangleCount = 0;
            this._culledObjects = 0;
            this._frameId++;

            // M9: the scene-wide environment map every standard material falls
            // back to (WebGLRenderer's `material.envMap || scene.environment`).
            // Resolved once per frame; a null slot means "no IBL this frame".
            this._envCube = scene.environment;
            // M25-R1 (D174): the pre-filtered ladder, resolved once per frame like
            // the cube itself. Scene state, not per-draw state -- the per-draw part
            // is only which LEVEL this material's roughness lands on.
            this._scenePrefiltered = scene.environmentPrefiltered;
            // M25: scene.environmentIntensity is scene state like the cube itself,
            // so it is read once per frame and folded into each standard draw's
            // environment intensity (envIntensityOf).
            this._sceneEnvIntensity = scene.environmentIntensity;
            // M27: LightProbe irradiance, resolved once per frame like the cube.
            // `_probeCube` is null when the scene carries no probe.
            this._resolveLightProbes(scene);

            this._collectLights(scene);

            // M7/M13 shadow prepass: render each shadow-casting directional
            // light's depth into its own map before the base pass samples it.
            // Shadow casters are a prefix of _dirLights (see _collectLights), so
            // slot i of the shadow arrays belongs to _dirLights[i].
            var shadowIndex:int;
            for (shadowIndex = 0; shadowIndex < this._shadowLightCount; shadowIndex++)
            {
                this._renderShadowPass(scene, this._dirLights[shadowIndex], shadowIndex);
            }

            // M20: Scene.background is drawn, not just cleared. A Color still
            // goes through clear() (M17/D113); a CubeTexture draws a skybox and
            // a 2D Texture draws one clip-space quad, both AFTER the clear so a
            // transparent-texel background composites onto the clear colour
            // exactly like three.js (WebGLBackground clears, then unshifts the
            // background mesh into the opaque list).
            // M20: Scene.background is drawn, not just cleared. A Color still
            // goes through clear() (M17/D113); a CubeTexture draws a skybox and
            // a 2D Texture draws one clip-space quad, both AFTER the clear so a
            // transparent-texel background composites onto the clear colour
            // exactly like three.js (WebGLBackground clears, then unshifts the
            // background mesh into the opaque list).
            this._renderBackground(scene, camera);

            // M20: scene fog. Resolved once per frame (it is scene state, not
            // per-draw state) and folded into the program variant key, so a
            // scene without fog emits exactly the pre-M20 sources.
            this._resolveFog(scene.fog, camera);
            // M19: culling / depth / blending are per-draw now
            // (_applyMaterialState reads Material.side/depthTest/depthWrite/
            // blending), so the pass only leaves a sane default behind for the
            // passes that do not draw meshes (the line program sets its own).
            this._context.setDepthTest(true, 'lessEqual');
            this._context.setCulling('front');

            // M10: collect the visible meshes once, split by `material.transparent`
            // (three.js WebGLRenderer projectObject: the split is the material's
            // `transparent` flag, not `opacity < 1`), and sort the transparent
            // list back-to-front.
            this._opaqueMeshes.length = 0;
            this._transparentMeshes.length = 0;
            this._lineObjects.length = 0;
            this._collectMeshes(scene);
            this._sortOpaqueMeshes();
            this._sortTransparentMeshes();

            // Base pass: ambient + directional light (the standard program).
            this._activePass = 0;
            this._activeLight = null;
            this._drawMeshes(this._opaqueMeshes);

            // Punctual passes: one additive pass per point/spot light. Depth is
            // tested (lessEqual) but NOT written so the base pass's depth buffer
            // stays authoritative; blending accumulates each light's direct
            // diffuse+specular onto the back buffer (three.js sums the punctual
            // contributions in its single pass; our per-light passes are the
            // equivalent sum -- recorded in three-borrow-map).
            //
            // M10 scope: punctual passes cover the OPAQUE list only. A
            // transparent draw accumulates its light in a single blend, so an
            // additive punctual pass over it would blend the light twice (once
            // through alpha, once additively). Transparent materials therefore
            // receive ambient + directional + IBL, the same subset three.js
            // sends to an object when no punctual light is in range. Recorded in
            // three-api-design.md §15.
            var i:int;
            var pc:int = this._pointLights.length;
            var sc:int = this._spotLights.length;
            if (pc > 0 || sc > 0)
            {
                this._context.setBlendFactors('one', 'one');
                this._context.setDepthTest(false, 'lessEqual');
                this._activePass = 1;
                for (i = 0; i < pc; i++)
                {
                    this._activeLight = this._pointLights[i];
                    this._drawMeshes(this._opaqueMeshes);
                }
                this._activePass = 2;
                for (i = 0; i < sc; i++)
                {
                    this._activeLight = this._spotLights[i];
                    this._drawMeshes(this._opaqueMeshes);
                }
                this._context.setBlendFactors('one', 'zero');
                this._context.setDepthTest(true, 'lessEqual');
            }
            this._activePass = 0;
            this._activeLight = null;

            // M11 line pass: after every lit/opaque pass so epipolar edges sit on
            // top of the surfaces they outline, but before the transparent pass
            // so glass in front of an edge still composites over it. Depth is
            // tested AND written (a hard edge is opaque geometry); culling is
            // disabled because the expanded quad's winding depends on the
            // projected segment direction, so it is always front-facing on one
            // side of a silhouette and back-facing on the other.
            if (this._lineObjects.length > 0)
            {
                this._drawLines();
            }

            // M10 transparent pass: back-to-front. M19: the blend factors and
            // the depth state now come from the MATERIAL (blending /
            // depthTest / depthWrite), so a glass stack that sets depthWrite =
            // false keeps testing depth without writing it, while
            // Material.blending selects the equation. Drawn after every opaque
            // and punctual pass so it composites over the finished image.
            if (this._transparentMeshes.length > 0)
            {
                this._drawMeshes(this._transparentMeshes);
                this._context.setBlendFactors('one', 'zero');
                this._context.setDepthTest(true, 'lessEqual');
            }
        }

        public function setSize(width:int, height:int):void
        {
            this._context.configureBackBuffer(width, height, 0, true);
        }

        // ------------------------------------------------------------------
        // M20: scene fog.
        //
        // Fog used to be a dead field with a one-shot diagnostic (M17/D114). It
        // is a real per-fragment mix: `fog_fragment.glsl.js` computes a factor
        // from the view depth and lerps the final LINEAR color toward the fog
        // color, BEFORE tone mapping and the output encode. Here the same mix is
        // emitted as AGAL at the end of the standard/unlit fragments, and the
        // scene state is uploaded once per draw into fc37..fc40.
        //
        // Divergences (three-api-design.md §25):
        //   * only the BASE pass applies fog -- the punctual additive passes
        //     would add the fog color once per light (the same reason they skip
        //     material blending, R37);
        //   * line/wireframe programs have no fog stage (their fragment is the
        //     shared unlit body without the block).
        // ------------------------------------------------------------------

        public static const FOG_NONE:int = 0;
        public static const FOG_LINEAR:int = 1;
        public static const FOG_EXP2:int = 2;
        // fc37..fc40: (near, far, density, 1/(far-near) | log2(e)) / (camPos.xyz, 1) /
        // (camForward.xyz, 3) / (fogColor.rgb, 0).
        public static const FOG_CONST:int = 37;

        // fc37.w -- the linear fog's depth scale. The fragment program computes
        // `(depth - near) * fc37.wwww` instead of dividing by `(far - near)`,
        // because that division is illegal AGAL: the operands of `sub` would be
        // two constants, which AIR rejects at upload (#3625 "Both are
        // constants") and which no CPU-side rewrite of the shader could fix --
        // the two policy halves are the CPU scale here and the `mul` in
        // `_fogBlock`. One definition, so the shader, the upload and the CPU
        // mirror in `fogFactorAt` cannot drift apart (they did once: the shader
        // switched to `mul fc37.wwww` while the upload still wrote 0, which
        // silently disabled fog in BOTH runtimes -- the same frame, the same
        // picture, and every probe still green, because `fogFactorAt` is its
        // own arithmetic).
        public static function linearFogScale(near:Number, far:Number):Number
        {
            var span:Number = far - near;
            // A zero span (a degenerate Fog) has no meaningful scale; report 0
            // so the factor degrades to "no fog" instead of Infinity.
            if (span == 0 || span != span) return 0;
            return 1 / span;
        }

        public static function fogModeOf(fog:Object):int
        {
            if (fog is Fog) return AGALRenderer.FOG_LINEAR;
            if (fog is FogExp2) return AGALRenderer.FOG_EXP2;
            return AGALRenderer.FOG_NONE;
        }

        // CPU mirror of the emitted block, so a probe can pin the shader against
        // a reference without a GPU. `depth` is the view-space depth (-mv.z).
        public static function fogFactorAt(mode:int, near:Number, far:Number,
                                           density:Number, depth:Number):Number
        {
            var t:Number;
            if (mode == AGALRenderer.FOG_LINEAR)
            {
                t = (depth - near) * AGALRenderer.linearFogScale(near, far);
                if (t < 0) t = 0;
                else if (t > 1) t = 1;
                // smoothstep(fogNear, fogFar, vFogDepth)
                return t * t * (3 - 2 * t);
            }
            if (mode == AGALRenderer.FOG_EXP2)
            {
                t = density * depth;
                return 1 - Math.exp(-(t * t));
            }
            return 0;
        }

        // Resolve Scene.fog once per frame into the constant block. The camera's
        // world matrix must already be current (render() updates it first).
        private function _resolveFog(fog:Object, camera:Camera):void
        {
            this._fogMode = AGALRenderer.packFogConstants(this._fogConst, fog,
                camera.matrixWorld.elements);
        }

        // Pure: fills `out[0..15]` (fc37..fc40) and returns the fog mode. Kept
        // static rather than inlined into _resolveFog so a probe can pin the
        // packing against the AGAL that reads it -- the one thing that could not
        // be checked before, and the one thing that broke: the shader reads
        // fc37.w while the upload wrote a literal 0.
        public static function packFogConstants(out:Vector.<Number>, fog:Object,
                                                 m:Vector.<Number>):int
        {
            var mode:int = AGALRenderer.fogModeOf(fog);
            if (mode == AGALRenderer.FOG_NONE) return mode;

            var near:Number = 1;
            var far:Number = 1000;
            var density:Number = 0;
            var color:Color = null;
            if (fog is Fog)
            {
                near = Fog(fog).near;
                far = Fog(fog).far;
                color = Fog(fog).color;
            }
            else
            {
                density = FogExp2(fog).density;
                color = FogExp2(fog).color;
            }

            out[0] = near;
            out[1] = far;
            out[2] = density;
            // w is the one per-fog scale the shader needs: 1/(far-near) for the
            // linear case (see linearFogScale), log2(e) for FogExp2 -- AGAL's
            // `exp` is base 2, so the shader has to carry e^x over to 2^x, and
            // doing it in the constant keeps it off the per-fragment path.
            out[3] = (mode == AGALRenderer.FOG_LINEAR)
                ? AGALRenderer.linearFogScale(near, far) : Math.LOG2E;

            // Column 3 of matrixWorld is the camera position, column 2 is its
            // +Z axis; `vFogDepth` grows along -Z (view space), so forward is
            // the negation of that column.
            out[4] = m[12];
            out[5] = m[13];
            out[6] = m[14];
            out[7] = 1;
            out[8] = -m[8];
            out[9] = -m[9];
            out[10] = -m[10];
            out[11] = 3;
            out[12] = color != null ? color.r : 0;
            out[13] = color != null ? color.g : 0;
            out[14] = color != null ? color.b : 0;
            out[15] = 0;
            return mode;
        }

        private function _uploadFogConstants():void
        {
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT,
                AGALRenderer.FOG_CONST, this._fogConst, 4);
        }

        // The AGAL fog block. Stage3D has no `smoothstep`, so the linear case is
        // spelled out (t*t*(3-2t)); FogExp2 needs one natural `exp` because the
        // backend exposes no base-2 opcode (D48 uses the same fact for the env
        // BRDF). `t0.xyz` holds the camera->fragment delta on entry and is dead
        // on exit; `t0.w` carries the view depth.
        private function _fogBlock(colorReg:String, t0:String, t1:String):String
        {
            if (this._fogMode == AGALRenderer.FOG_NONE) return '';

            var s:String =
                'sub ' + t0 + '.xyz, v1.xyz, fc38.xyz\n' +
                'dp3 ' + t0 + '.w, ' + t0 + '.xyz, fc39.xyz\n';

            if (this._fogMode == AGALRenderer.FOG_LINEAR)
            {
                s +=
                    'sub ' + t0 + '.y, ' + t0 + '.w, fc37.x\n' +       // d - near
                    // 1/(far-near) is precomputed on the CPU into fc37.w: AGAL
                    // forbids two constant source operands in one instruction
                    // (AIR #3625 "Both are constants"), and `far - near` would
                    // need exactly that. Same arithmetic, two instructions fewer.
                    'mul ' + t0 + '.y, ' + t0 + '.y, fc37.wwww\n' +    // (d-near)/(far-near)
                    'sat ' + t0 + '.y, ' + t0 + '.y\n' +               // t
                    'mul ' + t0 + '.z, ' + t0 + '.y, ' + t0 + '.y\n' + // t^2
                    'add ' + t0 + '.x, ' + t0 + '.y, ' + t0 + '.y\n' + // 2t
                    'sub ' + t0 + '.x, fc39.w, ' + t0 + '.x\n' +        // 3 - 2t
                    'mul ' + t0 + '.y, ' + t0 + '.z, ' + t0 + '.x\n';   // factor
            }
            else
            {
                // AGAL's `exp` is base 2 (measured: temp/agalprobe/Exp.as), while
                // three.js FogExp2 is 1 - exp(-density^2 * d^2) with e. The base
                // change is one extra multiply by fc37.w, which the linear case
                // uses for 1/(far-near) and FogExp2 otherwise leaves at 0.
                s +=
                    'mul ' + t0 + '.y, ' + t0 + '.w, fc37.z\n' +       // d * density
                    'mul ' + t0 + '.y, ' + t0 + '.y, ' + t0 + '.y\n' +  // squared
                    'neg ' + t0 + '.y, ' + t0 + '.y\n' +
                    'mul ' + t0 + '.y, ' + t0 + '.y, fc37.wwww\n' +     // * log2(e)
                    'exp ' + t0 + '.y, ' + t0 + '.y\n' +
                    'sub ' + t0 + '.y, fc38.w, ' + t0 + '.y\n';        // 1 - exp(...)
            }

            // mix(color, fogColor, f)
            return s +
                'sub ' + t0 + '.z, fc38.w, ' + t0 + '.y\n' +
                'mul ' + t1 + '.xyz, fc40.xyz, ' + t0 + '.yyyy\n' +
                'mul ' + colorReg + '.xyz, ' + colorReg + '.xyz, ' + t0 + '.zzzz\n' +
                'add ' + colorReg + '.xyz, ' + colorReg + '.xyz, ' + t1 + '.xyz\n';
        }

        // ------------------------------------------------------------------
        // ------------------------------------------------------------------
        // M20: Scene.background (Color / CubeTexture skybox / 2D Texture quad).
        //
        // three.js (WebGLBackground.js): a Color becomes the clear colour; a
        // CubeTexture is a unit box drawn at the camera position with
        // `side=BackSide, depthTest=false, depthWrite=false` and z pinned to the
        // far plane; a plain Texture is one clip-space quad sampling with the
        // texture's own uv matrix. The background is drawn FIRST, after the
        // clear, so a fully opaque background simply covers the clear.
        // ------------------------------------------------------------------

        private function _renderBackground(scene:Scene, camera:Camera):void
        {
            var bg:Object = scene.background;

            // M25: the background knobs are scene state read once per frame (the
            // same "one writer" shape the panel uses: the frame is what applies
            // them).
            this._bgIntensity = scene.backgroundIntensity;
            this._bgBlurriness = scene.backgroundBlurriness;

            if (bg is Color)
            {
                AGALRenderer.clearColorInto(this._clearVec, bg);
                this._context.clear(this._clearVec[0], this._clearVec[1], this._clearVec[2], 1);
                return;
            }

            // A texture background still clears first (three.js autoClear keeps
            // running; the background quad is just an opaque-list entry).
            this._context.clear(0, 0, 0, 1);

            if (bg is CubeTexture)
            {
                this._drawSkybox(CubeTexture(bg), camera);
                return;
            }
            if (bg is Texture)
            {
                this._drawBackgroundQuad(Texture(bg));
                return;
            }
            if (bg != null)
            {
                // RenderTarget / video backgrounds have no counterpart here.
                this._warnOnce("background",
                    "Scene.background of type " + bg + " is not implemented on this backend; " +
                    "clearing black instead (three-api-design.md 25)");
            }
        }

        private function _drawSkybox(cube:CubeTexture, camera:Camera):void
        {
            this._ensureBackgroundGeometry();

            var decode:Boolean = AGALRenderer.needsDecode(cube);
            var hdrScale:Number = cube.hdrScale > 0 ? cube.hdrScale : 1.0;
            // M25: an HDR bake is gamma-encoded linear radiance, so it needs decode
            // +scale+tone map (the M20 decode variant skips tone mapping by design).
            var hdr:Boolean = decode && hdrScale != 1.0;
            var blur:Boolean = this._bgBlurriness > 0;
            var program:Program3D;
            if (hdr)
            {
                // M25-R2: two blur tiers. `blurTapsFor` is the single source of
                // truth (a probe pins it without a GPU), so the program choice and
                // the documented semantics cannot drift apart.
                var taps:int = AGALRenderer.blurTapsFor(this._bgBlurriness);
                program = (taps == 0) ? this._bgCubeProgramHdr
                        : (taps == 5 ? this._bgCubeProgramHdrBlur : this._bgCubeProgramHdrBlur9);
            }
            else program = decode ? this._bgCubeProgramDecode : this._bgCubeProgramPlain;
            this._context.setProgram(program);

            // Rotation-only view: three.js copies the camera POSITION into the
            // box each frame (boxMesh.onBeforeRender -> matrixWorld.copyPosition)
            // so the skybox never translates with the camera.
            this._bgView.copy(camera.matrixWorld);
            var e:Vector.<Number> = this._bgView.elements;
            e[12] = 0;
            e[13] = 0;
            e[14] = 0;
            this._bgMatrix.multiplyMatrices(camera.projectionMatrix, this._bgView);
            this._bgMatrix3D.rawData = this._bgMatrix.elements;
            this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, this._bgMatrix3D, true);

            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 1, this._gammaVec, 1);
            this._uploadSrgbConstants();
            this._uploadToneConstants(0, 1);
            if (hdr)
            {
                // fc2 = (hdrScale * backgroundIntensity, blurRadius, 0, 0).
                // D156: the radius is an ANGLE (~0.5 rad at blurriness 1), not a
                // mip level -- this backend cannot select a cube LOD from AGAL.
                this._bgHdrConst[0] = hdrScale * this._bgIntensity;
                this._bgHdrConst[1] = this._bgBlurriness * AGALRenderer.BACKGROUND_BLUR_RADIUS;
                this._bgHdrConst[2] = 0;
                this._bgHdrConst[3] = 0;
                this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 2, this._bgHdrConst, 1);
                // fc3..fc6: the tap axes and both average weights (see
                // bgTapAxes). Only the blur tiers read them, but they are always
                // uploaded so a tier switch costs no extra state call.
                this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 3,
                    AGALRenderer.bgTapAxes, 4);
            }
            this._bindCubeTexture(cube, 0);

            this._context.setDepthTest(false, 'always');
            this._context.setBlendFactors('one', 'zero');
            // three.js backgroundCube uses side = BackSide: the camera sits
            // INSIDE the box, so the faces that survive are the back ones.
            this._context.setCulling('back');
            this._context.setVertexBufferAt(0, this._bgCubePositionBuffer, 0,
                Context3DVertexBufferFormat.FLOAT_3);
            this._context.drawTriangles(this._bgCubeIndexBuffer, 0, 12);
        }

        private function _drawBackgroundQuad(texture:Texture):void
        {
            this._ensureBackgroundGeometry();

            var decode:Boolean = AGALRenderer.needsDecode(texture);
            this._context.setProgram(decode ? this._bgPlaneProgramDecode : this._bgPlaneProgramPlain);

            // vc0 = (1,1,1,1): the quad's z/w are constant 1 (three.js
            // background.vertex.glsl.js: `gl_Position = vec4(position.xy, 1, 1)`).
            this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, this._bgConst, 1);
            // The texture's own matrix, i.e. the M18 block in slot 0
            // (WebGLBackground.js: `uvTransform.value.copy(background.matrix)`).
            AGALRenderer.uvRowsInto(this._uvRows, 0, AGALRenderer.uvMatrixOf(texture));
            this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX,
                AGALRenderer.UV_CONST_BASE, this._uvRows, 2);

            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 1, this._gammaVec, 1);
            this._uploadSrgbConstants();
            this._uploadToneConstants(0, 1);
            this._bindTexture(texture, 0);

            this._context.setDepthTest(false, 'always');
            this._context.setBlendFactors('one', 'zero');
            this._context.setCulling('none');
            this._context.setVertexBufferAt(0, this._bgQuadPositionBuffer, 0,
                Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(2, this._bgQuadUvBuffer, 0,
                Context3DVertexBufferFormat.FLOAT_2);
            this._context.drawTriangles(this._bgQuadIndexBuffer, 0, 2);
        }

        // Built once: a unit cube for the skybox (8 shared corners, 12
        // triangles, CCW outward) and a clip-space quad for a 2D background
        // texture.
        private function _ensureBackgroundGeometry():void
        {
            if (this._bgCubePositionBuffer != null) return;

            // Vector construction goes through Array literals because this
            // subset's Vector constructors only take (length, fixed).
            var corners:Vector.<Number> = AGALRenderer.numbersFrom([
                -0.5, -0.5, -0.5,    0.5, -0.5, -0.5,    0.5,  0.5, -0.5,   -0.5,  0.5, -0.5,
                -0.5, -0.5,  0.5,    0.5, -0.5,  0.5,    0.5,  0.5,  0.5,   -0.5,  0.5,  0.5]);
            var cubeSrc:Array = [
                4, 5, 6,  4, 6, 7,     // +Z
                1, 0, 3,  1, 3, 2,     // -Z
                5, 1, 2,  5, 2, 6,     // +X
                0, 4, 7,  0, 7, 3,     // -X
                3, 7, 6,  3, 6, 2,     // +Y
                0, 1, 5,  0, 5, 4];    // -Y
            var cubeIndices:Vector.<uint> = AGALRenderer.uintsFrom(cubeSrc);
            this._bgCubePositionBuffer = this._context.createVertexBuffer(8, 3);
            this._bgCubePositionBuffer.uploadFromVector(corners, 0, 8);
            this._bgCubeIndexBuffer = this._context.createIndexBuffer(36);
            this._bgCubeIndexBuffer.uploadFromVector(cubeIndices, 0, 36);

            var quad:Vector.<Number> = AGALRenderer.numbersFrom([
                -1, -1, 0,   1, -1, 0,   -1, 1, 0,   1, 1, 0]);
            var quadUv:Vector.<Number> = AGALRenderer.numbersFrom([
                0, 0,   1, 0,   0, 1,   1, 1]);
            var quadIndices:Vector.<uint> = AGALRenderer.uintsFrom([0, 1, 2,  2, 1, 3]);
            this._bgQuadPositionBuffer = this._context.createVertexBuffer(4, 3);
            this._bgQuadPositionBuffer.uploadFromVector(quad, 0, 4);
            this._bgQuadUvBuffer = this._context.createVertexBuffer(4, 2);
            this._bgQuadUvBuffer.uploadFromVector(quadUv, 0, 4);
            this._bgQuadIndexBuffer = this._context.createIndexBuffer(6);
            this._bgQuadIndexBuffer.uploadFromVector(quadIndices, 0, 6);
        }

        // Vector.<T> from an Array literal. The subset's Vector constructors
        // only accept (length, fixed), so a literal list must be copied in.
        private static function numbersFrom(src:Array):Vector.<Number>
        {
            var out:Vector.<Number> = new Vector.<Number>(src.length);
            for (var i:int = 0; i < src.length; i++) out[i] = Number(src[i]);
            return out;
        }

        private static function uintsFrom(src:Array):Vector.<uint>
        {
            var out:Vector.<uint> = new Vector.<uint>(src.length);
            for (var i:int = 0; i < src.length; i++) out[i] = uint(src[i]);
            return out;
        }

        // Background programs (three.js ShaderLib.backgroundCube / background).
        // `decode` marks an sRGB texture: three.js sets `toneMapped = false` in
        // that case, so the decode variant skips the tone-map block entirely.
        //
        // M25 adds a SIXTH shape next to that pair: `hdr` is an environment cube
        // baked by EquirectangularToCube (gamma-encoded LINEAR radiance plus an
        // hdrScale divisor). It has to decode, scale, and THEN tone map -- the only
        // combination the M20 pair cannot express. `blur` adds the D156 tap cone
        // for scene.backgroundBlurriness.
        private function _buildBackgroundProgram(isCube:Boolean, decode:Boolean,
                                                 hdr:Boolean = false, blur:Boolean = false,
                                                 blurWide:Boolean = false):Program3D
        {
            var vertexSrc:String;
            if (isCube)
            {
                // `gl_Position.z = gl_Position.w` pins the box to the far plane;
                // the clip position is built in vt0 because `op` is write-only.
                vertexSrc =
                    'dp4 vt0.x, va0, vc0\n' +
                    'dp4 vt0.y, va0, vc1\n' +
                    'dp4 vt0.z, va0, vc2\n' +
                    'dp4 vt0.w, va0, vc3\n' +
                    'mov vt0.z, vt0.w\n' +
                    'mov op, vt0\n' +
                    // transformDirection(position, modelMatrix) with a
                    // position-only model matrix: the local corner IS the
                    // direction (the cube is centred on the origin).
                    'mov v0, va0\n';
            }
            else
            {
                vertexSrc =
                    // Full write to the output register in one instruction (AIR
                    // #3701); the position is assembled in vt0 first.
                    'mov vt0.xy, va0.xy\n' +
                    'mov vt0.z, vc0.x\n' +
                    'mov vt0.w, vc0.x\n' +
                    'mov op, vt0\n' +
                    'dp4 v2.x, va2, vc40\n' +
                    'dp4 v2.y, va2, vc41\n' +
                    // AIR requires a varying to have ALL FOUR components written
                    // somewhere in the vertex program (#3633); the fragment samples
                    // v2.xy only, so .zw is padding. Measured on adl 51.4.1: the
                    // writes need not be in one instruction, they must merely cover
                    // xyzw between them.
                    'mov v2.zw, vc0.xxxx\n';
            }

            var fragSrc:String;
            if (hdr && blur && blurWide && isCube)
            {
                // M25-R2 wide tier: the same five taps plus +/-Y and the two XZ
                // diagonals (nine samples, weight 1/9 in fc6.w). The narrow tier
                // samples only the XZ cross, which at a large radius reads as four
                // ghosted copies instead of a blurred sky.
                fragSrc =
                    'tex ft4, v0.xyz, fs0 <cube,clamp,linear,mipnone>\n';
                var axes:Array = ['fc3', 'fc4', 'fc5', 'fc6'];
                var k:int;
                for (k = 0; k < axes.length; k++)
                {
                    var axis:String = String(axes[k]);
                    fragSrc +=
                        'mul ft5.xyz, ' + axis + '.xyz, fc2.yyy\n' +
                        'add ft6.xyz, v0.xyz, ft5.xyz\n' +
                        'tex ft6, ft6.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                        'add ft4.xyz, ft4.xyz, ft6.xyz\n' +
                        'sub ft6.xyz, v0.xyz, ft5.xyz\n' +
                        'tex ft6, ft6.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                        'add ft4.xyz, ft4.xyz, ft6.xyz\n';
                }
                fragSrc +=
                    // Full four-component write for the same #3647/#3648 reason the
                    // narrow tier documents below.
                    'mul ft0, ft4, fc6.wwww\n' +
                    // D177: the bake's storage curve is the sRGB OETF, so the
                    // decode here is the sRGB EOTF (fc41) -- the same pair every
                    // other sampled texture uses since D170.
                    AGALRenderer.srgbDecodeBlock('ft0', AGALRenderer.DECODE_MAP,
                        AGALRenderer.DECODE_MAP, 'ft1') +
                    'mul ft0.xyz, ft0.xyz, fc2.xxx\n' +
                    'mov ft0.w, ft4.wwww\n' +
                    this._toneMapBlock('ft0', 'ft1', 'ft2', 'ft3');
            }
            else if (hdr && blur && isCube)
            {
                // D156: five taps on a world-axis cross. A tangent frame would
                // need crs+nrm and degenerates at the poles (nrm of a zero vector);
                // a cube sample only reads a DIRECTION, so offsetting the direction
                // along fixed axes is enough and cannot produce a NaN. fc3 = (1,0,0,0),
                // fc4 = (0,0,1,1/5).
                fragSrc =
                    'tex ft4, v0.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                    'mul ft5.xyz, fc3.xyz, fc2.yyy\n' +
                    'add ft6.xyz, v0.xyz, ft5.xyz\n' +
                    'tex ft6, ft6.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                    'add ft4.xyz, ft4.xyz, ft6.xyz\n' +
                    'sub ft6.xyz, v0.xyz, ft5.xyz\n' +
                    'tex ft6, ft6.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                    'add ft4.xyz, ft4.xyz, ft6.xyz\n' +
                    'mul ft5.xyz, fc4.xyz, fc2.yyy\n' +
                    'add ft6.xyz, v0.xyz, ft5.xyz\n' +
                    'tex ft6, ft6.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                    'add ft4.xyz, ft4.xyz, ft6.xyz\n' +
                    'sub ft6.xyz, v0.xyz, ft5.xyz\n' +
                    'tex ft6, ft6.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                    'add ft4.xyz, ft4.xyz, ft6.xyz\n' +
                    // Full four-component write: `tex` is the only instruction
                    // above that fills .w, and `mov oc, ft0` reads xyzw -- a
                    // .xyz-only accumulate here is Error #3647/#3648
                    // ("ft0 is read before it is written") in BOTH validators.
                    'mul ft0, ft4, fc4.wwww\n' +
                    // D177: sRGB EOTF, matching the bake's OETF (see the wide tier).
                    AGALRenderer.srgbDecodeBlock('ft0', AGALRenderer.DECODE_MAP,
                        AGALRenderer.DECODE_MAP, 'ft1') +
                    'mul ft0.xyz, ft0.xyz, fc2.xxx\n' +
                    // ft4.w is the first tap's alpha (the adds above are .xyz),
                    // i.e. the cube's own alpha, which the plain path also keeps.
                    'mov ft0.w, ft4.wwww\n' +
                    this._toneMapBlock('ft0', 'ft1', 'ft2', 'ft3');
            }
            else if (hdr)
            {
                fragSrc =
                    'tex ft0, v0.xyz, fs0 <cube,clamp,linear,mipnone>\n' +
                    // D177: sRGB EOTF, matching the bake's OETF.
                    AGALRenderer.srgbDecodeBlock('ft0', AGALRenderer.DECODE_MAP,
                        AGALRenderer.DECODE_MAP, 'ft1') +
                    'mul ft0.xyz, ft0.xyz, fc2.xxx\n' +
                    this._toneMapBlock('ft0', 'ft1', 'ft2', 'ft3');
            }
            else
            {
                fragSrc = isCube
                    ? 'tex ft0, v0.xyz, fs0 <cube,clamp,linear,mipnone>\n'
                    : 'tex ft0, v2.xy, fs0 <2d,clamp,linear,mipnone>\n';
                if (decode)
                {
                    // D170/D177: this is an sRGB COLOR image (a background
                    // photo), so it takes the sRGB EOTF. The matching encode
                    // below makes the pair an exact identity, so an authored
                    // background image still shows its own pixels (no tone map
                    // here, by design: three.js sets toneMapped=false for this
                    // case). fc36 -- the D154 HDR-bake storage exponent -- is
                    // retired; the HDR path uses the same pair (D177).
                    fragSrc += AGALRenderer.srgbDecodeBlock('ft0',
                        AGALRenderer.DECODE_MAP, AGALRenderer.DECODE_MAP, 'ft1');
                }
                else
                {
                    fragSrc += this._toneMapBlock('ft0', 'ft1', 'ft2', 'ft3');
                }
            }
            fragSrc +=
                'sat ft0.xyz, ft0.xyz\n' +
                // D170: the sRGB OETF (fc41/fc42), not pow(x, 1/2.2).
                AGALRenderer.srgbEncodeBlock('ft0') +
                'mov oc, ft0\n';

            // AGAL 2 for the same reason as _buildBasicProgram: fc41/fc42 (sRGB)
            // and vc40/vc41 (the uv matrix) are past AGAL 1's 28-register file.
            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            vertex.assemble(Context3DProgramType.VERTEX, vertexSrc, AGAL_VERSION);
            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT, fragSrc, AGAL_VERSION);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            this._noteStreams(program, vertexSrc, fragSrc);
            return program;
        }

        // M10: tone mapping (three.js WebGLRenderer.toneMapping /
        // toneMappingExposure). NoToneMapping is the default, matching r187.
        //
        // These live on the concrete renderer rather than IRenderer because
        // tone mapping is a backend capability: three.js also exposes it on
        // WebGLRenderer, not on an abstract renderer interface.
        // ------------------------------------------------------------------

        public static const NoToneMapping:int = 0;
        public static const LinearToneMapping:int = 1;
        public static const ACESFilmicToneMapping:int = 2;

        public function get toneMapping():int
        {
            return this._toneMapping;
        }

        // Changing the operator changes the emitted fragment source (three.js
        // bakes TONE_MAPPING into the program too), so the programs are rebuilt
        // on the next render.
        public function set toneMapping(value:int):void
        {
            if (value < 0 || value > 2) value = AGALRenderer.NoToneMapping;
            if (value == this._toneMapping) return;
            this._toneMapping = value;
            this._programsDirty = true;
        }

        // Exposure alone is a constant, so it needs no rebuild.
        public function get toneMappingExposure():Number
        {
            return this._toneMappingExposure;
        }

        public function set toneMappingExposure(value:Number):void
        {
            this._toneMappingExposure = value;
        }

        private function _rebuildPrograms():void
        {
            this._programsDirty = false;
            this._basicVariants = new Dictionary();
            this._basicProgram = this._getBasicProgram(false, false, false);
            // M13: variants are cached by (dirs, shadows, decodeMask); a
            // tone-mapping change invalidates every one of them (tone is baked
            // into the source).
            this._standardVariants = new Dictionary();
            this._punctualVariants = new Dictionary();
            this._standardProgram = this._getStandardProgram(1, 0, 0, false, false, false);
            this._shadowProgram = this._buildShadowProgram();
            this._shadowAlphaProgram = this._buildShadowAlphaProgram();
            this._lineVariants = new Dictionary();
            this._lineProgram = this._getLineProgram(false, true);
            // M20: background programs. The decode variants SKIP tone mapping
            // exactly like three.js (`material.toneMapped = transfer !==
            // SRGBTransfer` for both background shaders), so they cannot share
            // a source with the plain ones.
            this._bgCubeProgramPlain = this._buildBackgroundProgram(true, false);
            this._bgCubeProgramDecode = this._buildBackgroundProgram(true, true);
            // M25: the HDR pair (see _buildBackgroundProgram).
            this._bgCubeProgramHdr = this._buildBackgroundProgram(true, true, true, false);
            this._bgCubeProgramHdrBlur = this._buildBackgroundProgram(true, true, true, true);
            this._bgCubeProgramHdrBlur9 = this._buildBackgroundProgram(true, true, true, true, true);
            this._bgPlaneProgramPlain = this._buildBackgroundProgram(false, false);
            this._bgPlaneProgramDecode = this._buildBackgroundProgram(false, true);
        }

        // M20: MeshBasicMaterial variants. `map` adds the fs0 fetch plus the
        // uv-transform rows, `decode` the sRGB pow, `fog` the fog mix; a
        // colour-only unlit draw still compiles the exact M1 source.
        private function _getBasicProgram(map:Boolean, decode:Boolean, fog:Boolean,
                                          toneMapped:Boolean = true):Program3D
        {
            var key:String = (map ? "1" : "0") + ":" + (decode ? "1" : "0") + ":" +
                (fog ? "1" : "0") + ":" + (toneMapped ? "1" : "0");
            var program:Program3D = Program3D(this._basicVariants[key]);
            if (program == null)
            {
                program = this._buildBasicProgram(map, decode, fog, toneMapped);
                this._basicVariants[key] = program;
            }
            return program;
        }

        // Lazy standard-program variant lookup. `dirs` = how many directional
        // lights the base pass sums (1 when the scene has none: the light color
        // is zeroed), `shadows` = how many of them sample a shadow map (always
        // a PREFIX of the light list, see _collectLights), `decode` = M17/D171's
        // 5-bit color-space mask (1 map, 2 emissive, 4 environment, 8 roughness,
        // 16 metalness).
        private function _getStandardProgram(dirs:int, shadows:int, decode:int, flat:Boolean,
                                             fog:Boolean, prefiltered:Boolean = false):Program3D
        {
            if (dirs < 1) dirs = 1;
            if (dirs > AGALRenderer.MAX_DIR_LIGHTS) dirs = AGALRenderer.MAX_DIR_LIGHTS;
            if (shadows < 0) shadows = 0;
            if (shadows > shadowsLimit(dirs)) shadows = shadowsLimit(dirs);
            if (decode < 0) decode = 0;
            if ((decode & ~AGALRenderer.DECODE_MAPS_ALL) != 0) {
                // No slot above fs7 carries data the standard program decodes;
                // ignore stray bits rather than compile a variant nothing can
                // select.
                decode &= AGALRenderer.DECODE_MAPS_ALL;
            }
            // M19: `flat` (material.flatShading) is part of the variant identity
            // -- it swaps the interpolated geometric normal for a derivative-
            // based face normal, so it changes the emitted source. M20 adds the
            // fog bit for the same reason. M25-R1 adds `prefiltered`: with a
            // pre-filtered ladder the environment slot already holds the blurred
            // level, so the M9 stand-in -- refetch at N and mix by roughness^4 --
            // is not emitted at all. That is a source-level change, so it is a
            // variant, not a uniform.
            var key:String = dirs + ":" + shadows + ":" + decode + ":" + (flat ? "1" : "0") +
                             ":" + (fog ? "1" : "0") + ":" + (prefiltered ? "1" : "0");
            var program:Program3D = Program3D(this._standardVariants[key]);
            if (program == null)
            {
                program = this._buildStandardProgram(dirs, shadows, decode, flat, fog, prefiltered);
                this._standardVariants[key] = program;
            }
            return program;
        }

        // M17: punctual (point/spot) programs, keyed by light kind and by the
        // base-color decode bit only -- a punctual pass has no environment or
        // emissive term to decode.
        private function _getPunctualProgram(isSpot:Boolean, decodeMap:Boolean, flat:Boolean):Program3D
        {
            var key:String = (isSpot ? "1" : "0") + ":" + (decodeMap ? "1" : "0") + ":" + (flat ? "1" : "0");
            var program:Program3D = Program3D(this._punctualVariants[key]);
            if (program == null)
            {
                program = this._buildPunctualProgram(isSpot, decodeMap, flat);
                this._punctualVariants[key] = program;
            }
            return program;
        }

        // A light can only cast a shadow if the base pass evaluates it.
        private function shadowsLimit(dirs:int):int
        {
            return dirs < AGALRenderer.MAX_SHADOW_LIGHTS ? dirs : AGALRenderer.MAX_SHADOW_LIGHTS;
        }

        // Tone-map block, emitted immediately before the R7 sRGB encode of the
        // linear color in `colorReg`. `t0..t2` must be dead temporaries.
        //
        // three.js tonemapping_fragment.glsl.js:9 applies toneMapping() to
        // gl_FragColor.rgb and the colour-space conversion happens after it, so
        // tone mapping must see LINEAR radiance -- putting it after the pow()
        // encode would apply ACES to sRGB values and wash the image out.
        private function _toneMapBlock(colorReg:String, t0:String, t1:String, t2:String):String
        {
            if (this._toneMapping == AGALRenderer.NoToneMapping) return '';

            if (this._toneMapping == AGALRenderer.LinearToneMapping)
            {
                // saturate(toneMappingExposure * color), tonemapping_pars_fragment.glsl.js:10-14
                return 'mul ' + colorReg + '.xyz, ' + colorReg + '.xyz, fc14.xxx\n';
            }

            return AGALRenderer.acesToneMapSnippet(colorReg, t0, t1, t2);
        }

        // The ACESFilmicToneMapping snippet, in isolation. Public so
        // probes/alpha-smoke-m10 can assemble and numerically model the EXACT
        // sequence the renderer emits instead of a hand-copied mirror of it.
        //
        // ACESFilmicToneMapping (tonemapping_pars_fragment.glsl.js:46-73):
        //   c = ACESInputMat * (color * (exposure / 0.6))
        //   a = c*(c + 0.0245786) - 0.000090537
        //   b = c*(0.983729*c + 0.4329510) + 0.238081
        //   color = ACESOutputMat * (a / b), saturated
        // The 1/0.6 pre-scale is part of the r187 operator (it brightens the
        // viewing environment), so fc14.x already holds exposure/0.6.
        public static function acesToneMapSnippet(colorReg:String, t0:String, t1:String, t2:String):String
        {
            return 'mul ' + t0 + '.xyz, ' + colorReg + '.xyz, fc14.xxx\n' +
                'dp3 ' + t1 + '.x, ' + t0 + '.xyz, fc16.xyz\n' +
                'dp3 ' + t1 + '.y, ' + t0 + '.xyz, fc17.xyz\n' +
                'dp3 ' + t1 + '.z, ' + t0 + '.xyz, fc18.xyz\n' +
                // a
                'add ' + t2 + '.xyz, ' + t1 + '.xyz, fc14.yyy\n' +
                'mul ' + t2 + '.xyz, ' + t1 + '.xyz, ' + t2 + '.xyz\n' +
                'add ' + t2 + '.xyz, ' + t2 + '.xyz, fc14.zzz\n' +
                // b
                'mul ' + t0 + '.xyz, ' + t1 + '.xyz, fc14.www\n' +
                'add ' + t0 + '.xyz, ' + t0 + '.xyz, fc15.xxx\n' +
                'mul ' + t0 + '.xyz, ' + t1 + '.xyz, ' + t0 + '.xyz\n' +
                'add ' + t0 + '.xyz, ' + t0 + '.xyz, fc15.yyy\n' +
                // a / b (AGAL has no div; rcp then mul)
                'rcp ' + t0 + '.xyz, ' + t0 + '.xyz\n' +
                'mul ' + t2 + '.xyz, ' + t2 + '.xyz, ' + t0 + '.xyz\n' +
                'dp3 ' + t1 + '.x, ' + t2 + '.xyz, fc19.xyz\n' +
                'dp3 ' + t1 + '.y, ' + t2 + '.xyz, fc20.xyz\n' +
                'dp3 ' + t1 + '.z, ' + t2 + '.xyz, fc21.xyz\n' +
                'sat ' + colorReg + '.xyz, ' + t1 + '.xyz\n';
        }

        // Alpha test (three.js alphatest_fragment.glsl.js:11: `if (a < alphaTest)
        // discard`). AGAL's `kil` discards when ANY component of the source is
        // negative, so the register is filled uniformly with a - alphaTest
        // rather than relying on a swizzle. `reg` must be a dead temporary.
        //
        // three.js smooths the cut with fwidth(); AGAL has no derivative opcode
        // for scalars, so this is a hard cut -- recorded in three-api-design.md
        // §15.
        public static function alphaTestSnippet(reg:String, alphaSwizzle:String):String
        {
            // AIR rejects a `kil` whose source has no explicit swizzle
            // (#3703 "Source swizzle must be scalar") -- it is accepted silently
            // by as-aot, which is exactly the kind of divergence that renders a
            // black frame in AIR only. The register is filled uniformly, so the
            // scalar swizzle is also what the comment above intends.
            return 'sub ' + reg + ', ' + alphaSwizzle + ', fc15.zzzz\n' +
                'kil ' + reg + '.xxxx\n';
        }

        private function _alphaTestBlock(reg:String, alphaSwizzle:String):String
        {
            return AGALRenderer.alphaTestSnippet(reg, alphaSwizzle);
        }

        // fc14..fc21 upload: exposure and alphaTest/opacity are per draw.
        private function _uploadToneConstants(alphaTest:Number, opacity:Number):void
        {
            var expo:Number = this._toneMappingExposure;
            // ACES pre-scales by 1/0.6 inside the operator.
            this._toneVec[0] = (this._toneMapping == AGALRenderer.ACESFilmicToneMapping) ? expo / 0.6 : expo;
            this._toneVec[6] = alphaTest;
            this._toneVec[7] = opacity;
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 14, this._toneVec, 8);
        }

        // D170: fc41/fc42 carry the sRGB transfer-function constants. Uploaded
        // right after a program's own block because Stage3D keeps fragment
        // constants per PROGRAM: a program that is bound without them reads
        // zeros, and pow(x, 0) is 1.0 (i.e. a white frame, not a silent no-op).
        private function _uploadSrgbConstants():void
        {
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT,
                AGALRenderer.SRGB_CONST, this._srgbConstVec, 2);
        }

        // ------------------------------------------------------------------
        // M27: light probes.
        // ------------------------------------------------------------------

        // Gather the scene's LightProbes and bake their summed irradiance into one
        // cube (see LightProbeGenerator.toIrradianceCube). Re-baked only when the
        // probe set or a probe's `version` changes, so a static probe costs one
        // bake for the lifetime of the renderer.
        //
        // WHY ONE CUBE AND NOT SH IN THE SHADER (D176): a faithful SH9 evaluation
        // is ~40 AGAL instructions. The standard fragment program has ~90 left
        // with M25-R1 already spending its share on the roughness prefilter, and
        // the eight fragment samplers are all spoken for, so the SH is evaluated
        // here instead -- on 6*16*16 directions rather than per pixel. The shader
        // sees an irradiance cube through the environment slot it already samples.
        private function _resolveLightProbes(root:Object3D):void
        {
            var probes:Vector.<LightProbe> = this._probeScratch;
            probes.length = 0;
            AGALRenderer.collectProbes(root, probes);

            var n:int = probes.length;
            if (n == 0)
            {
                this._probeCube = null;
                this._probeCache.length = 0;
                this._probeVersionCache.length = 0;
                return;
            }

            if (this._probeCube != null && n == this._probeCache.length)
            {
                var same:Boolean = true;
                var i:int;
                for (i = 0; i < n; i++)
                {
                    if (this._probeCache[i] != probes[i] ||
                        this._probeVersionCache[i] != probes[i].version)
                    {
                        same = false;
                        break;
                    }
                }
                if (same) return;
            }

            // A probe's irradiance adds: three.js sums every probe into
            // `irradiance` (lights_fragment_begin.glsl.js:224-232). Summing the SH
            // first is the same thing (the evaluation is linear) and costs one bake
            // instead of one per probe.
            var acc:SphericalHarmonics3 = new SphericalHarmonics3();
            var k:int;
            for (k = 0; k < n; k++) acc.addScaledSH(probes[k].sh, probes[k].intensity);
            var merged:LightProbe = new LightProbe(acc, 1.0);
            this._probeCube = LightProbeGenerator.toIrradianceCube(
                merged, LightProbeGenerator.IRRADIANCE_FACE_SIZE);

            this._probeCache.length = 0;
            this._probeVersionCache.length = 0;
            for (k = 0; k < n; k++)
            {
                this._probeCache.push(probes[k]);
                this._probeVersionCache.push(probes[k].version);
            }

            // Loud, once, and only when it actually loses information: the probe
            // needs the environment sampler slot, and an environment already owns
            // it. Silently dropping the probe would make a scene that "has a light
            // probe" render as if it did not.
            if (this._envCube != null || this._scenePrefiltered != null)
            {
                this._warnOnce("probe-vs-env",
                    "M27 LightProbe ignored: this scene also has scene.environment, and " +
                    "the standard program has one environment sampler (fs7) for both. " +
                    "Use the probe OR the environment map for indirect diffuse.");
            }
        }

        private static function collectProbes(object:Object3D, out:Vector.<LightProbe>):void
        {
            var probe:LightProbe = object as LightProbe;
            if (probe != null) out.push(probe);
            var children:Vector.<Object3D> = object.children;
            var i:int;
            for (i = 0; i < children.length; i++)
            {
                AGALRenderer.collectProbes(children[i], out);
            }
        }

        // ------------------------------------------------------------------
        // Light collection (M2: one directional + accumulated ambient; M6:
        // up to 4 point + 2 spot lights for the additive punctual passes).
        // ------------------------------------------------------------------

        private function _collectLights(root:Object3D):void
        {
            this._ambientColor.setRGB(0, 0, 0);
            this._dirLights.length = 0;
            this._pointLights.length = 0;
            this._spotLights.length = 0;
            this._collectLightsRecursive(root);

            // M13: shadow casters must occupy a PREFIX of the light list so the
            // fragment's shadow sample index matches the light it attenuates
            // (variant `dirs:shadows`). A stable partition keeps author order
            // within each group.
            var casters:Vector.<DirectionalLight> = new Vector.<DirectionalLight>();
            var plain:Vector.<DirectionalLight> = new Vector.<DirectionalLight>();
            var i:int;
            var n:int = this._dirLights.length;
            for (i = 0; i < n; i++)
            {
                var light:DirectionalLight = this._dirLights[i];
                if (AGALRenderer.castsShadow(light) && casters.length < AGALRenderer.MAX_SHADOW_LIGHTS) casters.push(light);
                else plain.push(light);
            }
            this._dirLights.length = 0;
            for (i = 0; i < casters.length; i++) this._dirLights.push(casters[i]);
            for (i = 0; i < plain.length; i++) this._dirLights.push(plain[i]);
            this._shadowLightCount = casters.length;
            this._dirLight = this._dirLights.length > 0 ? this._dirLights[0] : null;
        }

        // A directional light casts a shadow when it asks for one and carries a
        // shadow config; the renderer separately caps how many maps it will own.
        public static function castsShadow(light:DirectionalLight):Boolean
        {
            return light.castShadow && light.shadow != null;
        }

        private function _collectLightsRecursive(object:Object3D):void
        {
            if (object is AmbientLight)
            {
                var amb:AmbientLight = AmbientLight(object);
                this._ambientColor.r += amb.color.r * amb.intensity;
                this._ambientColor.g += amb.color.g * amb.intensity;
                this._ambientColor.b += amb.color.b * amb.intensity;
            }
            else if (object is DirectionalLight)
            {
                // M13: up to MAX_DIR_LIGHTS directional lights are summed by the
                // base pass; extras are ignored (they would need a third direct
                // block, see three-api-design.md §18).
                if (this._dirLights.length < AGALRenderer.MAX_DIR_LIGHTS)
                {
                    this._dirLights.push(DirectionalLight(object));
                }
            }
            else if (object is PointLight)
            {
                // Up to 4 point lights per frame (AGAL additive pass budget).
                if (this._pointLights.length < 4) this._pointLights.push(PointLight(object));
            }
            else if (object is SpotLight)
            {
                // Up to 2 spot lights per frame (AGAL additive pass budget).
                if (this._spotLights.length < 2) this._spotLights.push(SpotLight(object));
            }

            var children:Vector.<Object3D> = object.children;
            var n:int = children.length;
            for (var i:int = 0; i < n; i++)
            {
                this._collectLightsRecursive(children[i]);
            }
        }

        // ------------------------------------------------------------------
        // M7 shadow pass: depth-only render into the directional light's map.
        // ------------------------------------------------------------------

        // AIR rejects a sampler still bound to a slot the current fragment
        // program never samples (#3697). The shadow programs sample nothing, so
        // the pass clears the main pass's leftovers first; every textured draw
        // re-binds its own slots anyway (there is no binding cache).
        private function _unbindAllSamplers():void
        {
            for (var si:int = 0; si < AGALRenderer.MAX_SAMPLER_SLOTS; si++)
            {
                this._context.setTextureAt(si, null);
            }
        }

        private function _renderShadowPass(scene:Scene, dirLight:DirectionalLight, index:int):void
        {
            var shadow:DirectionalLightShadow = dirLight.shadow;
            var shadowCam:OrthographicCamera = shadow.camera;

            // Position the shadow camera at the light and aim it at the light
            // target (LightShadow.updateMatrices r187:213-222).
            this._tmpA.setFromMatrixPosition(dirLight.matrixWorld);
            shadowCam.position.copy(this._tmpA);
            this._tmpB.setFromMatrixPosition(dirLight.target.matrixWorld);
            shadowCam.lookAt(this._tmpB.x, this._tmpB.y, this._tmpB.z);
            shadowCam.updateMatrixWorld(true);
            shadowCam.updateMatrixWorldInverse();

            // shadowVP = projection * viewInverse; shadow.matrix = bias * shadowVP
            // (LightShadow._updateMatrix r187:256-264).
            this._shadowVP.multiplyMatrices(shadowCam.projectionMatrix, shadowCam.matrixWorldInverse);
            this._setShadowBiasMatrix();
            shadow.matrix.multiplyMatrices(this._shadowBias, this._shadowVP);
            this._shadowMatrix.copy(shadow.matrix);

            // (Re)create THIS light's shadow map when mapSize changes. M13 owns
            // one map per shadow-casting light, so every slot is (re)sized
            // independently.
            var w:int = shadow.mapSize.x;
            var h:int = shadow.mapSize.y;
            var tex:flash.display3D.textures.Texture = this._shadowMaps[index];
            if (tex == null || this._shadowMapW[index] != w || this._shadowMapH[index] != h)
            {
                tex = this._context.createTexture(w, h, Context3DTextureFormat.BGRA, true);
                this._shadowMaps[index] = tex;
                this._shadowMapW[index] = w;
                this._shadowMapH[index] = h;
                shadow.map = null; // the Texture wrapper is renderer-owned
            }

            // Depth-only render into the shadow map. Clear color to 1 (farthest
            // depth in the [0,1] encoding) and depth to 1 so unoccluded texels
            // stay "far" and never cast a false shadow.
            this._context.setRenderToTexture(tex, true);
            // Depth programs sample nothing: clear the slots the main pass left
            // bound before the first shadow draw (AIR #3697).
            this._unbindAllSamplers();
            this._context.clear(1, 1, 1, 1, 1.0, 0, 3);
            this._context.setDepthTest(true, 'lessEqual');
            this._context.setCulling('front');
            // M19: the previous frame's / previous pass's material blend state
            // must not leak into the depth target -- the packed depth is
            // written through the COLOR output, so additive or alpha blending
            // here would corrupt every shadow lookup. Resetting is required
            // now that blend factors are per material rather than per pass.
            this._context.setBlendFactors('one', 'zero');
            this._shadowPassActive = -1;
            this._renderShadowObject(scene);
            this._context.setRenderToBackBuffer();
        }

        // M13: pick the depth program for one caster. A material with an
        // alphaTest and geometry with uvs renders through the cutout program,
        // which samples the base-color texel and discards below the threshold
        // (three.js gives casters a depth material carrying alphaTest/alphaMap;
        // D89). Everything else takes the cheaper position-only program.
        private function _selectShadowProgram(mesh:Mesh):int
        {
            return AGALRenderer.shadowDepthKind(mesh.material, mesh.geometry);
        }

        // 0 = position-only depth program, 1 = the alpha-cutout variant. Public
        // so the probe can pin the rule without a GPU (three.js gives casters a
        // depth material that honours alphaTest, D89).
        public static function shadowDepthKind(material:Material, geometry:BufferGeometry):int
        {
            if (material != null && material.alphaTest > 0 && geometry != null
                && geometry.getAttribute('uv') != null)
            {
                return 1;
            }
            return 0;
        }

        private function _bindShadowProgram(mesh:Mesh):void
        {
            var which:int = this._selectShadowProgram(mesh);
            if (which != this._shadowPassActive)
            {
                this._shadowPassActive = which;
                var shadowProg:Program3D = (which == 1) ? this._shadowAlphaProgram : this._shadowProgram;
                this._context.setProgram(shadowProg);
                this._curStreamMask = this._streamsOf(shadowProg);
                this._curSamplerMask = this._samplersOf(shadowProg);
                // fc1 = (255, 1/255, 0, 1): the depth-packing scales (M13) and
                // the shadow map's output alpha. Both depth programs need it.
                this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 1, this._shadowPackConst, 1);
                if (which == 0)
                {
                    this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._shadowConst, 1);
                }
            }
            if (which == 1)
            {
                var material:Material = mesh.material;
                this._shadowPassAlphaConst[0] = material.alphaTest;
                this._shadowPassAlphaConst[1] = material.opacity;
                this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._shadowPassAlphaConst, 1);
                // Only the standard material carries a base-color map; a basic
                // material cuts out on opacity alone (the neutral white texel
                // keeps alpha = opacity).
                var cutMap:Texture = material is MeshStandardMaterial ? MeshStandardMaterial(material).map : null;
                this._bindTexture(cutMap, 0);
                // M18: feed the map slot's uv transform to the cutout vertex
                // program (vc40/vc41). Two registers, not the whole block -- this
                // program samples one texture.
                AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_MAP * 8,
                    AGALRenderer.uvMatrixOf(cutMap));
                this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX,
                    AGALRenderer.UV_CONST_BASE, this._uvRows, 2);
            }
        }

        // NDC [-1,1] -> [0,1] shadow-space bias matrix (WebGL coordinate system,
        // LightShadow._updateMatrix r187:256-264, scaleX=scaleY=1 with no atlas).
        private function _setShadowBiasMatrix():void
        {
            var e:Vector.<Number> = this._shadowBias.elements;
            // Map clip-space x/y from [-1,1] to [0,1] texture coords. The x
            // column is 0.5*scale + 0.5*offset. The y column is *negated*
            // (-0.5*scale + 0.5*offset): Metal's framebuffer/texture origin is
            // top-left while the NDC y axis grows upward, so the WebGL-style
            // y remap would mirror the shadow vertically. The z column stays
            // identity: the shadow camera is orthographic in the [0,1] depth
            // convention (Matrix4.makeOrthographic), so the shadow-space depth
            // is already [0,1] and must NOT be remapped.
            e[0] = 0.5; e[1] = 0;   e[2] = 0;   e[3] = 0;
            e[4] = 0;   e[5] = -0.5; e[6] = 0;   e[7] = 0;
            e[8] = 0;   e[9] = 0;   e[10] = 1;  e[11] = 0;
            e[12] = 0.5; e[13] = 0.5; e[14] = 0; e[15] = 1;
        }

        // Depth-only scene walk: uploads only position + index (shadow needs no
        // normal/uv) and draws with the shadow program + shadow MVP.
        private function _renderShadowObject(object:Object3D):void
        {
            // M20: a hidden subtree casts no shadow. three.js returns from the
            // shadow walk on `object.visible === false`
            // (WebGLShadowMap.js:522) BEFORE recursing, so setting
            // `group.visible = false` removes the whole branch from the map.
            // This port only checked `mesh.visible`, so an invisible Group kept
            // its children's shadows alive -- a shadow with no visible caster.
            if (!object.visible) return;

            if (object is Mesh)
            {
                var mesh:Mesh = Mesh(object);
                // Only casters enter the shadow map (WebGLShadowMap.render:
                // `if (object.castShadow)`). M7 drew every visible mesh, which
                // made `castShadow` advisory and put receivers into the map
                // themselves; M13 makes the flag authoritative.
                if (mesh.visible && mesh.castShadow)
                {
                    var geometry:BufferGeometry = mesh.geometry;
                    if (geometry != null)
                    {
                        var position:BufferAttribute = geometry.getAttribute('position');
                        if (position != null)
                        {
                            // M12: deform before the shadow pass reads the vertex
                            // buffer (a skinned mesh must cast a posed shadow).
                            mesh.updateDeform(this._frameId);
                            var resources:GPUMeshResources = GPUMeshResources(this._cache[mesh]);
                            if (resources == null)
                            {
                                resources = new GPUMeshResources();
                                this._cache[mesh] = resources;
                            }

                            if (resources.vertexBuffer == null || resources.positionVersion != position.version)
                            {
                                resources.vertexBuffer = this._context.createVertexBuffer(position.count, position.itemSize);
                                resources.vertexBuffer.uploadFromVector(position.array, 0, position.count);
                                resources.positionVersion = position.version;
                            }

                            var index:BufferAttribute = geometry.index;
                            var numTriangles:int;
                            var firstIndex:int;
                            var totalIndices:int;
                            if (index != null)
                            {
                                if (resources.indexBuffer == null || resources.indexVersion != index.version)
                                {
                                    resources.indexBuffer = this._context.createIndexBuffer(index.count);
                                    resources.indexBuffer.uploadFromVector(this._toUintVector(index), 0, index.count);
                                    resources.indexVersion = index.version;
                                }
                                totalIndices = index.count;
                            }
                            else
                            {
                                // Non-indexed: synthesize a sequential index buffer
                                // (same safety net as _renderMesh).
                                if (resources.indexBuffer == null || resources.indexVersion != position.version)
                                {
                                    var vcount:int = position.count;
                                    var seq:Vector.<uint> = new Vector.<uint>(vcount);
                                    for (var j:int = 0; j < vcount; j++) seq[j] = j;
                                    resources.indexBuffer = this._context.createIndexBuffer(vcount);
                                    resources.indexBuffer.uploadFromVector(seq, 0, vcount);
                                    resources.indexVersion = position.version;
                                }
                                totalIndices = position.count;
                            }
                            // M20: the caster respects geometry.drawRange too (a
                            // trimmed geometry casts the shadow of what it draws).
                            firstIndex = AGALRenderer.drawFirstIndex(geometry);
                            numTriangles = AGALRenderer.drawNumTriangles(geometry, totalIndices);
                            if (numTriangles > 0)
                            {
                                // shadowMVP = shadowVP * modelWorld (uploaded as vc0..vc3).
                                this._mvp.multiplyMatrices(this._shadowVP, mesh.matrixWorld);
                                this._matrix3D.rawData = this._mvp.elements;
                                this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, this._matrix3D, true);

                                // M13: cutout casters use the alphaTest program, which
                                // also reads the uv attribute (va2).
                                this._bindShadowProgram(mesh);
                                if (this._shadowPassActive == 1)
                                {
                                    var uv:BufferAttribute = geometry.getAttribute('uv');
                                    if (resources.uvBuffer == null || resources.uvVersion != uv.version)
                                    {
                                        resources.uvBuffer = this._context.createVertexBuffer(uv.count, uv.itemSize);
                                        resources.uvBuffer.uploadFromVector(uv.array, 0, uv.count);
                                        resources.uvVersion = uv.version;
                                    }
                                }
                                // Depth-only programs read va0 alone; binding the
                                // normal/uv streams anyway is what AIR rejects with
                                // #3607, so the same mask drives the binding here.
                                this._bindMeshStreams(resources);
                                // M19: a BackSide / DoubleSide caster renders the
                                // faces the author asked for (shadowCullingFor maps
                                // BackSide to the backend's back-face cull and
                                // DoubleSide to no culling). FrontSide keeps the
                                // pre-M19 front-face path -- see the note there.
                                this._context.setCulling(AGALRenderer.shadowCullingFor(
                                    mesh.material != null ? mesh.material.side : Material.FrontSide));
                                this._context.drawTriangles(resources.indexBuffer, firstIndex, numTriangles);
                            }
                        }
                    }
                }
            }

            var children:Vector.<Object3D> = object.children;
            var cn:int = children.length;
            for (var ci:int = 0; ci < cn; ci++)
            {
                this._renderShadowObject(children[ci]);
            }
        }

        // ------------------------------------------------------------------
        // M10: draw-list collection and ordering.
        // ------------------------------------------------------------------

        private function _collectMeshes(object:Object3D):void
        {
            // M11: frustum culling. three.js tests object.frustumCulled in
            // projectObject and skips the subtree there; a culled Mesh keeps its
            // CHILDREN visible (a Group's children are separate objects), which
            // is why the rejection only skips the object's own push and still
            // recurses.
            var visible:Boolean = true;
            if (object.visible)
            {
                if (object is Mesh)
                {
                    var mesh:Mesh = Mesh(object);
                    if (mesh.material != null && mesh.material.visible)
                    {
                        if (this._isCulled(mesh))
                        {
                            this._culledObjects++;
                        }
                        else if (mesh.material.transparent)
                        {
                            this._transparentMeshes.push(mesh);
                        }
                        else
                        {
                            this._opaqueMeshes.push(mesh);
                        }
                    }
                }
                else if (object is LineSegments)
                {
                    var lines:LineSegments = LineSegments(object);
                    if (lines.material != null && lines.material.visible && lines.geometry != null)
                    {
                        if (this._isCulledObject(lines))
                        {
                            this._culledObjects++;
                        }
                        else
                        {
                            this._lineObjects.push(lines);
                        }
                    }
                }
            }
            else
            {
                visible = false;
            }

            if (!visible) return;

            var children:Vector.<Object3D> = object.children;
            var n:int = children.length;
            for (var i:int = 0; i < n; i++)
            {
                this._collectMeshes(children[i]);
            }
        }

        // three.js Frustum.intersectsObject against a Mesh's bounding sphere.
        private function _isCulled(mesh:Mesh):Boolean
        {
            if (!this.frustumCullingEnabled || !mesh.frustumCulled) return false;
            return !this._frustum.intersectsObject(mesh);
        }

        // Same test for a LineSegments (which is not a Mesh, so the Frustum
        // overload for Mesh cannot take it; the sphere is grown identically).
        private function _isCulledObject(object:Object3D):Boolean
        {
            if (!this.frustumCullingEnabled || !object.frustumCulled) return false;
            var lines:LineSegments = LineSegments(object);
            var geometry:BufferGeometry = lines.geometry;
            if (geometry == null) return false;
            if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
            if (geometry.boundingSphere == null || geometry.boundingSphere.isEmpty()) return false;

            this._cullSphere.copy(geometry.boundingSphere).applyMatrix4(lines.matrixWorld);
            return !this._frustum.intersectsSphere(this._cullSphere);
        }

        // ---- M11 statistics (three.js renderer.info.render) ----

        // Records which generic streams the freshly built vertex program reads.
        // Scanning the emitted AGAL is exact here: the source is generated, so
        // `vaN` can only appear as a real attribute reference.
        private function _noteStreams(program:Program3D, vertexSrc:String, fragSrc:String):void
        {
            var mask:int = 0;
            if (vertexSrc.indexOf('va0') >= 0) mask |= 1;
            if (vertexSrc.indexOf('va1') >= 0) mask |= 2;
            if (vertexSrc.indexOf('va2') >= 0) mask |= 4;
            this._progStreams[program] = mask;
            // Same story for samplers (#3697): a slot left bound while the
            // fragment program never samples it is a hard AIR error.
            var smask:int = 0;
            for (var i:int = 0; i < AGALRenderer.MAX_SAMPLER_SLOTS; i++)
            {
                if (fragSrc.indexOf('fs' + i) >= 0) smask |= (1 << i);
            }
            this._progSamplers[program] = smask;
        }

        private function _noteStreamsMask(program:Program3D, mask:int, samplerMask:int):void
        {
            this._progStreams[program] = mask;
            this._progSamplers[program] = samplerMask;
        }

        private function _streamsOf(program:Program3D):int
        {
            var m:Object = this._progStreams[program];
            return (m == null) ? 7 : int(m);
        }

        private function _samplersOf(program:Program3D):int
        {
            var m:Object = this._progSamplers[program];
            return (m == null) ? int((1 << AGALRenderer.MAX_SAMPLER_SLOTS) - 1) : int(m);
        }

        // Binds exactly the streams the current program reads and unbinds the
        // rest (null disables a stream in both runtimes).
        private function _bindMeshStreams(resources:GPUMeshResources):void
        {
            var smask:int = this._curSamplerMask;
            for (var i:int = 0; i < AGALRenderer.MAX_SAMPLER_SLOTS; i++)
            {
                if ((smask & (1 << i)) == 0) this._context.setTextureAt(i, null);
            }
            var mask:int = this._curStreamMask;
            this._context.setVertexBufferAt(0, resources.vertexBuffer, 0, Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(1, ((mask & 2) != 0) ? resources.normalBuffer : null,
                0, Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(2, ((mask & 4) != 0) ? resources.uvBuffer : null,
                0, Context3DVertexBufferFormat.FLOAT_2);
        }

        public function get drawCalls():int
        {
            return this._drawCalls;
        }

        public function get triangles():int
        {
            return this._triangleCount;
        }

        // Objects the frustum pass rejected on the last render. three.js keeps no
        // equivalent counter, so this is an asaot3d addition for verification
        // (recorded in three-api-design.md §16 as E-stats).
        public function get culledObjects():int
        {
            return this._culledObjects;
        }

        private function _drawMeshes(list:Vector.<Mesh>):void
        {
            var n:int = list.length;
            for (var i:int = 0; i < n; i++)
            {
                this._renderMesh(list[i]);
            }
        }

        // ------------------------------------------------------------------
        // M11: LineSegments drawing.
        // ------------------------------------------------------------------

        private function _drawLines():void
        {
            var n:int = this._lineObjects.length;
            for (var i:int = 0; i < n; i++)
            {
                this._renderLineSegments(this._lineObjects[i]);
            }
        }

        // Expand each vertex PAIR into 4 quad vertices and draw 2 triangles per
        // segment. The expansion feeds the vertex program's (pos, other, side)
        // interpretation (see _buildLineProgram).
        private function _renderLineSegments(lines:LineSegments):void
        {
            var geometry:BufferGeometry = lines.geometry;
            if (geometry == null) return;

            var position:BufferAttribute = geometry.getAttribute('position');
            if (position == null) return;

            // M26: per-vertex colour and tone mapping pick the program variant and
            // decide whether va3 is bound. `color` is only consulted when the
            // material asks for it, so a geometry that happens to carry colours is
            // not silently tinted.
            var material:LineBasicMaterial = (lines.material is LineBasicMaterial)
                ? LineBasicMaterial(lines.material) : null;
            var vertexColors:Boolean = (material != null) && material.vertexColors;
            var colorAttr:BufferAttribute = vertexColors ? geometry.getAttribute('color') : null;
            if (colorAttr == null) vertexColors = false;
            var toneMapped:Boolean = (material == null) || material.toneMapped;

            var resources:GPULineResources = GPULineResources(this._lineCache[lines]);
            if (resources == null)
            {
                resources = new GPULineResources();
                this._lineCache[lines] = resources;
            }

            if (resources.indexBuffer == null
                || resources.positionVersion != position.version
                || resources.colorVersion != ((colorAttr != null) ? colorAttr.version : -1))
            {
                this._buildLineBuffers(position, colorAttr, resources);
            }

            var numTriangles:int = int(resources.segmentCount) * 2;
            if (numTriangles <= 0) return;

            // Model-view-projection for this object.
            this._mvp.multiplyMatrices(this._viewProjection, lines.matrixWorld);
            this._matrix3D.rawData = this._mvp.elements;

            // M19: depth test/write and blending come from the material (a
            // LineBasicMaterial can be additive or test-without-write). Culling
            // is forced off right below: the expanded quad's winding depends on
            // the projected segment direction, so it is always front-facing on
            // one side of a silhouette and back-facing on the other.
            this._applyMaterialState(lines.material);

            this._context.setProgram(this._getLineProgram(vertexColors, toneMapped));
            this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, this._matrix3D, true);

            // vc4 = (halfWidth, halfHeight, halfLineWidth, 0) in device pixels.
            var halfWidthPixels:Number = (material != null) ? material.linewidth * 0.5 : 0.5;
            this._lineViewport[0] = this._context.backBufferWidth * 0.5;
            this._lineViewport[1] = this._context.backBufferHeight * 0.5;
            this._lineViewport[2] = halfWidthPixels;
            // -1: the shader has no unary minus for source operands, so the
            // perpendicular's x component is negated by this multiplier.
            this._lineViewport[3] = -1;
            // vc5 = (1/halfWidth, 1/halfHeight, 0, 0): reciprocals the shader would
            // otherwise compute per vertex (see _buildLineProgram).
            this._lineViewport[4] = 1 / this._lineViewport[0];
            this._lineViewport[5] = 1 / this._lineViewport[1];
            this._lineViewport[6] = 0;
            this._lineViewport[7] = 0;
            this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 4, this._lineViewport, 2);

            // Fragment: same layout as the basic program (fc0 color+alpha,
            // fc14.. tone mapping + fc41/fc42 sRGB transfer constants).
            var color:Color = (material != null) ? material.color : null;
            this._colorVec[0] = (color != null) ? color.r : 1;
            this._colorVec[1] = (color != null) ? color.g : 1;
            this._colorVec[2] = (color != null) ? color.b : 1;
            this._colorVec[3] = (lines.material != null) ? lines.material.opacity : 1;
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._colorVec, 1);
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 1, this._gammaVec, 1);
            this._uploadSrgbConstants();
            this._uploadToneConstants((lines.material != null) ? lines.material.alphaTest : 0,
                                      (lines.material != null) ? lines.material.opacity : 1);

            this._context.setVertexBufferAt(0, resources.positionBuffer, 0, Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(1, resources.otherBuffer, 0, Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(2, resources.sideBuffer, 0, Context3DVertexBufferFormat.FLOAT_1);
            // M26: va3 is bound only for the colour variant. Leaving it bound on
            // the plain variant is a hard AIR error (#3607 "stream set but not used"),
            // so the unused slot is explicitly disabled.
            this._context.setVertexBufferAt(3, vertexColors ? resources.colorBuffer : null, 0,
                Context3DVertexBufferFormat.FLOAT_3);

            // M19: culling comes from the material now; the expanded quad needs
            // it off (its winding depends on the projected edge direction).
            this._context.setCulling('none');
            this._context.drawTriangles(resources.indexBuffer, 0, numTriangles);
            this._drawCalls++;
            this._triangleCount += numTriangles;
        }

        // CPU-side segment expansion (3 buffers + index, plus a colour buffer for
        // the M26 vertex-colour variant).
        //
        // Runs when a version the buffers depend on changes. The SCRATCH vectors
        // and the GPU buffers are kept on `resources` and refilled in place, so a
        // geometry that updates every frame (SkeletonHelper) costs one
        // uploadFromVector per buffer and zero allocations. Rebuilding them per
        // frame put tens of thousands of doubles through the GC every frame -- the
        // exact churn AGENTS.md's memory red-line forbids.
        private function _buildLineBuffers(position:BufferAttribute, colorAttr:BufferAttribute,
                                           resources:GPULineResources):void
        {
            var segments:int = int(position.count / 2);
            resources.segmentCount = segments;
            resources.positionVersion = position.version;
            resources.colorVersion = (colorAttr != null) ? colorAttr.version : -1;

            if (segments <= 0) return;

            var verticesPerSegment:int = 4;
            var totalVerts:int = segments * verticesPerSegment;

            // Layout (and therefore the buffer set) changes only with the segment
            // count, so that is the only allocation trigger.
            if (resources.positionBuffer == null || resources.allocatedSegments != segments)
            {
                resources.allocatedSegments = segments;
                resources.posData = new Vector.<Number>(totalVerts * 3);
                resources.otherData = new Vector.<Number>(totalVerts * 3);
                resources.sideData = new Vector.<Number>(totalVerts);

                resources.positionBuffer = this._context.createVertexBuffer(totalVerts, 3);
                resources.otherBuffer = this._context.createVertexBuffer(totalVerts, 3);
                resources.sideBuffer = this._context.createVertexBuffer(totalVerts, 1);

                // Index pairs never change while the segment count is fixed.
                var idxData:Vector.<uint> = new Vector.<uint>(segments * 6);
                var si:int = 0;
                while (si < segments)
                {
                    var sbase:int = si * verticesPerSegment;
                    var kk:int = si * 6;
                    idxData[kk + 0] = sbase + 0;
                    idxData[kk + 1] = sbase + 1;
                    idxData[kk + 2] = sbase + 2;
                    idxData[kk + 3] = sbase + 1;
                    idxData[kk + 4] = sbase + 3;
                    idxData[kk + 5] = sbase + 2;
                    si++;
                }
                resources.indexBuffer = this._context.createIndexBuffer(segments * 6);
                resources.indexBuffer.uploadFromVector(idxData, 0, segments * 6);
            }

            var posData:Vector.<Number> = resources.posData;
            var otherData:Vector.<Number> = resources.otherData;
            var sideData:Vector.<Number> = resources.sideData;
            var colorData:Vector.<Number> = null;
            if (colorAttr != null)
            {
                if (resources.colorBuffer == null)
                {
                    resources.colorBuffer = this._context.createVertexBuffer(totalVerts, 3);
                    resources.colorData = new Vector.<Number>(totalVerts * 3);
                }
                colorData = resources.colorData;
            }

            var p:Vector.<Number> = position.array;
            var c:Vector.<Number> = (colorAttr != null) ? colorAttr.array : null;

            var s:int = 0;
            while (s < segments)
            {
                var ia:int = (s * 2) * 3;
                var ib:int = (s * 2 + 1) * 3;

                var ax:Number = p[ia], ay:Number = p[ia + 1], az:Number = p[ia + 2];
                var bx:Number = p[ib], by:Number = p[ib + 1], bz:Number = p[ib + 2];

                var base:int = s * verticesPerSegment;
                var o:int = base * 3;

                //  0: A, other=B, side=-1
                posData[o + 0] = ax; posData[o + 1] = ay; posData[o + 2] = az;
                otherData[o + 0] = bx; otherData[o + 1] = by; otherData[o + 2] = bz;
                sideData[base + 0] = -1;

                //  1: A, other=B, side=+1
                posData[o + 3] = ax; posData[o + 4] = ay; posData[o + 5] = az;
                otherData[o + 3] = bx; otherData[o + 4] = by; otherData[o + 5] = bz;
                sideData[base + 1] = 1;

                //  2: B, other=A, side=+1  (direction is reversed for the end
                //     vertex, so the sign is pre-negated to keep one consistent
                //     perpendicular across the quad)
                o = (base + 2) * 3;
                posData[o + 0] = bx; posData[o + 1] = by; posData[o + 2] = bz;
                otherData[o + 0] = ax; otherData[o + 1] = ay; otherData[o + 2] = az;
                sideData[base + 2] = 1;

                //  3: B, other=A, side=-1
                posData[o + 3] = bx; posData[o + 4] = by; posData[o + 5] = bz;
                otherData[o + 3] = ax; otherData[o + 4] = ay; otherData[o + 5] = az;
                sideData[base + 3] = -1;

                if (colorData != null)
                {
                    // Both vertices of the segment share its endpoints' colours
                    // (0-1 = A's colour, 2-3 = B's), which is what
                    // SkeletonHelper's blue->green bone taper relies on.
                    var ca:int = (s * 2) * 3;
                    var cb:int = (s * 2 + 1) * 3;
                    var c0:int = base * 3;
                    var c1:int = (base + 1) * 3;
                    var c2:int = (base + 2) * 3;
                    var c3:int = (base + 3) * 3;
                    colorData[c0 + 0] = c[ca]; colorData[c0 + 1] = c[ca + 1]; colorData[c0 + 2] = c[ca + 2];
                    colorData[c1 + 0] = c[ca]; colorData[c1 + 1] = c[ca + 1]; colorData[c1 + 2] = c[ca + 2];
                    colorData[c2 + 0] = c[cb]; colorData[c2 + 1] = c[cb + 1]; colorData[c2 + 2] = c[cb + 2];
                    colorData[c3 + 0] = c[cb]; colorData[c3 + 1] = c[cb + 1]; colorData[c3 + 2] = c[cb + 2];
                }

                s++;
            }

            resources.positionBuffer.uploadFromVector(posData, 0, totalVerts);
            resources.otherBuffer.uploadFromVector(otherData, 0, totalVerts);
            resources.sideBuffer.uploadFromVector(sideData, 0, totalVerts);
            if (colorData != null) resources.colorBuffer.uploadFromVector(colorData, 0, totalVerts);
        }

        // M19: Object3D.renderOrder is the primary sort key of BOTH lists, the
        // same rule three.js applies in painterSortStable /
        // reversePainterSortStable (WebGLRenderLists.js:12-34: groupOrder, then
        // renderOrder, then material/z). We have no groupOrder, and the opaque
        // tiebreak deliberately stays traversal order (three.js sorts opaque
        // front-to-back by program+material, which for our single program per
        // material kind would reshuffle draws for no visible gain). Transparent
        // keeps the back-to-front distance tiebreak from M10.
        //
        // Probes pin the comparison rules through these two static predicates.
        public static function renderOrderOf(object:Object3D):int
        {
            return object.renderOrder;
        }

        // True when b must be drawn before a (opaque list, stable otherwise).
        public static function opaqueOrderSwaps(a:Mesh, b:Mesh):Boolean
        {
            return b.renderOrder < a.renderOrder;
        }

        // True when b must be drawn before a (transparent list): lower
        // renderOrder first, then the farther mesh (`bDepth > aDepth`).
        public static function transparentOrderSwaps(a:Mesh, aDepth:Number, b:Mesh, bDepth:Number):Boolean
        {
            if (a.renderOrder != b.renderOrder) return b.renderOrder < a.renderOrder;
            return bDepth > aDepth;
        }

        // Stable insertion sort of the opaque list on renderOrder alone. A
        // scene holds a handful of meshes with a non-zero renderOrder, so this
        // stays allocation-free (nothing to key: renderOrder is read off the
        // object).
        private function _sortOpaqueMeshes():void
        {
            var list:Vector.<Mesh> = this._opaqueMeshes;
            var n:int = list.length;
            if (n < 2) return;
            var i:int;
            for (i = 1; i < n; i++)
            {
                var m:Mesh = list[i];
                var j:int = i - 1;
                while (j >= 0 && AGALRenderer.opaqueOrderSwaps(list[j], m))
                {
                    list[j + 1] = list[j];
                    j--;
                }
                list[j + 1] = m;
            }
        }

        // Sort the transparent list far-to-near (three.js reversePainterSortStable
        // pushes transparent objects by view-space z; squared camera distance is
        // the same ordering without a view transform), with renderOrder taking
        // precedence (M19). Insertion sort: a scene holds a handful of
        // transparent meshes, and it keeps the scratch vector allocation-free.
        private function _sortTransparentMeshes():void
        {
            var list:Vector.<Mesh> = this._transparentMeshes;
            var n:int = list.length;
            // A single transparent mesh needs no distance at all.
            if (n < 2) return;

            var keys:Vector.<Number> = this._sortDepth;
            keys.length = n;
            var i:int;
            for (i = 0; i < n; i++)
            {
                keys[i] = AGALRenderer.transparentSortKey(list[i], this._cameraPos);
            }

            // Descending key = farthest first (back-to-front painter's order),
            // unless renderOrder says otherwise.
            for (i = 1; i < n; i++)
            {
                var km:Mesh = list[i];
                var kd:Number = keys[i];
                var j:int = i - 1;
                while (j >= 0 && AGALRenderer.transparentOrderSwaps(list[j], keys[j], km, kd))
                {
                    list[j + 1] = list[j];
                    keys[j + 1] = keys[j];
                    j--;
                }
                list[j + 1] = km;
                keys[j + 1] = kd;
            }
        }

        // Transparent-pass depth key: squared distance from the camera to the
        // object's world origin. Public so probes can pin the ordering rule
        // without a Context3D (the pass sorts DESCENDING on this value, so the
        // larger key -- farther object -- is drawn first).
        public static function transparentSortKey(mesh:Mesh, cameraPos:Vector3):Number
        {
            var e:Vector.<Number> = mesh.matrixWorld.elements;
            var dx:Number = e[12] - cameraPos.x;
            var dy:Number = e[13] - cameraPos.y;
            var dz:Number = e[14] - cameraPos.z;
            return dx * dx + dy * dy + dz * dz;
        }

        // ------------------------------------------------------------------
        // M19: per-draw render state.
        // ------------------------------------------------------------------

        // Apply one material's culling / depth / blend state. Called for every
        // mesh (and line) draw, which is what makes Material.side, depthTest,
        // depthWrite and blending real instead of decorative.
        //
        // The punctual passes are the one place that OVERRIDES the material: they
        // accumulate a single light's contribution onto the base pass, which only
        // works with additive blending and no depth writes. three.js sums every
        // punctual light inside one shader pass and therefore has no equivalent
        // per-pass state; that mapping is R37 in three-api-design.md §24.
        private function _applyMaterialState(material:Material):void
        {
            this._context.setCulling(AGALRenderer.cullingFor(material.side));

            if (this._activePass != 0)
            {
                this._context.setDepthTest(false, 'lessEqual');
                this._context.setBlendFactors('one', 'one');
                return;
            }

            this._context.setDepthTest(
                AGALRenderer.depthMaskFor(material.depthTest, material.depthWrite),
                AGALRenderer.depthCompareFor(material.depthTest));

            var blending:int = AGALRenderer.effectiveBlending(material.blending, material.transparent);
            if (!AGALRenderer.blendingImplemented(material.blending))
            {
                this._warnOnce("blending",
                    "Material.blending " + material.blending + " (CustomBlending) is not implemented " +
                    "-- this port exposes no per-material blendSrc/blendDst, so NormalBlending is used " +
                    "(three-api-design.md 24)");
            }
            this._context.setBlendFactors(AGALRenderer.blendSrcFor(blending),
                                          AGALRenderer.blendDstFor(blending));
        }

        // M20: blending is only meaningful on a `transparent` material. three.js
        // (WebGLState.js:763-766) resolves exactly ONE case:
        //
        //   (blending === NormalBlending && transparent === false) ? NoBlending
        //                                                          : setBlending(blending)
        //
        // Before M20 this port always installed sourceAlpha/oneMinusSourceAlpha,
        // which had two consequences: an opaque material with `opacity < 1`
        // rendered translucent (three.js renders it fully opaque -- the classic
        // "forgot transparent = true" behaviour), and EVERY opaque draw went down
        // the destination-reading blend path, which is why this backend showed
        // LSB-level pixel noise against the pre-M19 baselines (R39).
        public static function effectiveBlending(blending:int, transparent:Boolean):int
        {
            if (!transparent && blending == Material.NormalBlending) return Material.NoBlending;
            return blending;
        }

        // ------------------------------------------------------------------
        // M25: HDR environment intensity.
        // ------------------------------------------------------------------

        // The cone radius (in RADIANS) that scene.backgroundBlurriness = 1 asks
        // for. D156: three.js blurs a background by sampling a PMREM chain at a
        // fixed roughness; Stage3D's AGAL has no explicit-LOD cube sample (and a
        // full-screen quad's derivatives pin the LOD to 0), so the skybox
        // approximates it with a five-tap cone. 0.5 rad is "plainly out of focus"
        // without turning the environment into a single flat colour.
        public static const BACKGROUND_BLUR_RADIUS:Number = 0.5;

        // M25-R2: `backgroundBlurriness` is TIERED instead of one fixed 5-tap cone
        // (D156 fixed the shape, this fixes the strength ramp).
        //
        //   blurriness <= 0        -> no blur program at all (the sharp HDR one)
        //   0 < blurriness <= 0.5  -> 5 taps on +/-X and +/-Z (cheap, and a small
        //                             cone is what a low blurriness asks for)
        //   blurriness > 0.5       -> 9 taps: those four plus +/-Y and the two XZ
        //                             diagonals, which is what stops a strong
        //                             blur from reading as four ghosted copies
        //
        // It is still an ANGLE, not a PMREM LOD (this backend cannot select a cube
        // LOD from AGAL). The tier boundary is public so the probe can pin the
        // ramp without a GPU.
        public static const BACKGROUND_BLUR_WIDE_TIER:Number = 0.5;

        /** 0 = sharp, 5 = narrow cone, 9 = wide cone. */
        public static function blurTapsFor(blurriness:Number):int
        {
            if (!(blurriness > 0)) return 0;      // also rejects NaN
            return (blurriness > AGALRenderer.BACKGROUND_BLUR_WIDE_TIER) ? 9 : 5;
        }

        // fc3..fc6 of the HDR skybox: the tap axes and both average weights.
        // fc3 = +X, fc4 = +Z (w = 1/5), fc5 = +Y, fc6 = the XZ diagonal (w = 1/9).
        // Uploaded as one block whichever tier runs, so the two variants never
        // disagree about what the registers mean. Static so the probe can pin
        // them without a GPU.
        public static const bgTapAxes:Vector.<Number> = AGALRenderer.makeBgTapAxes();

        private static function makeBgTapAxes():Vector.<Number>
        {
            var v:Vector.<Number> = new Vector.<Number>(16, true);
            v[0] = 1; v[1] = 0; v[2] = 0; v[3] = 0;                    // fc3 = +X
            v[4] = 0; v[5] = 0; v[6] = 1; v[7] = 1 / 5;                // fc4 = +Z, 1/5
            v[8] = 0; v[9] = 1; v[10] = 0; v[11] = 0;                  // fc5 = +Y
            v[12] = Math.SQRT1_2; v[13] = 0; v[14] = Math.SQRT1_2;     // fc6 = XZ diag
            v[15] = 1 / 9;
            return v;
        }

        // fc10.x for one standard draw.
        // three.js multiplies FOUR things into the environment's contribution:
        //   material.envMapIntensity   (MeshStandardMaterial.js)
        //   scene.environmentIntensity (Scene.js:60, r165+)
        //   the PMREM prefilter          (not modelled here, M9's mix(R,N,r^2))
        //   the texture's own encoding   (M17's decode pow)
        // M25 adds a fifth: `cube.hdrScale`, the radiance divisor an
        // EquirectangularToCube bake divided by (D154). It belongs HERE rather
        // than in a new shader slot because it is exactly "this cube's texels are
        // N times darker than the colour they encode".
        public static function envIntensityOf(materialIntensity:Number, cube:CubeTexture,
                                              sceneIntensity:Number):Number
        {
            if (cube == null) return 0;
            var scale:Number = cube.hdrScale > 0 ? cube.hdrScale : 1.0;
            var scene:Number = sceneIntensity == sceneIntensity ? sceneIntensity : 1.0;
            return materialIntensity * scene * scale;
        }

        // M20: BufferGeometry.drawRange. `start`/`count` are INDEX offsets and
        // `count == -1` means "to the end" (D7) -- the same convention the
        // raycaster already used. Before M20 the draw path ignored the range
        // entirely, so trimming a geometry visibly changed nothing while picking
        // silently changed; that sort of split (field present, draw path
        // ignores it) is exactly what M17-M19 were about.
        //
        // `start` is floored to a whole triangle and the count clamped to the
        // buffer: a hand-written range must never index past the buffer, which
        // would throw inside Stage3D with no location.
        public static function drawFirstIndex(geometry:BufferGeometry):int
        {
            var start:int = geometry.drawRange.start;
            if (start < 0) start = 0;
            return int(start / 3) * 3;
        }

        public static function drawNumTriangles(geometry:BufferGeometry, totalIndices:int):int
        {
            var first:int = AGALRenderer.drawFirstIndex(geometry);
            var room:int = totalIndices - first;
            if (room < 0) room = 0;
            var count:int = geometry.drawRange.count;
            if (count < 0) count = room;
            if (count > room) count = room;
            return int(count / 3);
        }

        // ------------------------------------------------------------------
        // M19: wireframe.
        //
        // three.js switches the rasterizer to LINES; Stage3D has only
        // drawTriangles, so every triangle edge is expanded into a screen-space
        // quad exactly like the M11 LineSegments path, and drawn with the same
        // line program. Edge count is 3 per triangle with no de-duplication:
        // shared edges are rasterized twice, which is invisible at these widths
        // and keeps the buffer build a single pass (three.js's WireframeGeometry
        // dedupes at the cost of an edge hash table).
        //
        // Divergences (R38, three-api-design.md §24): the edge color is the
        // material's flat `color` (the line program has no lighting/texture
        // stage), punctual passes skip wireframe draws (an unlit line would be
        // added once per light), and the shadow pass still rasterizes SURFACES
        // (three.js forwards `wireframe` to its depth material).
        // ------------------------------------------------------------------

        private function _renderWireframe(mesh:Mesh, material:Material):void
        {
            var geometry:BufferGeometry = mesh.geometry;
            var position:BufferAttribute = geometry.getAttribute('position');
            if (position == null) return;

            var resources:GPUMeshResources = GPUMeshResources(this._cache[mesh]);
            if (resources == null)
            {
                resources = new GPUMeshResources();
                this._cache[mesh] = resources;
            }

            var index:BufferAttribute = geometry.index;
            var indexVersion:int = (index != null) ? index.version : -1;
            if (resources.wireframeBuffer == null
                || resources.wireframePositionVersion != position.version
                || resources.wireframeIndexVersion != indexVersion)
            {
                this._buildWireframeBuffers(position, index, resources);
            }

            var numTriangles:int = int(resources.wireframeEdges) * 2;
            if (numTriangles <= 0) return;

            this._mvp.multiplyMatrices(this._viewProjection, mesh.matrixWorld);
            this._matrix3D.rawData = this._mvp.elements;

            this._context.setProgram(this._lineProgram);
            this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, this._matrix3D, true);

            // vc4 = (halfWidth, halfHeight, halfLineWidth, -1) in device pixels
            // (the line program's own register contract; the standard program's
            // vc4..vc7 model matrix is unused here).
            this._lineViewport[0] = this._context.backBufferWidth * 0.5;
            this._lineViewport[1] = this._context.backBufferHeight * 0.5;
            this._lineViewport[2] = AGALRenderer.wireframeHalfWidth(material);
            this._lineViewport[3] = -1;
            // vc5 = (1/halfWidth, 1/halfHeight, 0, 0): reciprocals the shader would
            // otherwise compute per vertex (see _buildLineProgram).
            this._lineViewport[4] = 1 / this._lineViewport[0];
            this._lineViewport[5] = 1 / this._lineViewport[1];
            this._lineViewport[6] = 0;
            this._lineViewport[7] = 0;
            this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 4, this._lineViewport, 2);

            var color:Color = AGALRenderer.wireframeColorOf(material);
            this._colorVec[0] = color.r;
            this._colorVec[1] = color.g;
            this._colorVec[2] = color.b;
            this._colorVec[3] = material.opacity;
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._colorVec, 1);
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 1, this._gammaVec, 1);
            this._uploadSrgbConstants();
            this._uploadToneConstants(material.alphaTest, material.opacity);

            // The quad's winding follows the projected edge direction, so it is
            // front-facing on one side of the silhouette and back-facing on the
            // other -- exactly why the M11 line pass draws without culling.
            this._context.setCulling('none');
            this._context.setVertexBufferAt(0, resources.wireframeBuffer, 0, Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(1, resources.wireframeOtherBuffer, 0, Context3DVertexBufferFormat.FLOAT_3);
            this._context.setVertexBufferAt(2, resources.wireframeSideBuffer, 0, Context3DVertexBufferFormat.FLOAT_1);
            this._context.drawTriangles(resources.wireframeIndexBuffer, 0, numTriangles);
            this._drawCalls++;
            this._triangleCount += numTriangles;
        }

        // Flat line color + width, read through one helper each so a probe can
        // pin the rule without a Context3D.
        public static function wireframeColorOf(material:Material):Color
        {
            if (material is MeshStandardMaterial) return MeshStandardMaterial(material).color;
            if (material is MeshBasicMaterial) return MeshBasicMaterial(material).color;
            return null;
        }

        public static function wireframeHalfWidth(material:Material):Number
        {
            var w:Number = 1;
            if (material is MeshStandardMaterial) w = MeshStandardMaterial(material).wireframeLinewidth;
            else if (material is MeshBasicMaterial) w = MeshBasicMaterial(material).wireframeLinewidth;
            if (!(w > 0)) w = 1;
            return w * 0.5;
        }

        // Only the two mesh materials carry `wireframe` in three.js; a material
        // without the field draws its surface as usual.
        public static function wantsWireframe(material:Material):Boolean
        {
            if (material is MeshStandardMaterial) return MeshStandardMaterial(material).wireframe;
            if (material is MeshBasicMaterial) return MeshBasicMaterial(material).wireframe;
            return false;
        }

        // M19: `flatShading` (three.js FLAT_SHADED) -- only MeshStandardMaterial
        // shades, so it is the only material that can ask for a face normal.
        public static function flatShadingOf(material:Material):Boolean
        {
            if (material is MeshStandardMaterial) return MeshStandardMaterial(material).flatShading;
            return false;
        }

        // CPU-side edge expansion: 4 vertices per triangle edge (position / other
        // endpoint / signed side) plus a fixed two-triangle index, mirroring
        // _buildLineBuffers so both paths share the vertex program's contract.
        private function _buildWireframeBuffers(position:BufferAttribute, index:BufferAttribute, resources:GPUMeshResources):void
        {
            resources.wireframePositionVersion = position.version;
            resources.wireframeIndexVersion = (index != null) ? index.version : -1;

            var triCount:int = (index != null) ? int(index.count / 3) : int(position.count / 3);
            var edges:int = triCount * 3;
            resources.wireframeEdges = edges;
            if (edges <= 0) return;

            var verts:int = edges * 4;
            var posData:Vector.<Number> = new Vector.<Number>(verts * 3);
            var otherData:Vector.<Number> = new Vector.<Number>(verts * 3);
            var sideData:Vector.<Number> = new Vector.<Number>(verts);
            var idxData:Vector.<uint> = new Vector.<uint>(edges * 6);

            var p:Vector.<Number> = position.array;
            var src:Vector.<Number> = (index != null) ? index.array : null;

            var t:int = 0;
            var e:int = 0;
            while (t < triCount)
            {
                var ia:int;
                var ib:int;
                var ic:int;
                if (src != null)
                {
                    ia = int(src[t * 3]);
                    ib = int(src[t * 3 + 1]);
                    ic = int(src[t * 3 + 2]);
                }
                else
                {
                    ia = t * 3;
                    ib = t * 3 + 1;
                    ic = t * 3 + 2;
                }

                e = AGALRenderer.wireEdgeInto(posData, otherData, sideData, idxData, e, p, ia, ib);
                e = AGALRenderer.wireEdgeInto(posData, otherData, sideData, idxData, e, p, ib, ic);
                e = AGALRenderer.wireEdgeInto(posData, otherData, sideData, idxData, e, p, ic, ia);
                t++;
            }

            resources.wireframeBuffer = this._context.createVertexBuffer(verts, 3);
            resources.wireframeBuffer.uploadFromVector(posData, 0, verts);
            resources.wireframeOtherBuffer = this._context.createVertexBuffer(verts, 3);
            resources.wireframeOtherBuffer.uploadFromVector(otherData, 0, verts);
            resources.wireframeSideBuffer = this._context.createVertexBuffer(verts, 1);
            resources.wireframeSideBuffer.uploadFromVector(sideData, 0, verts);
            resources.wireframeIndexBuffer = this._context.createIndexBuffer(edges * 6);
            resources.wireframeIndexBuffer.uploadFromVector(idxData, 0, edges * 6);
        }

        // One edge -> four quad vertices. Signs follow _buildLineBuffers: the end
        // vertices pass the start as `other`, which reverses the projected
        // direction, so their side sign is pre-negated to keep one perpendicular
        // across the quad. Public + static so the probe can pin the packing
        // without a Context3D.
        public static function wireEdgeInto(posData:Vector.<Number>, otherData:Vector.<Number>,
                                            sideData:Vector.<Number>, idxData:Vector.<uint>,
                                            edge:int, p:Vector.<Number>, i:int, j:int):int
        {
            var ai:int = i * 3;
            var bi:int = j * 3;
            var ax:Number = p[ai], ay:Number = p[ai + 1], az:Number = p[ai + 2];
            var bx:Number = p[bi], by:Number = p[bi + 1], bz:Number = p[bi + 2];

            var base:int = edge * 4;
            var o:int = base * 3;

            posData[o + 0] = ax; posData[o + 1] = ay; posData[o + 2] = az;
            otherData[o + 0] = bx; otherData[o + 1] = by; otherData[o + 2] = bz;
            sideData[base + 0] = -1;

            posData[o + 3] = ax; posData[o + 4] = ay; posData[o + 5] = az;
            otherData[o + 3] = bx; otherData[o + 4] = by; otherData[o + 5] = bz;
            sideData[base + 1] = 1;

            o = (base + 2) * 3;
            posData[o + 0] = bx; posData[o + 1] = by; posData[o + 2] = bz;
            otherData[o + 0] = ax; otherData[o + 1] = ay; otherData[o + 2] = az;
            sideData[base + 2] = 1;

            posData[o + 3] = bx; posData[o + 4] = by; posData[o + 5] = bz;
            otherData[o + 3] = ax; otherData[o + 4] = ay; otherData[o + 5] = az;
            sideData[base + 3] = -1;

            var k:int = edge * 6;
            idxData[k + 0] = base + 0;
            idxData[k + 1] = base + 1;
            idxData[k + 2] = base + 2;
            idxData[k + 3] = base + 1;
            idxData[k + 4] = base + 3;
            idxData[k + 5] = base + 2;
            return edge + 1;
        }

        private function _renderMesh(mesh:Mesh):void
        {
            var geometry:BufferGeometry = mesh.geometry;
            if (geometry == null) return;

            var position:BufferAttribute = geometry.getAttribute('position');
            if (position == null) return;

            var material:Material = mesh.material;

            // M26/R59: only the unlit (basic/line) programs implement
            // toneMapped = false. A lit material that asks for it would be tone
            // mapped anyway, so it is reported once instead of silently diverging
            // from three.js.
            if (material != null && !material.toneMapped && !(material is MeshBasicMaterial))
            {
                this._warnOnce("toneMapped",
                    "material.toneMapped = false is only implemented for MeshBasicMaterial " +
                    "and LineBasicMaterial draws; this lit material is tone mapped anyway");
            }

            // M19: wireframe replaces the surface draw entirely (three.js
            // switches the rasterizer to LINES). It is unlit, so the punctual
            // light passes leave it alone.
            if (AGALRenderer.wantsWireframe(material))
            {
                if (this._activePass != 0) return;
                this._applyMaterialState(material);
                this._renderWireframe(mesh, material);
                return;
            }

            // M19: real culling / depth / blend state for this draw.
            this._applyMaterialState(material);

            // M12: morph targets / skinning run on the CPU (D84) and write back
            // into this geometry's position/normal attributes. Doing it here --
            // before the version check below -- means the re-upload picks up this
            // frame's deformation with no extra buffer management.
            mesh.updateDeform(this._frameId);

            // Model-view-projection: projection * view * model.
            this._mvp.multiplyMatrices(this._viewProjection, mesh.matrixWorld);
            this._matrix3D.rawData = this._mvp.elements;

            // Upload (or rebuild) GPU buffers for this mesh.
            var resources:GPUMeshResources = GPUMeshResources(this._cache[mesh]);
            if (resources == null)
            {
                resources = new GPUMeshResources();
                this._cache[mesh] = resources;
            }

            if (resources.vertexBuffer == null || resources.positionVersion != position.version)
            {
                resources.vertexBuffer = this._context.createVertexBuffer(position.count, position.itemSize);
                resources.vertexBuffer.uploadFromVector(position.array, 0, position.count);
                resources.positionVersion = position.version;
            }

            var normal:BufferAttribute = geometry.getAttribute('normal');
            if (normal != null)
            {
                if (resources.normalBuffer == null || resources.normalVersion != normal.version)
                {
                    resources.normalBuffer = this._context.createVertexBuffer(normal.count, normal.itemSize);
                    resources.normalBuffer.uploadFromVector(normal.array, 0, normal.count);
                    resources.normalVersion = normal.version;
                }
            }
            else
            {
                // R9: missing normal -> synthesize a constant (0,0,1) buffer
                // (three.js WebGLAttributes' default attribute). Keyed to the
                // position version so it tracks the vertex count.
                if (resources.normalBuffer == null || resources.normalVersion != position.version)
                {
                    var normalFallback:Vector.<Number> = new Vector.<Number>(position.count * 3);
                    for (var ni:int = 0; ni < position.count; ni++)
                    {
                        normalFallback[ni * 3 + 0] = 0;
                        normalFallback[ni * 3 + 1] = 0;
                        normalFallback[ni * 3 + 2] = 1;
                    }
                    resources.normalBuffer = this._context.createVertexBuffer(position.count, 3);
                    resources.normalBuffer.uploadFromVector(normalFallback, 0, position.count);
                    resources.normalVersion = position.version;
                }
            }

            var uv:BufferAttribute = geometry.getAttribute('uv');
            if (uv != null)
            {
                if (resources.uvBuffer == null || resources.uvVersion != uv.version)
                {
                    resources.uvBuffer = this._context.createVertexBuffer(uv.count, uv.itemSize);
                    resources.uvBuffer.uploadFromVector(uv.array, 0, uv.count);
                    resources.uvVersion = uv.version;
                }
            }
            else
            {
                // R9: missing uv -> synthesize an all-zero buffer (three.js
                // default uv = (0,0): every texel sample returns the texture's
                // (0,0) texel, so a mapped material shows its corner color).
                if (resources.uvBuffer == null || resources.uvVersion != position.version)
                {
                    var uvFallback:Vector.<Number> = new Vector.<Number>(position.count * 2);
                    resources.uvBuffer = this._context.createVertexBuffer(position.count, 2);
                    resources.uvBuffer.uploadFromVector(uvFallback, 0, position.count);
                    resources.uvVersion = position.version;
                }
            }

            var index:BufferAttribute = geometry.index;
            var numTriangles:int;
            var totalIndices:int;
            if (index != null)
            {
                if (resources.indexBuffer == null || resources.indexVersion != index.version)
                {
                    resources.indexBuffer = this._context.createIndexBuffer(index.count);
                    resources.indexBuffer.uploadFromVector(this._toUintVector(index), 0, index.count);
                    resources.indexVersion = index.version;
                }
                totalIndices = index.count;
            }
            else
            {
                // Non-indexed geometry: Stage3D's drawTriangles requires an index
                // buffer, so synthesize a sequential 0..n-1 one (cached alongside
                // the position buffer). Built-in geometries are always indexed, so
                // this is a safety net rather than a hot path.
                if (resources.indexBuffer == null || resources.indexVersion != position.version)
                {
                    var vcount:int = position.count;
                    var seq:Vector.<uint> = new Vector.<uint>(vcount);
                    for (var j:int = 0; j < vcount; j++) seq[j] = j;
                    resources.indexBuffer = this._context.createIndexBuffer(vcount);
                    resources.indexBuffer.uploadFromVector(seq, 0, vcount);
                    resources.indexVersion = position.version;
                }
                totalIndices = position.count;
            }

            // M20: geometry.drawRange. `start`/`count` are index offsets, with
            // -1 meaning "to the end" (D7); both are snapped to whole triangles
            // and clamped so a hand-written range can never index out of bounds.
            var firstIndex:int = AGALRenderer.drawFirstIndex(geometry);
            numTriangles = AGALRenderer.drawNumTriangles(geometry, totalIndices);
            if (numTriangles <= 0) return;

            // Per-mesh vertex attributes: va0 position, va1 normal, va2 uv.
            // R9 guarantees normal/uv are never null here (synthesized above),
            // but the *program* may read only a subset, and AIR errors (#3607)
            // on any stream set beyond that subset -- so the binding happens
            // after the program for this draw is chosen, through the mask.
            if (mesh.material is MeshStandardMaterial)
            {
                this._renderStandard(mesh, resources);
            }
            else if (mesh.material is MeshBasicMaterial)
            {
                // M10 fix: an unlit material has no light terms to add, so it
                // must not be re-drawn by a punctual additive pass -- doing so
                // brightened every MeshBasicMaterial by the number of point/spot
                // lights in the scene. three.js draws it exactly once.
                if (this._activePass != 0) return;
                this._renderBasic(mesh);
            }
            else
            {
                return;
            }

            this._bindMeshStreams(resources);
            this._context.drawTriangles(resources.indexBuffer, firstIndex, numTriangles);
            this._drawCalls++;
            this._triangleCount += numTriangles;
        }

        // ------------------------------------------------------------------
        // MeshBasicMaterial: unlit color (M1 path, kept intact).
        // ------------------------------------------------------------------

        private function _renderBasic(mesh:Mesh):void
        {
            var material:MeshBasicMaterial = MeshBasicMaterial(mesh.material);

            // M20: unlit base-color texture. three.js `map_fragment` does
            // `diffuseColor *= sampledDiffuseColor`, so rgb AND alpha come from
            // the texel -- which is what lets a cutout glTF material
            // (KHR_materials_unlit + alphaMode MASK) work at all.
            var map:Texture = material.map;
            var decode:Boolean = map != null && AGALRenderer.needsDecode(map);
            var fogOn:Boolean = material.fog && this._fogMode != AGALRenderer.FOG_NONE &&
                                this._activePass == 0;

            var basicProgram:Program3D = this._getBasicProgram(map != null, decode, fogOn,
                                                              material.toneMapped);
            this._context.setProgram(basicProgram);
            this._curStreamMask = this._streamsOf(basicProgram);
            this._curSamplerMask = this._samplersOf(basicProgram);

            // Constants: vc0..vc3 = MVP, fc0 = material color, fc41/fc42 = the
            // sRGB transfer-function constants (D170). Color.setHex decodes sRGB
            // hex to the linear working space (D30), so fc0 already holds LINEAR
            // values and the fragment's srgbEncodeBlock is the other half of the
            // pair -- an earlier version of this comment claimed the basic path
            // skipped the encode, which the fragment source has never done.
            this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, this._matrix3D, true);
            if (fogOn)
            {
                // The fog variant reads the world position, so it needs the
                // model matrix in vc4..vc7.
                this._modelMatrix3D.rawData = mesh.matrixWorld.elements;
                this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 4,
                    this._modelMatrix3D, true);
            }

            // M20: the map slot's uv transform rides in vc40/vc41 (M18 block).
            if (map != null)
            {
                AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_MAP * 8,
                    AGALRenderer.uvMatrixOf(map));
                this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX,
                    AGALRenderer.UV_CONST_BASE, this._uvRows, 2);
            }

            var c:Color = material.color;
            this._colorVec[0] = c.r;
            this._colorVec[1] = c.g;
            this._colorVec[2] = c.b;
            // M10: fc0.w is the diffuse alpha the fragment writes to oc.w and
            // compares against fc15.z (alphaTest).
            this._colorVec[3] = material.opacity;
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._colorVec, 1);
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 1, this._gammaVec, 1);
            this._uploadSrgbConstants();
            // M10: fc14..fc21 (tone mapping + alpha). fc0.w already carries the
            // opacity for this draw, so the tone block's opacity slot is unused
            // by the basic program.
            this._uploadToneConstants(material.alphaTest, material.opacity);

            // D170/D177: no fc36 upload here -- the map decode is the sRGB
            // curve (fc41/fc42), and the HDR background uses that same pair.
            if (map != null)
            {
                this._bindTexture(map, 0);
            }

            if (fogOn)
            {
                this._uploadFogConstants();
            }
        }

        // ------------------------------------------------------------------
        // MeshStandardMaterial: GGX PBR (M2 path + M4 texture map family).
        // ------------------------------------------------------------------

        private function _renderStandard(mesh:Mesh, resources:GPUMeshResources):void
        {
            var material:MeshStandardMaterial = MeshStandardMaterial(mesh.material);

            // M9: resolve this draw's environment map. three.js reads
            // `material.envMap || scene.environment` per draw; the intensity is
            // forced to 0 when neither exists so the neutral white cube bound at
            // fs7 contributes nothing (one code path for every material).
            //
            // M25-R1 (D174/D175): with a pre-filtered ladder on the scene, the
            // environment slot gets the level matching this material's roughness.
            // A material that carries its own envMap keeps the M9 path: a plain
            // CubeTexture has no ladder behind it.
            //
            // ONE slot, not two (D175). AGAL exposes eight fragment samplers and
            // the standard program already has all eight spoken for in the shadow
            // variant (fs0 base, fs1 normal, fs2 roughness, fs3 metalness,
            // fs4 shadow, fs5 emissive, fs6 AO, fs7 environment). Binding the
            // roughest ladder level as a separate "irradiance" cube would need a
            // ninth, so the diffuse term keeps sampling fs7 at N -- which for a
            // pre-filtered level is the blurred sky in that direction, i.e. close
            // to what getIBLIrradiance wants, and identical to M9 for an LDR cube.
            var env:CubeTexture;
            var usingProbe:Boolean = false;
            if (material.envMap != null) env = material.envMap;
            else if (this._scenePrefiltered != null && this._scenePrefiltered.levelCount > 0)
            {
                env = this._scenePrefiltered.cubeFor(material.roughness);
            }
            else if (this._envCube != null) env = this._envCube;
            else if (this._probeCube != null)
            {
                // M27: no environment anywhere, so the probe's baked irradiance
                // cube takes the slot. It carries E/pi per texel, which is exactly
                // what the shader's "radiance * pi" turns back into irradiance, and
                // there is no radiance chain for the specular fetch to read -- the
                // specular IBL term is zero either way.
                env = this._probeCube;
                usingProbe = true;
            }
            else env = null;
            // M25-R1: a pre-filtered ladder is only bound for the scene's own
            // environment. A material envMap has no ladder behind it, so it keeps
            // the M9 stand-in path (a different program variant, see
            // _buildStandardProgram).
            var prefilteredDraw:Boolean =
                material.envMap == null && this._scenePrefiltered != null &&
                this._scenePrefiltered.levelCount > 0;
            // M25: material.envMapIntensity x scene.environmentIntensity x the
            // cube's hdrScale (see envIntensityOf). Zero when there is no cube,
            // which is what makes the neutral white cube at fs7 contribute nothing.
            //
            // M27: the probe is not an environment -- three.js scales
            // `iblIrradiance` by envMapIntensity/environmentIntensity and the
            // probe's irradiance by neither, so the probe path uploads the cube's
            // own divisor alone (LightProbe.intensity is already inside the SH).
            var envIntensity:Number = usingProbe
                ? (env != null ? env.hdrScale : 0)
                : AGALRenderer.envIntensityOf(material.envMapIntensity, env,
                                              this._sceneEnvIntensity);
            // M17: which of this draw's color slots carry sRGB texels. three.js
            // gets this from the texture's internal format; here it drives which
            // program variant is selected (the decode is one pow per slot).
            var decode:int = AGALRenderer.decodeMaskFor(material.map, material.emissiveMap, env,
                                                        material.roughnessMap, material.metalnessMap);

            // M19: flatShading picks the derivative-normal variant of the same
            // program family (three.js FLAT_SHADED). Baked into the source, so it
            // joins the variant key.
            var flat:Boolean = material.flatShading;

            // M20: fog only enters the BASE pass. The punctual passes ADD light,
            // and a fog mix there would add the fog colour once per light (the
            // same reason they ignore material blending, R37); three.js has one
            // program that does both because it accumulates lights in one pass.
            var fogOn:Boolean = material.fog && this._fogMode != AGALRenderer.FOG_NONE &&
                                this._activePass == 0;

            // M6: pick the program and constants by pass. The base pass runs the
            // standard (ambient + directional) program; a punctual pass runs the
            // point/spot program for the light in _activeLight.
            var stdProgram:Program3D;
            if (this._activePass == 1)
            {
                stdProgram = this._getPunctualProgram(false,
                    (decode & AGALRenderer.DECODE_MAP) != 0, flat);
            }
            else if (this._activePass == 2)
            {
                stdProgram = this._getPunctualProgram(true,
                    (decode & AGALRenderer.DECODE_MAP) != 0, flat);
            }
            else
            {
                // M13: the base-pass program is a (dirs, shadows) variant. A
                // shadow-less scene takes the variant without the PCF kernels, so
                // it pays nothing for shadows. M17 adds the decode mask.
                stdProgram = this._getStandardProgram(this._dirLights.length,
                                                     this._shadowLightCount, decode, flat, fogOn,
                                                     prefilteredDraw);
            }
            this._context.setProgram(stdProgram);
            this._curStreamMask = this._streamsOf(stdProgram);
            this._curSamplerMask = this._samplersOf(stdProgram);

            // Vertex constants: vc0..vc3 = MVP (transposed rows), vc4..vc7 =
            // model matrix (world transform), vc8..vc10 = normal matrix rows.
            this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, this._matrix3D, true);
            this._modelMatrix3D.rawData = mesh.matrixWorld.elements;
            this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 4, this._modelMatrix3D, true);
            this._uploadNormalMatrix(mesh);

            // M18: the six per-slot uv transforms (vc40..vc51). Refreshed for
            // every draw because they are texture state, not material state: two
            // meshes sharing one material can still bind different maps.
            this._fillUvRows(material);
            this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX,
                AGALRenderer.UV_CONST_BASE, this._uvRows, AGALRenderer.UV_SLOTS * 2);

            // M13: the base pass uploads the shadow-casting light's world ->
            // shadow-clip matrix (vc12..vc15) and its normalBias (vc20.x). A
            // punctual pass skips both: it never samples a shadow map.
            if (this._activePass == 0 && this._shadowLightCount > 0)
            {
                this._shadowMatrix3D.rawData = this._dirLights[0].shadow.matrix.elements;
                this._context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 12, this._shadowMatrix3D, true);
                this._shadowNormalBias[0] = this._dirLights[0].shadow.normalBias;
                this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 20, this._shadowNormalBias, 1);
                // vc22.x = receiveShadow (Object3D.receiveShadow). three.js
                // compiles a shadow-sampling variant per receiver; here the
                // factor is mixed toward 1 in the shader, which keeps one
                // program for every object.
                this._receiveVec[0] = mesh.receiveShadow ? 1 : 0;
                this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 22, this._receiveVec, 1);
            }

            // Fragment constants (fc0..fc13). Layout is pinned to the AGAL
            // program below -- do not reorder without editing the program
            // builders.
            if (this._activePass == 1)
            {
                this._fillPunctualConstants(PointLight(this._activeLight), material, false);
            }
            else if (this._activePass == 2)
            {
                this._fillPunctualConstants(SpotLight(this._activeLight), material, true);
            }
            else
            {
                this._fillStandardConstants(material, envIntensity);
            }

            // D170/D177: the sRGB decode reads fc41/fc42 (uploaded with the
            // material block above), so this path no longer uploads fc36 -- that
            // register is retired; the HDR background program uses the same
            // pair now (D177).

            // M20: fc37..fc40 (fog). Only the fog variant references them, but
            // they are uploaded per draw rather than per frame because the
            // constants block is shared with every other program family.
            if (fogOn)
            {
                this._uploadFogConstants();
            }

            // R8: bind the four base sampler slots every draw. A null material
            // map binds the neutral 1x1 texture, which multiplies by identity in
            // the fragment program (white texel, or (0,0,1) decoded normal).
            this._bindTexture(material.map, 0);
            this._bindTexture(material.normalMap, 1);
            this._bindTexture(material.roughnessMap, 2);
            this._bindTexture(material.metalnessMap, 3);
            // M8 follow-up: fs5 emissive, fs6 ambient occlusion. Same neutral
            // trick as R8 -- a material without these maps binds the 1x1 white
            // texel, so the adds/multiplies are identity and no per-map program
            // variant is needed.
            this._bindTexture(material.emissiveMap, 5);
            this._bindTexture(material.aoMap, 6);

            // M9: fs7 is the environment cube. Every standard draw binds it (the
            // neutral white cube when the draw has no environment), so the
            // fragment's cube fetches are always legal. M25-R1 fills it with the
            // ladder level that matches the material's roughness (D175).
            this._bindCubeTexture(env, 7);

            // M13: bind the base pass's shadow map at fs4. Only the
            // shadow-casting variant fetches it, and only the base pass samples
            // it at all -- a punctual pass ignores the slot.
            if (this._activePass == 0 && this._shadowLightCount > 0)
            {
                this._context.setTextureAt(4, this._shadowMaps[0]);
                // M17: the shadow map is a render target with no mip chain, and a
                // sampler that still carried the slot's previous mip filter (set by
                // a tiled material on fs4 in another draw -- Stage3D keeps one state
                // per slot) would make the backend drop the WHOLE base-pass draw,
                // exactly like AIR does for a chain-less mip sample. Pin the slot.
                this._context.setSamplerStateAt(4, "clamp", "linear", "mipnone");
            }
        }

        private function _fillUvRows(material:MeshStandardMaterial):void
        {
            // three.js refreshes the matrix of every map it is about to bind
            // (WebGLMaterials.refreshTransformUniform runs once per map); a null
            // slot packs the identity, which is what the neutral 1x1 textures
            // assume.
            AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_MAP * 8,
                AGALRenderer.uvMatrixOf(material.map));
            AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_NORMAL * 8,
                AGALRenderer.uvMatrixOf(material.normalMap));
            AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_ROUGHNESS * 8,
                AGALRenderer.uvMatrixOf(material.roughnessMap));
            AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_METALNESS * 8,
                AGALRenderer.uvMatrixOf(material.metalnessMap));
            AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_EMISSIVE * 8,
                AGALRenderer.uvMatrixOf(material.emissiveMap));
            AGALRenderer.uvRowsInto(this._uvRows, AGALRenderer.UV_AO * 8,
                AGALRenderer.uvMatrixOf(material.aoMap));
        }

        private function _uploadNormalMatrix(mesh:Mesh):void
        {
            // normalMatrix = inverse(transpose(modelMatrix)) 3x3. Upload each of
            // its three ROWS into vc8/vc9/vc10 (transposed from column-major
            // elements: row 0 = elements[0], elements[3], elements[6]).
            this._normalMatrix.getNormalMatrix(mesh.matrixWorld);
            var e:Vector.<Number> = this._normalMatrix.elements;
            this._normalVec[0] = e[0];  this._normalVec[1] = e[3];  this._normalVec[2] = e[6];  this._normalVec[3] = 0;
            this._normalVec[4] = e[1];  this._normalVec[5] = e[4];  this._normalVec[6] = e[7];  this._normalVec[7] = 0;
            this._normalVec[8] = e[2];  this._normalVec[9] = e[5];  this._normalVec[10] = e[8]; this._normalVec[11] = 0;
            this._context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 8, this._normalVec, 3);
        }

        private function _fillStandardConstants(material:MeshStandardMaterial,
                                                envIntensity:Number):void
        {
            // fc0 = (camX, camY, camZ, EPSILON=1e-9)
            this._fragConst[0] = this._cameraPos.x;
            this._fragConst[1] = this._cameraPos.y;
            this._fragConst[2] = this._cameraPos.z;
            this._fragConst[3] = 1e-9;

            // fc1 = (lightDir.xyz, 0.5). Light direction points toward the light
            // (position - target), normalized; w holds the V_GGX 0.5 factor.
            if (this._dirLight != null)
            {
                this._dirLight.getWorldPosition(this._tmpA);
                this._dirLight.target.updateMatrixWorld(true);
                this._dirLight.target.getWorldPosition(this._tmpB);
                this._lightDir.subVectors(this._tmpA, this._tmpB).normalize();

                // fc2 = lightColor = color * intensity (scaled in place below).
                this._fragConst[8] = this._dirLight.color.r * this._dirLight.intensity;
                this._fragConst[9] = this._dirLight.color.g * this._dirLight.intensity;
                this._fragConst[10] = this._dirLight.color.b * this._dirLight.intensity;
            }
            else
            {
                this._lightDir.set(0, 1, 0);
                this._fragConst[8] = 0;
                this._fragConst[9] = 0;
                this._fragConst[10] = 0;
            }
            this._fragConst[4] = this._lightDir.x;
            this._fragConst[5] = this._lightDir.y;
            this._fragConst[6] = this._lightDir.z;
            this._fragConst[7] = 0.5;
            this._fragConst[11] = 0; // fc2.w unused

            // fc3 = accumulated ambient color.
            this._fragConst[12] = this._ambientColor.r;
            this._fragConst[13] = this._ambientColor.g;
            this._fragConst[14] = this._ambientColor.b;
            this._fragConst[15] = 0;

            // fc4 = baseColor.rgb, w = opacity. The fragment program multiplies
            // baseColor * sampledDiffuseColor unconditionally (map_fragment
            // .glsl.js:14); a material without a map binds the neutral white
            // texture, so the product degrades to baseColor * 1 (R8). M10: the
            // w channel carries Material.opacity, which the fragment multiplies
            // by the base-color texel's alpha to form the output alpha.
            this._fragConst[16] = material.color.r;
            this._fragConst[17] = material.color.g;
            this._fragConst[18] = material.color.b;
            this._fragConst[19] = material.opacity;

            // fc5 = (roughness, metalness, 1-metalness, 1/PI). Roughness is
            // clamped to three.js's minimum highlight roughness [0.045, 1].
            var roughness:Number = material.roughness < 0.045 ? 0.045 : material.roughness;
            if (roughness > 1) roughness = 1;
            var metalness:Number = material.metalness;
            this._fragConst[20] = roughness;
            this._fragConst[21] = metalness;
            this._fragConst[22] = 1 - metalness;
            this._fragConst[23] = 1 / Math.PI;

            // fc6 = (0.04, 0.04, 0.04, 1.0): dielectric F0 (three.js's non-IOR
            // specularColor) plus the scalar 1.0 used throughout.
            this._fragConst[24] = 0.04;
            this._fragConst[25] = 0.04;
            this._fragConst[26] = 0.04;
            this._fragConst[27] = 1.0;

            // fc7 = emissive * emissiveIntensity; w unused since D170 (the sRGB
            // encode constant moved to fc41/fc42 so it cannot be decimal-drifted).
            this._fragConst[28] = material.emissive.r * material.emissiveIntensity;
            this._fragConst[29] = material.emissive.g * material.emissiveIntensity;
            this._fragConst[30] = material.emissive.b * material.emissiveIntensity;
            this._fragConst[31] = 1 / 2.2;

            // fc8 = (normalScale.xy, 2.0, 0): the normal-map xy multiplier
            // (MeshStandardMaterial.js:238) and the texel*2-1 decode factor.
            this._fragConst[32] = material.normalScale.x;
            this._fragConst[33] = material.normalScale.y;
            this._fragConst[34] = 2.0;
            // fc8.w = aoMapIntensity (M8 follow-up). three.js scales the AO
            // with `aoMapIntensity` by lerping toward 1 (aomap_fragment:
            // `ambientOcclusion = mix(1.0, ambientOcclusion, material.aoMapIntensity)`),
            // so 0 means "ignore the map" and 1 means "use it fully".
            this._fragConst[35] = material.aoMapIntensity;

            // fc9.x = shadow bias of light 0 (DirectionalLightShadow.bias). A
            // shadow-less directional light leaves this 0, which still gates the
            // direct term (sample >= depth+0 always holds), so the code path is
            // safe.
            var shadow0:DirectionalLightShadow = this._shadowLightCount > 0 ? this._dirLights[0].shadow : null;
            this._fragConst[36] = shadow0 != null ? shadow0.bias : 0;
            // fc9.y/fc9.z = 0/1: the bounds the shadow in-frustum test compares
            // against (shadowmap_pars_fragment.glsl.js getShadow()).
            this._fragConst[37] = 0;
            this._fragConst[38] = 1;
            this._fragConst[39] = 0;

            // fc10 = (envMapIntensity, 1/21, irradianceEnvIntensity, 0). M9. Zero
            // when the draw has no environment map, which is what makes the
            // neutral white cube contribute nothing (every environment sample
            // multiplies by these scalars).
            //
            // fc10.y = 1/21 (D173): the average Fresnel `Favg = Fr + (1-Fr)/21`
            // of three.js's computeMultiscattering (lights_physical_pars_fragment
            // .glsl.js:481). It rides a lane that was always 0 rather than
            // widening the fc0..fc13 block.
            //
            // fc10.z is free again: M25-R1 briefly carried a second environment
            // scalar there for a separate irradiance cube, which the eight-sampler
            // budget does not allow (D175).
            this._fragConst[40] = envIntensity;
            this._fragConst[41] = 1 / 21;
            this._fragConst[42] = 0;
            this._fragConst[43] = 0;

            // fc11/fc12/fc13: Karis's analytic EnvBRDFApprox coefficients
            // ("Physically Based Shading on Mobile", 2014). three.js samples a
            // DFG LUT texture instead (BRDF_LUT in envmap_physical_pars_fragment
            // .glsl.js); the analytic form needs no extra sampler and is within
            // ~1% of the LUT for [0,1] roughness.
            //
            //   r      = roughness * c0 + c1
            //   a004   = min(r.x*r.x, exp2(-9.28*NoV)) * r.x + r.y
            //   AB     = vec2(-1.04, 1.04) * a004 + r.zw
            //
            // AGAL's `exp` IS base 2, so the coefficient is used verbatim. It has
            // to be: this block used to fold a base change into the constant
            // (-9.28 * ln 2 = -6.4324) because the opcode was assumed to be
            // natural. Measured on adl 51.4.1 (temp/agalprobe/Exp.as, same source
            // on adl and on the AOT build): `exp(-1)` reads back 0x7F = 0.498 = 2^-1,
            // and `log(2)` reads back 0xFF = 1.0 = log2(2) -- identical on both
            // runtimes, which is why the mistake was invisible as an AOT/AIR
            // divergence and only showed up against three.js. The fold made a004
            // too large, so every environment-lit surface was brighter than the
            // reference by an amount that grows as roughness falls (r.x = 1-roughness
            // scales the error). Pinned by examples/stage348.as.
            this._fragConst[44] = -1.0;
            this._fragConst[45] = -0.0275;
            this._fragConst[46] = -0.572;
            this._fragConst[47] = 0.022;
            this._fragConst[48] = 1.0;
            this._fragConst[49] = 0.0425;
            this._fragConst[50] = 1.04;
            this._fragConst[51] = -0.04;
            this._fragConst[52] = -9.28;
            this._fragConst[53] = Math.PI;   // irradiance PI factor (fc13.y)
            this._fragConst[54] = -1.04;
            this._fragConst[55] = 1.04;

            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._fragConst, 14);
            this._uploadSrgbConstants();
            // M10: fc14..fc21 carry tone mapping plus this material's alphaTest /
            // opacity. Uploaded separately so the 14-register block above keeps
            // its pinned layout.
            this._uploadToneConstants(material.alphaTest, material.opacity);
            // M13: fc22..fc26 = second directional light + light 0's PCF kernel.
            this._fillShadowAuxConstants();
            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 22, this._shadowAuxConst, 5);
        }

        // M13: fc22..fc26.
        //   fc22 = (light1 dir.xyz, 0)
        //   fc23 = (light1 color.rgb, 0)     -- color * intensity, 0 when absent
        //   fc24 = (radius/mapW, radius/mapH, 1/PCF_TAPS, 0)
        //   fc25, fc26 = reserved (zero) for a second shadow map, which the
        //                sampler budget rules out today (D93).
        // The kernel is pre-divided on the CPU: a fragment coordinate must add
        // one multiple of it per PCF tap, and multiplying two scalars in the
        // shader would cost an instruction per tap.
        private function _fillShadowAuxConstants():void
        {
            var light:DirectionalLight = this._dirLights.length > 1 ? this._dirLights[1] : null;
            if (light != null)
            {
                light.getWorldPosition(this._tmpA);
                light.target.updateMatrixWorld(true);
                light.target.getWorldPosition(this._tmpB);
                this._lightDir.subVectors(this._tmpA, this._tmpB).normalize();
                this._shadowAuxConst[0] = this._lightDir.x;
                this._shadowAuxConst[1] = this._lightDir.y;
                this._shadowAuxConst[2] = this._lightDir.z;
                this._shadowAuxConst[4] = light.color.r * light.intensity;
                this._shadowAuxConst[5] = light.color.g * light.intensity;
                this._shadowAuxConst[6] = light.color.b * light.intensity;
            }
            else
            {
                this._shadowAuxConst[0] = 0;
                this._shadowAuxConst[1] = 1;
                this._shadowAuxConst[2] = 0;
                this._shadowAuxConst[4] = 0;
                this._shadowAuxConst[5] = 0;
                this._shadowAuxConst[6] = 0;
            }
            this._shadowAuxConst[3] = 0;
            this._shadowAuxConst[7] = 0;

            // Kernel (fc24) and the depth-unpack factors (fc25).
            var s0:DirectionalLightShadow = this._shadowLightCount > 0 ? this._dirLights[0].shadow : null;
            var kernel:Vector.<Number> = AGALRenderer.pcfKernel(s0 != null ? s0.radius : 1,
                                                               this._shadowMapW[0], this._shadowMapH[0]);
            this._shadowAuxConst[8] = kernel[0];
            this._shadowAuxConst[9] = kernel[1];
            this._shadowAuxConst[10] = kernel[2];
            this._shadowAuxConst[11] = kernel[3];
            this._shadowAuxConst[12] = 1;              // fc25.x
            this._shadowAuxConst[13] = 1 / 255;        // fc25.y
            this._shadowAuxConst[14] = 0;              // fc25.z
            this._shadowAuxConst[15] = 0;              // fc25.w
            this._shadowAuxConst[16] = 0;              // fc26: reserved
            this._shadowAuxConst[17] = 0;
            this._shadowAuxConst[18] = 0;
            this._shadowAuxConst[19] = 0;
        }

        // A PCF kernel register: (radius/mapWidth, radius/mapHeight, 1/taps, 0).
        // radius is clipped to the map extent so a runaway value cannot fetch
        // past the clamp border on every tap.
        // fc24: (radius/mapW, radius/mapH, 1/PCF_TAPS, 0). Public so the probe
        // can pin the radius clamp (a kernel wider than a quarter of the map
        // would smear the shadow past its own geometry).
        public static function pcfKernel(radius:Number, w:int, h:int):Vector.<Number>
        {
            var out:Vector.<Number> = new Vector.<Number>(4);
            if (radius < 0) radius = 0;
            var maxRadius:Number = Math.min(w, h) * 0.25;
            if (radius > maxRadius) radius = maxRadius;
            out[0] = (w > 0) ? radius / w : 0;
            out[1] = (h > 0) ? radius / h : 0;
            out[2] = 1 / PCF_TAPS;
            out[3] = 0;
            return out;
        }

        // ------------------------------------------------------------------
        // M17: texture state. Before M17 every Texture field except the image
        // was inert: the sampler was hard-coded `<2d,clamp,linear,mipnone>` in
        // the AGAL source, so REPEAT tiled textures clamped, `generateMipmaps`
        // never produced a chain, `flipY` was never consulted and `colorSpace`
        // did not exist (every color map entered the lighting math as if it
        // were linear, then got sRGB-encoded on output -- i.e. gamma applied
        // twice, which reads as "our textured objects are washed out").
        //
        // The state now maps onto Stage3D as follows:
        //   wrap/filter/mip -> Context3D.setSamplerStateAt(slot, ...) called
        //                      right after setProgram (last writer wins, so it
        //                      overrides the program's inline default).
        //   generateMipmaps -> a real chain, generated with BitmapData.draw
        //                      (bilinear, smoothing=true) at upload time.
        //   flipY           -> row flip at upload time.
        //   colorSpace      -> the sRGB EOTF on the color slots (fc41/fc42,
        //                      D170), compiled only into the variants that need
        //                      it. The HDR bake stores with the matching OETF
        //                      (D177), so there is exactly one transfer pair.
        // ------------------------------------------------------------------

        // Decode-mask bits, one per sampler slot that holds COLOR data.
        public static const DECODE_MAP:int = 1;
        public static const DECODE_EMISSIVE:int = 2;
        public static const DECODE_ENV:int = 4;
        public static const DECODE_ALL:int = 7;
        // D171: the two DATA slots. three.js declares roughnessMap / metalnessMap
        // textures no differently from a color map, so the GPU's sRGB sampler
        // decodes them whenever the texture object says SRGBColorSpace -- which
        // is exactly what webgl_animation_walk does when it drives metalness from
        // the base-color map (`material.metalnessMap = material.map`). A glTF
        // metallicRoughness texture is linear, so it sets neither bit; this only
        // fires for a color texture reused as a data map.
        //
        // Without it the metalness reads as the ENCODED blue, i.e. up to 4x too
        // metal (0.5 encoded is 0.21 linear), so the metal loses its diffuse lobe
        // and the highlight blows out -- measured as body p50 half the reference's
        // and p90 2.2x (M26-R1b, three-api-design.md §32).
        public static const DECODE_ROUGHNESS:int = 8;
        public static const DECODE_METALNESS:int = 16;
        // Every slot whose texel the standard program can decode.
        public static const DECODE_MAPS_ALL:int = 31;
        // fc36 is FREE since D177 (it held the D154 HDR-bake storage exponent;
        // the bake and the background program now share the sRGB pair in
        // fc41/fc42). fc0..fc13 are the material/light block, fc14..fc21 tone
        // mapping, fc22..fc26 shadow auxiliaries, fc27..fc35 the PCF tap offsets
        // and fc37..fc40 the fog block.
        // D170: the sRGB transfer-function constants. fc41 = (1.055, 1/1.055,
        // 0.055, 2.4), fc42 = (1/2.4, 0, 0, 0) -- the first pair above the fog
        // block (fc37..fc40).
        public static const SRGB_CONST:int = 41;
        // The values behind fc41/fc42, in upload order. Public so the probe can
        // pin them against a curve it recomputes (a .z/.w swap -- offset vs
        // exponent -- reads as "albedo + 2.4" and washes the frame out).
        public static const SRGB_CONSTANTS:Array = [1.055, 1 / 1.055, 0.055, 2.4, 1 / 2.4];

        // The fragment snippet that decodes `reg.xyz` to LINEAR when `mask` has
        // `bit`, using `tmp` as one scratch register. Empty when it does not,
        // which is what keeps a scene with no sRGB textures at exactly the
        // pre-M17 instruction count.
        //
        // D170: the sRGB EOTF, not pow(x, 2.2).
        //   linear = ((c + 0.055) / 1.055) ^ 2.4
        // This is the exact curve for c > 0.04045; below the knee the exact
        // curve is the linear segment c/12.92, and this form is up to 0.0009
        // (0.5/255 in display units) too high there -- a deliberate trade: an
        // exact toe needs a third register for the compare, and the absolute
        // error is smaller than one code value. The pure-curve form is what
        // keeps decode/encode a mutual inverse pair, which the sRGB background
        // quad (decode then encode, no tone map) relies on.
        public static function srgbDecodeBlock(reg:String, mask:int, bit:int,
                                               tmp:String):String
        {
            if ((mask & bit) == 0) return '';
            return 'add ' + tmp + '.xyz, ' + reg + '.xyz, fc41.zzzz\n' +
                   'mul ' + tmp + '.xyz, ' + tmp + '.xyz, fc41.yyyy\n' +
                   'pow ' + reg + '.x, ' + tmp + '.x, fc41.wwww\n' +
                   'pow ' + reg + '.y, ' + tmp + '.y, fc41.wwww\n' +
                   'pow ' + reg + '.z, ' + tmp + '.z, fc41.wwww\n';
        }

        // The single-COMPONENT form of the same EOTF, for the data slots: the
        // roughness map is read on .g and the metalness map on .b. `tmp` is one
        // scratch register (only its .x is touched), and the value is decoded in
        // place, so a mesh with a linear MR texture emits nothing at all.
        public static function srgbDecodeScalarBlock(reg:String, comp:String, mask:int,
                                                     bit:int, tmp:String):String
        {
            if ((mask & bit) == 0) return '';
            return 'add ' + tmp + '.x, ' + reg + '.' + comp + ', fc41.zzzz\n' +
                   'mul ' + tmp + '.x, ' + tmp + '.x, fc41.yyyy\n' +
                   'pow ' + reg + '.' + comp + ', ' + tmp + '.x, fc41.wwww\n';
        }

        // Linear -> sRGB, in place on `reg.xyz` (no scratch needed):
        //   enc = 1.055 * x^(1/2.4) - 0.055
        // The caller must `sat` the linear value first (a negative radiance is
        // not defined for a fractional exponent); the trailing sat re-clamps the
        // -0.055 offset at black.
        public static function srgbEncodeBlock(reg:String):String
        {
            return 'pow ' + reg + '.x, ' + reg + '.x, fc42.xxxx\n' +
                   'pow ' + reg + '.y, ' + reg + '.y, fc42.xxxx\n' +
                   'pow ' + reg + '.z, ' + reg + '.z, fc42.xxxx\n' +
                   'mul ' + reg + '.xyz, ' + reg + '.xyz, fc41.xxxx\n' +
                   'sub ' + reg + '.xyz, ' + reg + '.xyz, fc41.zzzz\n' +
                   'sat ' + reg + '.xyz, ' + reg + '.xyz\n';
        }

        // r187's geometryRoughness, in isolation: it turns the screen-space
        // derivative of the NON-perturbed normal into a scalar roughness addend.
        // Public so a probe can pin the exact text -- the term changes every
        // lit surface's lobe width, and a silently dropped `abs` would bias it.
        //
        // Reads ft0.xyz (unit, the interpolated geometric normal) and writes
        // ft12.x; ft13 is scratch. Both are dead at this point in the program.
        public static function geometryRoughnessBlock():String
        {
            return 'ddx ft12.xyz, ft0.xyz\n' +
                'ddy ft13.xyz, ft0.xyz\n' +
                'abs ft12.xyz, ft12.xyz\n' +
                'abs ft13.xyz, ft13.xyz\n' +
                'max ft12.xyz, ft12.xyz, ft13.xyz\n' +
                'max ft12.x, ft12.x, ft12.y\n' +
                'max ft12.x, ft12.x, ft12.z\n';
        }

        // Karis's EnvBRDFApprox, isolated (D173). This is the analytic stand-in
        // for three.js's dfgLUT texel (BRDF_LUT in envmap_physical_pars_fragment
        // .glsl.js:12): `ab`.y = AB.x is the F0 gain, `ab`.z = AB.y is the F90
        // bias, and `ab`.x ends holding a004 (which the multi-scattering term
        // reuses). `ab`.w is NEVER written -- the standard program parks the
        // shadow factor there. `tmp` is one scratch register, fully clobbered.
        //
        //   r    = roughness * fc11 + fc12
        //   a004 = min(r.x*r.x, exp2(-9.28*NoV)) * r.x + r.y     (fc13.x = -9.28)
        //   AB   = vec2(-1.04, 1.04) * a004 + r.zw
        //
        // AGAL's `exp` is base 2 on both runtimes (stage348), so -9.28 is used
        // verbatim.
        public static function envBRDFApproxBlock(ab:String, tmp:String):String
        {
            return 'mul ' + tmp + ', ft5.xxxx, fc11\n' +
                'add ' + tmp + ', ' + tmp + ', fc12\n' +
                'mul ' + ab + '.x, ' + tmp + '.x, ' + tmp + '.x\n' +
                'mul ' + ab + '.y, fc13.x, ft3.y\n' +
                'exp ' + ab + '.y, ' + ab + '.y\n' +
                'min ' + ab + '.x, ' + ab + '.x, ' + ab + '.y\n' +
                'mul ' + ab + '.x, ' + ab + '.x, ' + tmp + '.x\n' +
                'add ' + ab + '.x, ' + ab + '.x, ' + tmp + '.y\n' +
                'mul ' + ab + '.y, ' + ab + '.x, fc13.z\n' +
                'add ' + ab + '.y, ' + ab + '.y, ' + tmp + '.z\n' +
                'mul ' + ab + '.z, ' + ab + '.x, fc13.w\n' +
                'add ' + ab + '.z, ' + ab + '.z, ' + tmp + '.w\n';
        }

        // The direct-light half of the multi-scattering compensation (D173),
        // lights_fragment_begin.glsl.js:56-74:
        //
        //   EssMs = dfg.x + dfg.y                  // white-furnace albedo
        //   material.multiScatteringCompensation
        //         = 1 + specularColorBlended * (1/EssMs - 1)
        //
        // applied to every direct specular term (lights_physical_pars_fragment
        // .glsl.js:595). A single-scattering GGX lobe loses the energy that went
        // into 2+ bounces; at the walk-m26 body's roughness 0.2 / NoV 0.5, Ess is
        // 0.89, so the lobe is x1.12 too dim. That is the missing quarter of the
        // M26-R1b metal reading (three-api-design.md §32, §34).
        //
        // `ab` must already hold envBRDFApproxBlock's output (`.y`/`.z` are read
        // as Ess; `.x` is scratch). `tmp`.x carries the scalar so the vector
        // multiply never reads a lane it is writing. Writes `out`.xyz only.
        public static function multiScatterCompBlock(out:String, ab:String,
                                                    tmp:String):String
        {
            return 'add ' + tmp + '.x, ' + ab + '.y, ' + ab + '.z\n' +
                'max ' + tmp + '.x, ' + tmp + '.x, fc0.wwww\n' +
                'rcp ' + tmp + '.x, ' + tmp + '.x\n' +
                'sub ' + tmp + '.x, ' + tmp + '.x, fc6.wwww\n' +
                'mul ' + out + '.xyz, ft6.xyz, ' + tmp + '.xxxx\n' +
                'add ' + out + '.xyz, ' + out + '.xyz, fc6.wwww\n';
        }

        // Whether a texture's texels need decoding. Only SRGBColorSpace does:
        // three.js defaults Texture.colorSpace to NoColorSpace, and a roughness
        // or normal map is linear data even when it happens to be an image.
        public static function needsDecode(texture:Texture):Boolean
        {
            return texture != null && texture.colorSpace == Texture.SRGBColorSpace;
        }

        // The decode mask for a standard draw. The two data slots are optional
        // arguments so the M17 call sites and probes keep their 3-argument shape.
        public static function decodeMaskFor(map:Texture, emissiveMap:Texture, env:CubeTexture,
                                             roughnessMap:Texture = null,
                                             metalnessMap:Texture = null):int
        {
            var mask:int = 0;
            if (AGALRenderer.needsDecode(map)) mask |= AGALRenderer.DECODE_MAP;
            if (AGALRenderer.needsDecode(emissiveMap)) mask |= AGALRenderer.DECODE_EMISSIVE;
            if (AGALRenderer.needsDecode(env)) mask |= AGALRenderer.DECODE_ENV;
            if (AGALRenderer.needsDecode(roughnessMap)) mask |= AGALRenderer.DECODE_ROUGHNESS;
            if (AGALRenderer.needsDecode(metalnessMap)) mask |= AGALRenderer.DECODE_METALNESS;
            return mask;
        }

        // three.js wrap pair -> Stage3D wrap mode string. The backend decodes
        // only "repeat" (everything else is clamp) and has a SINGLE wrap flag
        // per sampler, so a mixed pair (repeat on one axis, clamp on the other)
        // cannot be expressed. Such a pair falls back to repeat -- the axis that
        // asked for tiling keeps working, and repeating is the identity for a
        // uv that stays inside [0,1] -- and the caller warns once.
        public static function wrapModeFor(wrapS:int, wrapT:int):String
        {
            if (AGALRenderer.wrapAxisFor(wrapS) == 1 || AGALRenderer.wrapAxisFor(wrapT) == 1) return "repeat";
            return "clamp";
        }

        // True when the two axes disagree (or either asks for mirrored repeat),
        // i.e. when wrapModeFor() had to collapse something.
        public static function wrapIsLossy(wrapS:int, wrapT:int):Boolean
        {
            if (wrapS == Texture.MirroredRepeatWrapping || wrapT == Texture.MirroredRepeatWrapping) return true;
            return AGALRenderer.wrapAxisFor(wrapS) != AGALRenderer.wrapAxisFor(wrapT);
        }

        // 1 = repeat, 0 = clamp. MirroredRepeatWrapping reports 1 (mirroring has
        // no Stage3D equivalent; the caller warns).
        public static function wrapAxisFor(wrap:int):int
        {
            return (wrap == Texture.RepeatWrapping || wrap == Texture.MirroredRepeatWrapping) ? 1 : 0;
        }

        // Stage3D has ONE filter per slot, three.js has separate mag/min. The
        // minification filter wins: magnification with a linear filter is
        // already correct for every non-nearest texture, whereas minifying with
        // nearest is the visible artefact this is here to avoid.
        public static function samplerFilterFor(minFilter:int, magFilter:int):String
        {
            var minNearest:Boolean = minFilter == Texture.NearestFilter
                || minFilter == Texture.NearestMipmapNearestFilter
                || minFilter == Texture.NearestMipmapLinearFilter;
            if (minNearest) return "nearest";
            return "linear";
        }

        // The Stage3D mip filter for a texture. A mip filter is only legal when
        // a chain actually exists: AIR drops the ENTIRE draw when a mip-filtered
        // sample hits a chain-less texture, so generateMipmaps=false (or a
        // non-mip minFilter) must report "none" even if minFilter asks for mips.
        // The strings match what the backend decodes ("mipnearest"/"miplinear";
        // anything else is none).
        public static function mipFilterFor(minFilter:int, generateMipmaps:Boolean):String
        {
            // "mipnone", not "none": Context3D.setSamplerStateAt rejects the latter
            // with #2008 ("Parameter mipfilter must be one of the accepted values"),
            // and as-aot's glue silently treated any unknown string as no mip.
            if (!generateMipmaps) return "mipnone";
            if (minFilter == Texture.NearestMipmapNearestFilter
                || minFilter == Texture.LinearMipmapNearestFilter) return "mipnearest";
            if (minFilter == Texture.NearestMipmapLinearFilter
                || minFilter == Texture.LinearMipmapLinearFilter) return "miplinear";
            return "mipnone";
        }

        // Size of a mip level (half each step, floor at 1).
        public static function mipDimension(size:int, level:int):int
        {
            var d:int = size >> level;
            return d < 1 ? 1 : d;
        }

        // Highest level index that still has a distinct size.
        public static function mipLevelCount(width:int, height:int):int
        {
            var n:int = 0;
            var dim:int = Math.max(width, height);
            while (dim > 1) { dim >>= 1; n++; }
            return n + 1;
        }

        // Generate and upload levels 1..N for a 2D texture. Halving with
        // BitmapData.draw(smoothing=true) is a bilinear box reduction -- the
        // same shape as a GPU-generated chain, computed once at upload rather
        // than per frame.
        public static function uploadMipChain(target:flash.display3D.textures.Texture, level0:BitmapData):void
        {
            var w:int = level0.width;
            var h:int = level0.height;
            var levels:int = AGALRenderer.mipLevelCount(w, h);
            var src:BitmapData = level0;
            var level:int = 1;
            while (level < levels)
            {
                var nw:int = AGALRenderer.mipDimension(w, level);
                var nh:int = AGALRenderer.mipDimension(h, level);
                var dst:BitmapData = new BitmapData(nw, nh, src.transparent, 0);
                var m:Matrix = new Matrix();
                m.scale(nw / src.width, nh / src.height);
                dst.draw(src, m, null, null, null, true);
                target.uploadFromBitmapData(dst, level);
                src = dst;
                level++;
            }
        }

        // AIR requires EVERY level of a cube texture, even when the sampler asks
        // for mipnone: a cube with only level 0 uploaded makes the whole draw
        // fail with #3700 "incomplete texture" (measured on adl 51.4.1 -- the
        // 8x8 neutral environment cube reproduced it on its own). 2D textures
        // only need the levels the sampler can reach, so the 2D path stays
        // level-0 + chain-on-demand.
        public static function uploadCubeChain(target:flash.display3D.textures.CubeTexture,
                                               face:BitmapData, side:int):void
        {
            var w:int = face.width;
            var levels:int = AGALRenderer.mipLevelCount(w, face.height);
            target.uploadFromBitmapData(face, side, 0);
            var src:BitmapData = face;
            for (var level:int = 1; level < levels; level++)
            {
                var nw:int = AGALRenderer.mipDimension(w, level);
                var nh:int = AGALRenderer.mipDimension(face.height, level);
                var dst:BitmapData = new BitmapData(nw, nh, src.transparent, 0);
                var m:Matrix = new Matrix();
                m.scale(nw / src.width, nh / src.height);
                dst.draw(src, m, null, null, null, true);
                target.uploadFromBitmapData(dst, side, level);
                src = dst;
            }
        }

        // flipY=true means "t=0 is the image's BOTTOM row" (three.js / WebGL
        // convention). Stage3D uploads rows in memory order and its t=0 is the
        // TOP row, so the rows have to be reversed at upload time.
        public static function flipRows(src:BitmapData):BitmapData
        {
            var out:BitmapData = new BitmapData(src.width, src.height, src.transparent, 0);
            var m:Matrix = new Matrix();
            m.scale(1, -1);
            m.translate(0, src.height);
            out.draw(src, m, null, null, null, true);
            return out;
        }

        // scene.background (a Color in the linear working space) -> the four
        // floats to clear with. The back buffer holds sRGB-encoded values (every
        // program ends in the R7 pow encode), so the clear value must be encoded
        // too, or a colored background would be visibly darker than the same
        // color drawn as geometry.
        public static function clearColorOf(background:Object):Vector.<Number>
        {
            var out:Vector.<Number> = new Vector.<Number>(4);
            AGALRenderer.clearColorInto(out, background);
            return out;
        }

        // Allocation-free form used by render(): the renderer owns one scratch
        // vector, because a per-frame Vector in the arena is exactly the leak
        // AGENTS.md's memory red-line forbids.
        public static function clearColorInto(out:Vector.<Number>, background:Object):void
        {
            out[0] = 0;
            out[1] = 0;
            out[2] = 0;
            out[3] = 1;
            if (background is Color)
            {
                var hex:uint = Color(background).getHex();
                out[0] = (hex >> 16 & 255) / 255;
                out[1] = (hex >> 8 & 255) / 255;
                out[2] = (hex & 255) / 255;
            }
        }

        // One-time diagnostic. A per-frame trace would drown the log; silence
        // would hide an unsupported request (AGENTS.md: never degrade silently).
        private function _warnOnce(key:String, message:String):void
        {
            if (this._warned[key] != null) return;
            this._warned[key] = true;
            trace("AGALRenderer: " + message);
        }

        // ------------------------------------------------------------------
        // M19: render state (side / depthTest / depthWrite / blending).
        //
        // Before M19 the renderer set ONE culling / depth / blend state for a
        // whole pass and every Material field that is supposed to override it
        // was dead. These helpers map one Material to the Stage3D calls, and are
        // static + public so the probe can pin the table without a GPU.
        //
        // CULLING IS INVERTED. The Stage3D backend declares front-facing = CW
        // (Starling convention) while three.js geometry winds CCW, so a CCW
        // front face is the backend's BACK face. Culling three.js BACK faces
        // (what FrontSide means) is therefore setCulling('front'). Getting this
        // table wrong is invisible for closed meshes and fatal for thin ones.
        // ------------------------------------------------------------------

        // Material.side -> Context3D.setCulling. 'front' = cull the backend's
        // front face = cull three.js back faces.
        public static function cullingFor(side:int):String
        {
            if (side == Material.BackSide) return "back";
            if (side == Material.DoubleSide) return "none";
            return "front";
        }

        // Shadow-pass culling. three.js maps the caster's side through
        // shadowSide = {FrontSide: BackSide, BackSide: FrontSide, DoubleSide:
        // DoubleSide} so a closed caster records its FAR surface and stops
        // shadowing itself (WebGLShadowMap.js:51,486). This port keeps the
        // FrontSide path on front faces: our verified cutout casters are single-
        // sided plates, and `BackSide` would cull every face of such a plate,
        // deleting its shadow outright. BackSide/DoubleSide do take effect.
        // Recorded as R36 in three-api-design.md §24.
        public static function shadowCullingFor(side:int):String
        {
            if (side == Material.BackSide) return "front";
            if (side == Material.DoubleSide) return "none";
            return "front";
        }

        // Stage3D's setDepthTest(depthMask, compare) carries BOTH halves of the
        // OpenGL depth state: depthMask is the WRITE mask, the compare mode is
        // the test. three.js expresses "no depth test" by disabling GL_DEPTH_TEST
        // (WebGLState.setMaterial), and a disabled depth test also stops writes,
        // so depthTest = false -> compare 'always' AND write off.
        public static function depthMaskFor(depthTest:Boolean, depthWrite:Boolean):Boolean
        {
            return depthTest && depthWrite;
        }

        public static function depthCompareFor(depthTest:Boolean):String
        {
            return depthTest ? "lessEqual" : "always";
        }

        // Material.blending -> (setBlendFactors source, destination). three.js
        // WebGLState.setBlending r187: NoBlending disables GL_BLEND; Normal =
        // (SRC_ALPHA, ONE_MINUS_SRC_ALPHA); Additive adds (SRC_ALPHA, ONE);
        // Subtractive is (ZERO, ONE_MINUS_SRC_COLOR); Multiply is (ZERO,
        // SRC_COLOR). All five map onto Stage3D factor names.
        public static function blendSrcFor(blending:int):String
        {
            switch (blending)
            {
                case Material.NoBlending: return "one";
                case Material.AdditiveBlending: return "sourceAlpha";
                case Material.SubtractiveBlending: return "zero";
                case Material.MultiplyBlending: return "zero";
                default: return "sourceAlpha";
            }
        }

        public static function blendDstFor(blending:int):String
        {
            switch (blending)
            {
                case Material.NoBlending: return "zero";
                case Material.AdditiveBlending: return "one";
                case Material.SubtractiveBlending: return "oneMinusSourceColor";
                case Material.MultiplyBlending: return "sourceColor";
                default: return "oneMinusSourceAlpha";
            }
        }

        // CustomBlending needs per-material blendSrc/blendDst, which this port
        // does not expose yet; it degrades to NormalBlending with a one-time
        // diagnostic instead of silently drawing something else (R35).
        public static function blendingImplemented(blending:int):Boolean
        {
            return blending >= Material.NoBlending && blending <= Material.MultiplyBlending;
        }

        // ------------------------------------------------------------------
        // M18: uv transform (Texture.offset/repeat/rotation/center/matrix).
        //
        // three.js gives EVERY map its own transform uniform and its own uv
        // varying:
        //
        //     vMapUv      = (mapTransform      * vec3(uv, 1)).xy
        //     vNormalMapUv= (normalMapTransform* vec3(uv, 1)).xy   ... one per map
        //
        // (uv_vertex.glsl.js). The transform itself is refreshTransformUniform
        // (WebGLMaterials.js:13-22): if matrixAutoUpdate, map.updateMatrix(),
        // then the matrix is copied into the uniform.
        //
        // Stage3D has no uniform block to hang that on, so each slot's uv is
        // transformed in the VERTEX program into a packed varying and read back
        // by the fragment. Six material slots need six (u,v) pairs; AGAL's
        // varyings hold four floats each, so they share registers:
        //
        //     v2 = (mapU, mapV, normalU, normalV)     v3 = v2  (ddy copy)
        //     v6 = (roughU, roughV, metalU, metalV)
        //     v7 = (emissiveU, emissiveV, aoU, aoV)
        //
        // v3 is a plain copy of v2 for the same reason the pre-M18 shader kept
        // one: the tangent frame needs ddx(uv) and ddy(uv) of the NORMAL MAP's
        // uv (three.js passes vNormalMapUv to getTangentFrame), and AGAL's
        // derivative opcodes read a register directly -- so the value has to sit
        // in the component the write-mask picks: `.zwzw` selects v.z/v.w.
        // ------------------------------------------------------------------

        // Slot order of the uv transform block. The numbers are also the order
        // of `_uvRows` (8 floats per slot), and the shader reads slot k from
        // uvVaryingOf(k).
        public static const UV_MAP:int = 0;
        public static const UV_NORMAL:int = 1;
        public static const UV_ROUGHNESS:int = 2;
        public static const UV_METALNESS:int = 3;
        public static const UV_EMISSIVE:int = 4;
        public static const UV_AO:int = 5;
        public static const UV_SLOTS:int = 6;
        // vc40..vc51: two constant registers per slot. vc0..vc3 MVP, vc4..vc7
        // model, vc8..vc10 normal matrix, vc12..vc19 shadow matrices, vc20/vc21
        // shadow biases, vc22 receiveShadow -- 40 is the first free block that
        // leaves headroom under AIR's 128 vertex-constant limit.
        public static const UV_CONST_BASE:int = 40;

        // The varying component that carries slot `k`'s transformed uv. The
        // shader source and the probe's expectations are pinned to this one
        // table so a re-pack cannot silently sample the wrong pair.
        public static function uvVaryingOf(slot:int):String
        {
            switch (slot)
            {
                case AGALRenderer.UV_MAP: return "v2.xy";
                case AGALRenderer.UV_NORMAL: return "v2.zw";
                case AGALRenderer.UV_ROUGHNESS: return "v6.xy";
                case AGALRenderer.UV_METALNESS: return "v6.zw";
                case AGALRenderer.UV_EMISSIVE: return "v7.xy";
                case AGALRenderer.UV_AO: return "v7.zw";
            }
            return "v2.xy";
        }

        // three.js WebGLMaterials.refreshTransformUniform (WebGLMaterials.js:13-22).
        // A null texture reports null, which uvRowsInto() turns into identity.
        public static function uvMatrixOf(texture:Texture):Matrix3
        {
            if (texture == null) return null;
            if (texture.matrixAutoUpdate) texture.updateMatrix();
            return texture.matrix;
        }

        // Whether the packed rows are the identity transform, i.e. whether the
        // vertex program's dp4 pair reproduces (u,v) exactly. Used only for
        // diagnostics: the transform is applied unconditionally (three.js also
        // emits the mat3 multiply for every mapped draw), and dp4 against
        // (1,0,0,0)/(0,1,0,0) is exact.
        public static function uvIsIdentity(texture:Texture):Boolean
        {
            var m:Matrix3 = AGALRenderer.uvMatrixOf(texture);
            if (m == null) return true;
            var e:Vector.<Number> = m.elements;
            return e[0] == 1 && e[1] == 0 && e[3] == 0 && e[4] == 1 && e[6] == 0 && e[7] == 0;
        }

        // Pack a uv matrix into two constant registers at out[base..base+7]:
        //
        //     rowU = (m00, m10, 0, m20)   -> u' = dot((u, v, 0, 1), rowU)
        //     rowV = (m01, m11, 0, m21)   -> v' = dot((u, v, 0, 1), rowV)
        //
        // The `0` and `1` are not literals the shader supplies: Stage3D fills a
        // FLOAT_2 attribute's missing components with 0 for z and 1 for w (the
        // same default as GL's generic attribute state), which is exactly what
        // makes a 2-instruction dp4 pair enough for an affine uv transform.
        // Matrix3 is column-major, so m00 = e[0], m10 = e[3], m20 = e[6].
        public static function uvRowsInto(out:Vector.<Number>, base:int, m:Matrix3):void
        {
            if (m == null)
            {
                out[base] = 1; out[base + 1] = 0; out[base + 2] = 0; out[base + 3] = 0;
                out[base + 4] = 0; out[base + 5] = 1; out[base + 6] = 0; out[base + 7] = 0;
                return;
            }
            var e:Vector.<Number> = m.elements;
            out[base] = e[0]; out[base + 1] = e[3]; out[base + 2] = 0; out[base + 3] = e[6];
            out[base + 4] = e[1]; out[base + 5] = e[4]; out[base + 6] = 0; out[base + 7] = e[7];
        }

        // The vertex-program block that turns va2 into the six packed uvs. One
        // dp4 per uv row plus one mov per varying: 12 + 4 = 16 instructions,
        // paid by every draw because the constants are per-draw state and the
        // program is shared.
        //
        // vt3/vt4 must be free temporaries in the calling program.
        //
        // NOTE: the concatenation is assigned to a local before the return. AS3
        // applies automatic semicolon insertion to `return`, so `return` followed
        // by a newline returns undefined -- which silently turned this whole block
        // into a literal "null" line inside the vertex source (and the pipeline
        // then failed with "fragment inputs not written by vertex shader").
        public static function uvTransformBlock():String
        {
            var b:int = AGALRenderer.UV_CONST_BASE;
            var s:String =
                'dp4 vt3.x, va2, vc' + b + '\n' +
                'dp4 vt3.y, va2, vc' + (b + 1) + '\n' +
                'dp4 vt3.z, va2, vc' + (b + 2) + '\n' +
                'dp4 vt3.w, va2, vc' + (b + 3) + '\n' +
                'mov v2, vt3\n' +
                'mov v3, vt3\n' +
                'dp4 vt4.x, va2, vc' + (b + 4) + '\n' +
                'dp4 vt4.y, va2, vc' + (b + 5) + '\n' +
                'dp4 vt4.z, va2, vc' + (b + 6) + '\n' +
                'dp4 vt4.w, va2, vc' + (b + 7) + '\n' +
                'mov v6, vt4\n' +
                'dp4 vt4.x, va2, vc' + (b + 8) + '\n' +
                'dp4 vt4.y, va2, vc' + (b + 9) + '\n' +
                'dp4 vt4.z, va2, vc' + (b + 10) + '\n' +
                'dp4 vt4.w, va2, vc' + (b + 11) + '\n' +
                'mov v7, vt4\n';
            return s;
        }

        // Bind an environment cube map to a sampler slot (M9). A null cube, or
        // one whose faces are not all decoded yet, binds the neutral white cube;
        // the draw's fc10.x is 0 in that case, so the sample is multiplied away.
        //
        // The GPU cube is (re)built only when the face size changes or the
        // author bumped CubeTexture.needsUpdate -- the same version contract as
        // _bindTexture. All six faces upload in one pass so a half-filled cube
        // can never be sampled.
        private function _bindCubeTexture(cube:CubeTexture, slot:int):void
        {
            if (cube == null || cube.images.length < 6 || !this._hasAllFaces(cube))
            {
                // Reset the slot's sampler state too: the neutral cube must not
                // inherit a leftover REPEAT/pinned filter from an unrelated draw
                // (Stage3D keeps one state per slot across setTextureAt calls).
                this._context.setTextureAt(slot, this._neutralCube);
                this._context.setSamplerStateAt(slot, "clamp", "linear", "mipnone");
                return;
            }

            var gpu:GPUCubeResources = GPUCubeResources(this._cubeCache[cube]);
            if (gpu == null)
            {
                gpu = new GPUCubeResources();
                this._cubeCache[cube] = gpu;
            }

            var size:int = cube.images[0].width;
            // Cube chains are built by the BACKEND from level 0 (stage3d_glue.mm
            // s3d_generate_cube_mips, a blit right after the six faces land), and
            // this runtime ignores uploadFromBitmapData(side, miplevel > 0)
            // outright (CubeTexture_uploadFromBitmapData: `if (miplevel != 0)
            // return;`). So there is no chain for the renderer to generate -- the
            // mip FILTER is the only thing left to honour, and it is legal because
            // every bound cube reports a chain.
            if (gpu.cube == null || gpu.size != size)
            {
                gpu.cube = this._context.createCubeTexture(size, Context3DTextureFormat.BGRA, false);
                gpu.size = size;
                gpu.uploadVersion = -1;
            }

            if (gpu.uploadVersion != cube.version)
            {
                var side:int;
                for (side = 0; side < 6; side++)
                {
                    // CubeTexture pins flipY=false (see CubeTexture.as): a face's
                    // rows already run top-down like a glTF cubemap.
                    AGALRenderer.uploadCubeChain(gpu.cube, cube.images[side], side);
                }
                gpu.uploadVersion = cube.version;
            }

            // setTextureAt, not setCubeTextureAt: AIR's Context3D.setTextureAt takes
            // a TextureBase and is the ONLY way to bind a cube texture -- there is
            // no setCubeTextureAt in the real API (#1069 at runtime).
            this._context.setTextureAt(slot, gpu.cube);
            // M17: cube wrap is always clamp (three.js does the same -- a cube
            // sample is a direction, not a uv) and the filter/mip come from the
            // texture.
            this._context.setSamplerStateAt(slot, "clamp",
                AGALRenderer.samplerFilterFor(cube.minFilter, cube.magFilter),
                AGALRenderer.mipFilterFor(cube.minFilter, cube.generateMipmaps));

        }

        private function _hasAllFaces(cube:CubeTexture):Boolean
        {
            var i:int;
            for (i = 0; i < 6; i++)
            {
                if (cube.images[i] == null) return false;
            }
            return true;
        }

        // Bind a material texture to a sampler slot; a null texture (or a
        // texture without an uploaded image) binds the neutral 1x1 for that
        // slot instead (R8). The slot->texture mapping is fs0 base color,
        // fs1 normal, fs2 roughness, fs3 metalness, fs5 emissive, fs6 AO.
        //
        // M17 turned every inert Texture field into real Stage3D state:
        //   * generateMipmaps + a mip minFilter -> a chain is generated at upload
        //     (mip-filtering a chain-less texture makes AIR DROP the whole draw,
        //     so the two can never be set independently);
        //   * flipY -> the rows are flipped before upload (Stage3D's t=0 is the
        //     bitmap's TOP row, three.js's flipY=true means t=0 is the bottom);
        //   * wrapS/wrapT + filters -> setSamplerStateAt AFTER setProgram, which
        //     is what makes them win over the program's inline `<2d,clamp,...>`
        //     default (measured ordering: last writer wins, see as3compiler
        //     docs/zh-cn/display3d.md 9.5).
        private function _bindTexture(texture:Texture, slot:int):void
        {
            if (texture == null || texture.image == null)
            {
                // The neutral 1x1s keep the program's default state: the cached
                // state from a previous draw's setSamplerStateAt must not leak
                // into them, so reset it explicitly.
                this._context.setTextureAt(slot, slot == 1 ? this._neutralNormal : this._neutralWhite);
                this._context.setSamplerStateAt(slot, "clamp", "linear", "mipnone");
                return;
            }

            var gpu:GPUTextureResources = GPUTextureResources(this._textureCache[texture]);
            if (gpu == null)
            {
                gpu = new GPUTextureResources();
                this._textureCache[texture] = gpu;
            }

            var bmp:BitmapData = texture.image;
            var mip:String = AGALRenderer.mipFilterFor(texture.minFilter, texture.generateMipmaps);
            // A 1x1 image has no chain to build (mipLevelCount(1,1) == 1), and a
            // mip filter on a chain-less texture drops the whole draw (R30), so a
            // 1x1 that kept three.js's default LinearMipmapLinear would silently
            // delete its own geometry. Ask for no mip filter instead.
            if (bmp.width <= 1 && bmp.height <= 1) mip = "mipnone";
            var wantsChain:Boolean = mip != "mipnone";

            if (gpu.texture == null || gpu.width != bmp.width || gpu.height != bmp.height
                || gpu.mipmapped != wantsChain)
            {
                // 4th argument is optimizeForRenderToTexture, NOT a mip switch:
                // a sampled texture must pass false, or AIR allocates it as a
                // render target with no mip storage and every mip-sampling draw
                // fails with #3700 "incomplete texture". The chain is defined by
                // the uploadFromBitmapData levels below.
                gpu.texture = this._context.createTexture(bmp.width, bmp.height,
                                                          Context3DTextureFormat.BGRA, false);
                gpu.width = bmp.width;
                gpu.height = bmp.height;
                gpu.mipmapped = wantsChain;
                gpu.uploadVersion = -1;
            }

            // Re-upload only when the author bumped needsUpdate (version changed).
            if (gpu.uploadVersion != texture.version)
            {
                // flipY is a ROW ORDER change, so it has to happen before the
                // level-0 upload (and before the chain is derived from it, or
                // every level would disagree with level 0).
                var src:BitmapData = texture.flipY ? AGALRenderer.flipRows(bmp) : bmp;
                gpu.texture.uploadFromBitmapData(src, 0);
                if (wantsChain) AGALRenderer.uploadMipChain(gpu.texture, src);
                gpu.uploadVersion = texture.version;
            }

            this._context.setTextureAt(slot, gpu.texture);
            this._context.setSamplerStateAt(slot, AGALRenderer.wrapModeFor(texture.wrapS, texture.wrapT),
                                           AGALRenderer.samplerFilterFor(texture.minFilter, texture.magFilter),
                                           mip);

            if (AGALRenderer.wrapIsLossy(texture.wrapS, texture.wrapT))
            {
                this._warnOnce("wrap",
                    "wrapS/wrapT " + texture.wrapS + "/" + texture.wrapT +
                    " has no Stage3D equivalent (the backend keeps ONE wrap flag per slot); " +
                    "slot fs" + slot + " uses '" + AGALRenderer.wrapModeFor(texture.wrapS, texture.wrapT) + "'");
            }
        }

        // ------------------------------------------------------------------
        // AGAL program generation.
        // ------------------------------------------------------------------

        private function _buildBasicProgram(map:Boolean, decode:Boolean, fog:Boolean,
                                           toneMapped:Boolean = true):Program3D
        {
            // Vertex: MVP-transform position (va0). M20 adds the map slot's uv
            // transform (vc40/vc41) for a textured unlit material; without a
            // map no varying is written at all.
            var vertexSrc:String =
                'dp4 op.x, va0, vc0\n' +
                'dp4 op.y, va0, vc1\n' +
                'dp4 op.z, va0, vc2\n' +
                'dp4 op.w, va0, vc3\n';
            if (map)
            {
                vertexSrc +=
                    'dp4 v2.x, va2, vc40\n' +
                    'dp4 v2.y, va2, vc41\n' +
                    // AIR requires a varying to have ALL FOUR components written
                    // somewhere in the vertex program (#3633); the fragment samples
                    // v2.xy only, so .zw is padding. Measured on adl 51.4.1: the
                    // writes need not be in one instruction, they must merely cover
                    // xyzw between them.
                    'mov v2.zw, vc0.xxxx\n';
            }
            if (fog)
            {
                // M20: the fog block needs the fragment's WORLD position in
                // v1 (same convention as the standard program, where v1 is the
                // model-transformed vertex). A colour-only unlit draw with fog
                // therefore pays four extra vertex instructions and one more
                // uploaded constant row block (vc4..vc7).
                vertexSrc +=
                    'dp4 vt0.x, va0, vc4\n' +
                    'dp4 vt0.y, va0, vc5\n' +
                    'dp4 vt0.z, va0, vc6\n' +
                    'mov v1.xyz, vt0.xyz\n' +
                    'mov v1.w, vc0.xxxx\n';   // padding: AIR #3633 needs all four
            }

            var fragSrc:String = '';
            if (map)
            {
                fragSrc +=
                    'tex ft0, v2.xy, fs0 <2d,clamp,linear,mipnone>\n' +
                    AGALRenderer.srgbDecodeBlock('ft0', decode ? AGALRenderer.DECODE_MAP : 0,
                                                 AGALRenderer.DECODE_MAP, 'ft1') +
                    // map_fragment.glsl.js: `diffuseColor *= sampledDiffuseColor`
                    // -- rgb AND alpha, so a textured unlit material can carry
                    // cutout transparency and honour alphaTest.
                    'mul ft0, ft0, fc0\n';
            }
            else
            {
                fragSrc += 'mov ft0, fc0\n';
            }
            fragSrc += this._basicFragmentTail(fog, toneMapped);

            // AGAL 2: the uv-transform rows live at vc40+ and the fog block at
            // fc37+, both above AGAL 1's 28-register file. Assembling with the
            // default version silently yields a ZERO-LENGTH program (the
            // assembler only traces "index exceeds limit of 28"), which the
            // backend then reports as the useless "bytecode too short for
            // header" at draw time.
            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            vertex.assemble(Context3DProgramType.VERTEX, vertexSrc, AGAL_VERSION);

            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT, fragSrc, AGAL_VERSION);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            this._noteStreams(program, vertexSrc, fragSrc);
            return program;
        }

        // The unlit fragment body shared by MeshBasicMaterial and
        // LineBasicMaterial. Kept in one place so the two can never drift apart
        // on tone mapping, alpha test or the R7 sRGB encode.
        //   fc0      material color (rgb) + opacity (w)  [already sampled]
        //   fc1.w    legacy 1/2.2 (unused since D170; fc42.x is the exponent)
        //   fc14..21 tone mapping (M10)
        //   fc37..40 fog (M20)
        //   fc41..42 sRGB transfer-function constants (D170)
        //   v1       M26 per-vertex colour (lines only; see lineVertexSource)
        private function _basicFragmentSource(fog:Boolean = false, vertexColors:Boolean = false,
                                              toneMapped:Boolean = true):String
        {
            return 'mov ft0, fc0\n' +
                // M26: three.js `diffuseColor *= vColor`
                // (color_fragment.glsl.js). rgb only: glTF/helper vertex colours
                // never carry alpha, and multiplying w would silently scale the
                // material opacity per vertex.
                (vertexColors ? 'mul ft0.xyz, ft0.xyz, v1.xyz\n' : '') +
                this._basicFragmentTail(fog, toneMapped);
        }

        // Tone map -> R7 sRGB encode -> alpha test -> output, on the COLOR
        // already sitting in ft0 (rgb) with its alpha in ft0.w.
        private function _basicFragmentTail(fog:Boolean = false, toneMapped:Boolean = true):String
        {
            return (
                // M20: fog mixes the LINEAR color toward the fog colour before
                // tone mapping (fog_fragment.glsl.js runs before
                // tonemapping_fragment, same order as three.js).
                (fog ? this._fogBlock('ft0', 'ft2', 'ft3') : '') +
                // M10: tone map the LINEAR color, then encode (three.js
                // tonemapping_fragment runs before the colour-space conversion).
                // M26: `material.toneMapped = false` drops the block entirely --
                // three.js does the same with a #define, and the value only makes
                // sense on helpers whose colour is authored, not lit.
                (toneMapped ? this._toneMapBlock('ft0', 'ft1', 'ft2', 'ft3') : '') +
                'sat ft0.xyz, ft0.xyz\n' +
                // D170: the sRGB OETF, replacing pow(x, 1/2.2) (fc1.w is now
                // uploaded for nothing but the pre-D170 layout).
                AGALRenderer.srgbEncodeBlock('ft0') +
                // M10 alpha test. ft0.w is the material opacity (fc0.w); kil
                // discards when any component is negative, so a - alphaTest is
                // replicated across the register.
                'sub ft1, ft0.wwww, fc15.zzzz\n' +
                'kil ft1.xxxx\n' +
                'mov oc, ft0\n');
        }

        // M11: line-segment program. Stage3D has no line primitive, so each
        // segment is drawn as two triangles whose vertices are pushed off the
        // segment by +-halfWidth in SCREEN space. Per vertex:
        //   va0 = this endpoint (model space)
        //   va1 = the segment's OTHER endpoint (model space)
        //   va2.x = signed side (-1 or +1)
        //   vc0..vc3 = MVP, vc4 = (halfWidthPixels, halfHeightPixels,
        //                          halfLineWidthPixels, -1)
        // The end vertices pass the start as `other`, which reverses the
        // projected direction, so their side signs are pre-negated by the
        // CPU-side expansion (see _buildLineBuffers) to keep one consistent
        // perpendicular for the whole quad.
        //
        // Known limit: a segment that projects to zero screen length makes
        // rsq(0) infinite and the quad degenerates to nothing. That is the
        // correct visual outcome (an edge seen exactly end-on covers no pixels),
        // recorded in three-api-design.md §16.
        // The line/edge vertex program, as AGAL source. Public and static so the
        // structural probe (probes/geometry-smoke-m11) assembles the SAME text the
        // renderer uploads: a copy in the probe drifts the moment this changes
        // (it did -- twice).
        public static function lineVertexSource(vertexColors:Boolean = false):String
        {
            // clip positions of both endpoints. Written as four dp4s, not
            // `m44`: the constants are uploaded TRANSPOSED (vc0..vc3 hold the
            // matrix ROWS, see R1), which is exactly what dp4 assumes, while
            // m44's matrix layout in the AGAL translator does not agree with
            // it -- using m44 here put every segment at the wrong place.
            //
            // `return` and its operand MUST share a line: AS3 inserts a semicolon
            // after a newline, so a wrapped `return` yields undefined and the
            // assembler then dies on a null `source` (measured: this exact wrapping
            // cost every demo frame 1 with #1009).
            return 'dp4 vt6.x, va0, vc0\n' +
                    'dp4 vt6.y, va0, vc1\n' +
                    'dp4 vt6.z, va0, vc2\n' +
                    'dp4 vt6.w, va0, vc3\n' +
                    'dp4 vt0.x, va1, vc0\n' +
                    'dp4 vt0.y, va1, vc1\n' +
                    'dp4 vt0.z, va1, vc2\n' +
                    'dp4 vt0.w, va1, vc3\n' +
                    // -> NDC
                    'rcp vt1.w, vt6.w\n' +
                    'mul vt1.xyz, vt6.xyz, vt1.w\n' +
                    'rcp vt2.w, vt0.w\n' +
                    'mul vt2.xyz, vt0.xyz, vt2.w\n' +
                    // direction, scaled into half-pixel units so the perpendicular
                    // is isotropic (NDC x and y have different pixel densities)
                    'sub vt3.xyz, vt2.xyz, vt1.xyz\n' +
                    'mul vt3.x, vt3.x, vc4.x\n' +
                    'mul vt3.y, vt3.y, vc4.y\n' +
                    // 2D normalize (no nrm: it would fold the depth component in)
                    'mul vt5.x, vt3.x, vt3.x\n' +
                    'mul vt5.y, vt3.y, vt3.y\n' +
                    'add vt5.x, vt5.x, vt5.y\n' +
                    'rsq vt5.x, vt5.x\n' +
                    'mul vt3.xy, vt3.xy, vt5.xx\n' +
                    // perpendicular = (-dy, dx), times side and half width.
                    // AGAL source operands have no unary minus (the bundled
                    // AGALMiniAssembler's operand regex accepts no sign), so -dy is
                    // produced by multiplying by vc4.w = -1 rather than writing
                    // `mov vt4.x, -vt3.y`.
                    'mul vt4.x, vt3.y, vc4.w\n' +
                    'mov vt4.y, vt3.x\n' +
                    'mul vt4.xy, vt4.xy, va2.x\n' +
                    'mul vt4.xy, vt4.xy, vc4.z\n' +
                    // back into NDC
                    // vc5 = 1/(halfWidth, halfHeight), precomputed on the CPU. Two
                    // reasons, both measured: (a) AIR refuses every single-source math
                    // opcode on a constant -- `rcp vt5.x, vc4.x` fails upload with
                    // #3625 "Both are constants", which as-aot happily accepted; and
                    // (b) a reciprocal of a per-frame constant is strict CPU work, so
                    // one multiply replaces two GPU rcps.
                    'mul vt4.xy, vt4.xy, vc5.xy\n' +
                    'add vt1.xy, vt1.xy, vt4.xy\n' +
                    // `op` is a CLIP-space position -- the GPU divides xy by w AFTER
                    // the program. vt1.xy is NDC, so the offset computed above has
                    // to be scaled back by w (vt6.w) before it is written out;
                    // without this the whole quad shrinks by 1/w and collapses
                    // around the camera axis.
                    'mul vt6.xy, vt1.xy, vt6.wwww\n' +
                    'mov op, vt6\n' +
                    // M26: per-vertex colour rides va3 -> varying v1. One extra
                    // stream, no extra temporary: v1 is a varying, not a vt
                    // register, and every vt is already spoken for above.
                    (vertexColors ? 'mov v1, va3\n' : '');
        }

        // M26: cached accessor for the (vertexColors, toneMapped) line variants.
        private function _getLineProgram(vertexColors:Boolean, toneMapped:Boolean):Program3D
        {
            var key:String = (vertexColors ? "1" : "0") + ":" + (toneMapped ? "1" : "0");
            var program:Program3D = Program3D(this._lineVariants[key]);
            if (program == null)
            {
                program = this._buildLineProgram(vertexColors, toneMapped);
                this._lineVariants[key] = program;
            }
            return program;
        }

        private function _buildLineProgram(vertexColors:Boolean, toneMapped:Boolean):Program3D
        {
            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            // Vertex temporaries are vt0..vt7 in AGAL1 (ft* is fragment-only),
            // and `op` is never read back: the clip position is built in vt6 and
            // moved to op once, so no instruction depends on the output register.
            // All eight are in use, so nothing here can be rewritten into an extra
            // temporary; constants that only need transforming are precomputed on
            // the CPU (vc5) instead.
            //
            // D170: this pair is ALSO assembled at AGAL_VERSION, not the AGAL1 the
            // vertex program's register budget would allow. The shared
            // _basicFragmentTail now ends in srgbEncodeBlock, whose constants live
            // at fc41/fc42 -- past AGAL1's 28-register file, which makes the
            // assembler print "index exceeds limit of 28" and hand back an EMPTY
            // program (the draw then silently renders nothing).
            vertex.assemble(Context3DProgramType.VERTEX, AGALRenderer.lineVertexSource(vertexColors), AGAL_VERSION);

            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT,
                this._basicFragmentSource(false, vertexColors, toneMapped), AGAL_VERSION);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            // The line program's source is passed inline, so its stream usage is
            // spelled out: va0/va1 are the two segment endpoints, va2 the side,
            // and (M26) va3 the per-vertex colour.
            this._noteStreamsMask(program, vertexColors ? 15 : 7, 0);
            return program;
        }

        // Standard PBR program (M2 core + M4 texture map family). One program
        // for every material: all four map slots are sampled unconditionally,
        // with neutral 1x1 textures standing in for unbound maps (R8).
        //
        // The fragment is assembled as AGAL2 (version 2): the tangent-frame
        // normal mapping needs ddx/ddy (AGAL3 opcodes the 2015 assembler gates
        // behind OP_VERSION2), and the extra temporaries (ft4-ft11) exceed the
        // AGAL1 limit of eight.
        // M13 depth packing, written and read by the two shadow programs and the
        // PCF block. `src` holds the fragment's NDC depth in .x; the two-digit
        // value lands in `dst`.xy (hi = floor(d*255)/255, lo = frac(d*255)).
        // fc1 = (255, 1/255, 0, 0) is uploaded with the shadow pass.
        public static function packDepthSnippet(src:String, dst:String):String
        {
            return 'mul ' + dst + '.x, ' + src + '.xxxx, fc1.xxxx\n' +
                'frc ' + dst + '.y, ' + dst + '.x\n' +
                'sub ' + dst + '.x, ' + dst + '.x, ' + dst + '.y\n' +
                'mul ' + dst + '.x, ' + dst + '.x, fc1.yyyy\n';
        }

        // The inverse: dot(texel.xyz, fc25.xyz) with fc25 = (1, 1/255, 0), which
        // reconstructs hi + lo/255 in [0,1].
        public static const DEPTH_UNPACK_CONST:int = 25;

        // M13 PCF kernel. Emits one shadow light's 3x3 tap block and parks the
        // resulting factor (0 = fully shadowed, 1 = lit) in `c`.w:
        //
        //   shadowCoord /= w; z += bias
        //   inFrustum = u,v in [0,1] && z <= 1
        //   factor    = inFrustum ? (sum of "receiversDepth + bias <= storedDepth") / taps : 1
        //
        // The tap comparison is `sge stored, receiver` (three.js's
        // `step(receiver, stored)`), and the fetch is NEAREST: a PCF tap that
        // bilinearly interpolated two stored DEPTHS would fabricate a depth that
        // never existed and produce the classic "shadow bleeds across a depth
        // discontinuity" artifact.
        //
        // `bias` = fc9 (light 0) / fc25 (light 1): (bias, 0, 1, 0). `kernel` =
        // fc24 / fc26: (radius/mapW, radius/mapH, 1/taps, 0). Both are uploaded
        // per draw because radius and mapSize are per-light runtime values.
        public static function shadowFactorBlock(coord:String, bias:String, kernel:String,
                                                 recv:String, c:String, m:String, t:String,
                                                 o:String, a:String, slot:int):String
        {
            var s:String =
                'div ' + c + '.x, ' + coord + '.x, ' + coord + '.w\n' +
                'div ' + c + '.y, ' + coord + '.y, ' + coord + '.w\n' +
                'div ' + c + '.z, ' + coord + '.z, ' + coord + '.w\n' +
                'add ' + c + '.z, ' + c + '.z, ' + bias + '.xxxx\n' +
                // inFrustum: the sample would otherwise clamp to the border
                // texel and shadow everything outside the shadow camera's ortho
                // box (the M11 regression). three.js's getShadow keeps `shadow`
                // at 1.0 when the test fails.
                'sge ' + m + '.x, ' + c + '.x, ' + bias + '.yyyy\n' +
                'slt ' + m + '.y, ' + c + '.x, ' + bias + '.zzzz\n' +
                'mul ' + m + '.x, ' + m + '.x, ' + m + '.y\n' +
                'sge ' + m + '.y, ' + c + '.y, ' + bias + '.yyyy\n' +
                'slt ' + m + '.z, ' + c + '.y, ' + bias + '.zzzz\n' +
                'mul ' + m + '.y, ' + m + '.y, ' + m + '.z\n' +
                'mul ' + m + '.x, ' + m + '.x, ' + m + '.y\n' +
                'slt ' + m + '.y, ' + c + '.z, ' + bias + '.zzzz\n' +
                'mul ' + m + '.x, ' + m + '.x, ' + m + '.y\n' +
                'mov ' + a + '.x, ' + bias + '.yyyy\n';

            // `kernel` x tap-offset is two constant sources in one instruction. The
            // assembler hoists the first one into a free temporary -- once for the
            // whole loop -- so this stays a single extra `mov` (AGALMiniAssembler
            // .hoistConstantOperands; AIR rejects the raw form with #3625).
            var i:int;
            for (i = 0; i < AGALRenderer.PCF_TAPS; i++)
            {
                var off:String = 'fc' + (AGALRenderer.PCF_OFFSET_BASE + i);
                s +=
                    'mul ' + o + '.xy, ' + kernel + '.xy, ' + off + '.xy\n' +
                    'add ' + o + '.xy, ' + o + '.xy, ' + c + '.xy\n' +
                    'tex ' + t + ', ' + o + '.xy, fs' + slot + ' <2d,clamp,nearest,mipnone>\n' +
                    // unpack the stored 2-digit depth (see packDepthSnippet)
                    'dp3 ' + t + '.x, ' + t + ', fc' + DEPTH_UNPACK_CONST + '.xyz\n' +
                    'sge ' + t + '.x, ' + t + '.x, ' + c + '.z\n' +
                    'add ' + a + '.x, ' + a + '.x, ' + t + '.x\n';
            }

            return s +
                'mul ' + a + '.x, ' + a + '.x, ' + kernel + '.zzzz\n' +
                'sub ' + a + '.x, ' + a + '.x, ' + bias + '.zzzz\n' +
                // Outside the shadow camera's frustum the factor stays 1.
                'mul ' + a + '.x, ' + a + '.x, ' + m + '.xxxx\n' +
                'add ' + a + '.x, ' + a + '.x, ' + bias + '.zzzz\n' +
                'mov ' + c + '.w, ' + a + '.x\n' +
                // receiveShadow gate: a receiver with receiveShadow = false must
                // look unshadowed, so the factor is mixed toward 1
                // (light.shadowIntensity = 0 in three.js terms, per object).
                'sub ' + c + '.w, ' + c + '.w, ' + bias + '.zzzz\n' +
                'mul ' + c + '.w, ' + c + '.w, ' + recv + '.xxxx\n' +
                'add ' + c + '.w, ' + c + '.w, ' + bias + '.zzzz\n';
        }

        // M13 second directional light: the same direct diffuse + specular block
        // stage 5/6 runs for light 0, re-evaluated with fc22 (dir) / fc23
        // (color). It is never shadow-attenuated (the sampler budget buys one
        // shadow map, see MAX_SHADOW_LIGHTS). dotNV is shared with light 0
        // (ft3.y); everything that depends on the light direction (dotNL,
        // dotNH, dotVH, D, V) is recomputed.
        private function _secondLightBlock():String
        {
            var s:String =
                'add ft17.xyz, fc22.xyz, ft1.xyz\n' +   // L2 + V
                'nrm ft17.xyz, ft17.xyz\n' +            // H2
                'dp3 ft18.x, ft0.xyz, fc22.xyz\n' +
                'sat ft18.x, ft18.x\n' +                // dotNL2
                'dp3 ft18.z, ft0.xyz, ft17.xyz\n' +
                'sat ft18.z, ft18.z\n' +                // dotNH2
                'dp3 ft18.w, ft1.xyz, ft17.xyz\n' +
                'sat ft18.w, ft18.w\n' +                // dotVH2
                // D_GGX(alpha, dotNH2), alpha = roughness^2
                'mul ft19.x, ft5.x, ft5.x\n' +
                'mul ft19.y, ft19.x, ft19.x\n' +
                'mul ft19.z, ft18.z, ft18.z\n' +
                'sub ft19.w, ft19.y, fc6.wwww\n' +
                'mul ft19.z, ft19.z, ft19.w\n' +
                'add ft19.z, ft19.z, fc6.wwww\n' +
                'mul ft19.z, ft19.z, ft19.z\n' +
                'mul ft20.x, fc5.wwww, ft19.y\n' +
                'div ft20.x, ft20.x, ft19.z\n' +
                // V_GGX_SmithCorrelated(alpha, dotNL2, dotNV)
                'sub ft19.z, fc6.wwww, ft19.y\n' +
                'mul ft19.w, ft3.y, ft3.y\n' +
                'mul ft19.z, ft19.z, ft19.w\n' +
                'add ft19.z, ft19.z, ft19.y\n' +
                'sqt ft19.z, ft19.z\n' +
                'mul ft19.z, ft18.x, ft19.z\n' +         // gv
                'sub ft19.w, fc6.wwww, ft19.y\n' +
                'mul ft20.y, ft18.x, ft18.x\n' +
                'mul ft19.w, ft19.w, ft20.y\n' +
                'add ft19.w, ft19.w, ft19.y\n' +
                'sqt ft19.w, ft19.w\n' +
                'mul ft19.w, ft3.y, ft19.w\n' +          // gl
                'add ft19.z, ft19.z, ft19.w\n' +
                'max ft19.z, ft19.z, fc0.wwww\n' +
                'rcp ft19.z, ft19.z\n' +
                'mul ft19.z, ft19.z, fc1.wwww\n' +       // V2
                'mul ft20.x, ft20.x, ft19.z\n' +         // VD2
                // diffuse2 = diffCont/PI * (1 - F_Schlick(0.04, dotVH2)) * dotNL2 * color2
                'mul ft22.xyz, ft2.xyz, ft5.zzz\n' +     // diffuseContribution
                'mul ft22.xyz, ft22.xyz, fc5.wwww\n' +   // / PI
                'sub ft21.y, fc6.wwww, ft18.w\n' +
                'mul ft21.z, ft21.y, ft21.y\n' +
                'mul ft21.z, ft21.z, ft21.z\n' +
                'mul ft21.z, ft21.z, ft21.y\n' +         // fresnel
                'sub ft21.w, fc6.wwww, ft21.z\n' +
                'mul ft21.w, fc6.x, ft21.w\n' +
                'add ft21.w, ft21.w, ft21.z\n' +         // F_004
                'sub ft21.w, fc6.wwww, ft21.w\n' +       // 1 - F_004
                'mul ft21.w, ft21.w, ft18.x\n' +
                'mul ft22.xyz, ft22.xyz, ft21.wwww\n' +
                'mul ft22.xyz, ft22.xyz, fc23.xyz\n';
            s +=
                'add ft4.xyz, ft4.xyz, ft22.xyz\n' +
                // specular2 = F_blended * VD2 * dotNL2 * color2
                'sub ft21.y, fc6.wwww, ft18.w\n' +
                'mul ft21.z, ft21.y, ft21.y\n' +
                'mul ft21.z, ft21.z, ft21.z\n' +
                'mul ft21.z, ft21.z, ft21.y\n' +
                'sub ft23.w, fc6.wwww, ft21.z\n' +
                'mul ft23.xyz, ft6.xyz, ft23.wwww\n' +
                'add ft23.xyz, ft23.xyz, ft21.zzz\n' +
                'mul ft23.xyz, ft23.xyz, ft20.xxxx\n' +
                'mul ft23.xyz, ft23.xyz, ft18.xxxx\n' +
                'mul ft23.xyz, ft23.xyz, fc23.xyz\n' +
                // D173: the compensation is per-material, not per-light, so the
                // second directional light rides the same ft10.xyz the first one
                // used (three.js multiplies every RE_Direct call by it).
                'mul ft23.xyz, ft23.xyz, ft10.xyz\n';
            return s + 'add ft4.xyz, ft4.xyz, ft23.xyz\n';
        }

        // M19: the two instructions that rebuild a FACE normal from screen-space
        // derivatives of the world position. Emitted by both lighting programs
        // when material.flatShading is true, and public so the probe pins the
        // emitted AGAL (the ft4/ft5 operands must be the world-position
        // derivatives computed a few lines above it).
        public static function flatNormalBlock():String
        {
            return 'crs ft0.xyz, ft4.xyz, ft5.xyz\n' +
                   'nrm ft0.xyz, ft0.xyz\n';
        }

        private function _buildStandardProgram(dirs:int, shadows:int, decode:int, flat:Boolean,
                                               fog:Boolean, prefiltered:Boolean = false):Program3D
        {
            // Vertex: MVP-transform position (va0), world-transform position via
            // the model matrix (vc4..vc7) into v1, transform the normal (va1) by
            // the normal matrix rows (vc8..vc10) into v0, and copy uv (va2) into
            // v2. The normal matrix is 3x3, so dp3 (which ignores w) is used so
            // the model translation never leaks into the normal.
            //
            // M13: the world position and the normal land in vt0/vt1 first
            // because the shadow-space transform needs the NORMAL too -- each
            // shadow light offsets the receiver along its own normal by
            // `shadow.normalBias` before projecting (shadowmap_vertex.glsl.js:51).
            var vertexSrc:String =
                'dp4 op.x, va0, vc0\n' +
                'dp4 op.y, va0, vc1\n' +
                'dp4 op.z, va0, vc2\n' +
                'dp4 op.w, va0, vc3\n' +
                'dp4 vt0.x, va0, vc4\n' +
                'dp4 vt0.y, va0, vc5\n' +
                'dp4 vt0.z, va0, vc6\n' +
                'mov vt0.w, vc7.w\n' +
                'mov v1, vt0\n' +
                'dp3 vt1.x, va1, vc8\n' +
                'dp3 vt1.y, va1, vc9\n' +
                'dp3 vt1.z, va1, vc10\n' +
                'mov vt1.w, vc10.w\n' +
                'mov v0, vt1\n' +
                // M18: the six per-slot uv transforms. v2 = (map uv, normal uv),
                // v3 = copy of v2 (the ddy operand), v6 = (roughness, metalness),
                // v7 = (emissive, ao). Before M18 this was `mov v2.xy, va2.xy`
                // plus a hand-written v3 dup -- see uvTransformBlock().
                AGALRenderer.uvTransformBlock();

            // M13: one shadow-space coordinate per shadow light. vc12..vc15 =
            // bias*shadowVP of light 0, vc16..vc19 = light 1; vc20.x / vc21.x are
            // their normal biases. AGAL has no `mad`, so the offset is a mul+add
            // into a spare temporary.
            if (shadows >= 1)
            {
                vertexSrc +=
                    // The offset is applied to the FULL register: vt1.w is 0
                    // (vc10.w, the normal-matrix padding) and vt0.w is 1, so
                    // the sum keeps w = 1 for the dp4 below. Writing only
                    // .xyz leaves vt2.w unwritten, and a full-register read
                    // of a partially written temp is rejected by the
                    // translator ("vt2 is read before it is written", the
                    // same rule adl enforces with Error #3647).
                    'mul vt2, vt1, vc20.xxxx\n' +
                    'add vt2, vt2, vt0\n' +
                    'dp4 v4.x, vt2, vc12\n' +
                    'dp4 v4.y, vt2, vc13\n' +
                    'dp4 v4.z, vt2, vc14\n' +
                    'dp4 v4.w, vt2, vc15\n' +
                    // v5.x = receiveShadow (vc22.x, one register per draw): the
                    // fragment mixes the PCF factor toward unshadowed when it is
                    // 0. Flat and uninterpolated, so it must be written in full.
                    'mov v5, vc22.xxxx\n';
            }
            // Fragment: GGX metallic-roughness PBR. See the class comment for the
            // register allocation; the fc layout is pinned to _fillStandardConstants.
            var fragSrc:String = '';

            // --- Stage 1: geometric normal. ---
            //
            // M19: with `flatShading` the interpolated normal is discarded and
            // the face normal is rebuilt from screen-space derivatives of the
            // world position (three.js normal_fragment_begin.glsl.js FLAT_SHADED:
            // `normalize(cross(dFdx(vViewPosition), dFdy(vViewPosition)))`). The
            // derivatives are already computed a few lines below for the tangent
            // frame, so the block reuses them and costs 2 instructions.
            // r187 lights_physical_fragment.glsl.js:9-15 also folds the SCREEN
            // derivative of the (non-perturbed) normal into the roughness:
            //
            //   dxy = max(|dFdx(nonPerturbedNormal)|, |dFdy(nonPerturbedNormal)|)
            //   geometryRoughness = max(max(dxy.x, dxy.y), dxy.z)
            //   roughness = min(roughnessFactor + geometryRoughness, 1)
            //
            // This is not a detail: it is what keeps a sub-pixel-wide GGX peak
            // from aliasing into a blown-out patch. D_GGX is ~200x at roughness
            // 0.2 and a 1% shift in dotNH costs a factor of ~180, so without the
            // term a curved surface lights up in whole polygons (M26-R1b).
            // three.js lights in view space and we light in world space; the
            // magnitude of dFdx of a unit vector is rotation-invariant, so the
            // world-space derivative is the same number.
            //
            // FLAT_SHADED (M19) has a constant face normal, so the derivative --
            // and therefore the term -- is exactly  0; the register is zeroed
            // rather than left unwritten (a full-register read of a partially
            // written temp is rejected by the translator).
            if (!flat)
            {
                fragSrc += 'nrm ft0.xyz, v0.xyz\n' +   // ft0 = N
                           AGALRenderer.geometryRoughnessBlock();
            }
            else
            {
                // FLAT_SHADED (M19): the face normal is constant across the
                // triangle, so dFdx/dFdy of it are 0 and so is the term. Zero the
                // register rather than leave it unwritten (a full-register read of
                // a partially written temp is rejected by the translator).
                fragSrc += 'sub ft12.x, fc6.wwww, fc6.wwww\n';   // 1 - 1 = 0
            }

            // --- Stage 1.5 (M4): tangent-frame normal mapping (R8). ---
            //
            // three.js getTangentFrame (normalmap_pars_fragment.glsl.js:20-40),
            // computed in WORLD space (our lighting is world-space; three.js
            // computes it in view space because WebGLRenderer lights in view
            // space). q0/q1 = screen-space derivatives of the world position,
            // st0/st1 = derivatives of the uv.
            //
            //   q1perp = cross(q1, N); q0perp = cross(N, q0)
            //   T = q1perp*st0.x + q0perp*st1.x
            //   B = q1perp*st0.y + q0perp*st1.y
            //   scale = inversesqrt(max(dot(T,T), dot(B,B)))
            //   mapN = normalTexel*2-1; mapN.xy *= normalScale
            //   N = normalize(T*mapN.x + B*mapN.y + N*mapN.z)
            //
            // This stage MUST run before the dot products below: the lighting
            // consumes the PERTURBED normal (three.js perturbs in
            // normal_fragment_maps, before lights compute dotNL etc).
            //
            // The neutral normal texture is (0.5,0.5,1), so mapN = (0,0,1) and
            // the whole stage collapses to N unchanged -- no per-material
            // program variant is needed. The rcp is epsilon-guarded (fc0.w),
            // so degenerate derivatives cannot produce a NaN normal.
            fragSrc +=
                'ddx ft4.xyz, v1.xyz\n' +
                'ddy ft5.xyz, v1.xyz\n' +
                // AGAL partial swizzles read the source component at the SAME
                // index the write-mask selects, so `.zwzw` picks v.z/v.w -- the
                // normal-map uv half of the packed v2/v3 (M18, uvVaryingOf).
                // three.js's getTangentFrame takes the NORMAL map's uv
                // (normalmap_pars_fragment.glsl.js vNormalMapUv), not the base
                // map's, which is why the derivative pair lives in .zw.
                'ddx ft6.xy, v2.zwzw\n' +
                'ddy ft6.zw, v3.zwzw\n' +
                // M19 flat shading: the face normal. cross(dFdx(worldPos),
                // dFdy(worldPos)) -- the sign convention matches three.js's
                // vViewPosition-based form because both operands flip sign
                // together.
                (flat ? AGALRenderer.flatNormalBlock() : '') +
                'crs ft7.xyz, ft5.xyz, ft0.xyz\n' +  // q1perp
                'crs ft8.xyz, ft0.xyz, ft4.xyz\n' +  // q0perp
                'mul ft9.xyz, ft7.xyz, ft6.xxxx\n' +
                'mul ft10.xyz, ft8.xyz, ft6.zzzz\n' +
                'add ft9.xyz, ft9.xyz, ft10.xyz\n' + // T
                'mul ft10.xyz, ft7.xyz, ft6.yyyy\n' +
                'mul ft11.xyz, ft8.xyz, ft6.wwww\n' +
                'add ft10.xyz, ft10.xyz, ft11.xyz\n' + // B
                'dp3 ft11.x, ft9.xyz, ft9.xyz\n' +
                'dp3 ft11.y, ft10.xyz, ft10.xyz\n' +
                'max ft11.x, ft11.x, ft11.y\n' +
                'max ft11.x, ft11.x, fc0.wwww\n' +
                'sqt ft11.x, ft11.x\n' +
                'rcp ft11.x, ft11.x\n' +           // scale = inversesqrt(det)
                'mul ft9.xyz, ft9.xyz, ft11.xxxx\n' +
                'mul ft10.xyz, ft10.xyz, ft11.xxxx\n' +
                'tex ft11, v2.zw, fs1 <2d,clamp,linear,mipnone>\n' +
                'mul ft11.xyz, ft11.xyz, fc8.zzzz\n' + // texel*2
                'sub ft11.xyz, ft11.xyz, fc6.wwww\n' + // -1 => mapN
                'mul ft11.xy, ft11.xy, fc8.xy\n' +    // * normalScale
                'mul ft4.xyz, ft9.xyz, ft11.xxxx\n' +
                'mul ft5.xyz, ft10.xyz, ft11.yyyy\n' +
                'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
                'mul ft5.xyz, ft0.xyz, ft11.zzzz\n' +
                'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
                'nrm ft0.xyz, ft4.xyz\n';           // ft0 = perturbed N

            // --- Stage 2: V/H and the four dot products (from the perturbed N). ---
            fragSrc +=
                'sub ft1.xyz, fc0.xyz, v1.xyz\n' + // cameraPos - worldPos
                'nrm ft1.xyz, ft1.xyz\n' +      // ft1 = V
                'add ft2.xyz, fc1.xyz, ft1.xyz\n' + // L + V
                'nrm ft2.xyz, ft2.xyz\n' +      // ft2 = H
                'dp3 ft3.x, ft0.xyz, fc1.xyz\n' + // dotNL
                'sat ft3.x, ft3.x\n' +
                'dp3 ft3.y, ft0.xyz, ft1.xyz\n' + // dotNV
                'sat ft3.y, ft3.y\n' +
                'dp3 ft3.z, ft0.xyz, ft2.xyz\n' + // dotNH
                'sat ft3.z, ft3.z\n' +
                'dp3 ft3.w, ft1.xyz, ft2.xyz\n' + // dotVH
                'sat ft3.w, ft3.w\n';

            // --- Stage 2: base color + roughness/metalness factors (M4). ---
            //
            // diffuseColor = baseColor * sampledDiffuseColor (map_fragment
            // .glsl.js:14). The neutral white texture keeps the product
            // identical to baseColor when no map is bound. roughnessFactor *=
            // texel.g (roughnessmap_fragment.glsl.js:9) and metalnessFactor *=
            // texel.b (metalnessmap_fragment.glsl.js:9) -- white neutral texels
            // leave them unchanged.
            //
            // M18: each fetch reads ITS OWN slot's transformed uv (uvVaryingOf),
            // because three.js gives every map its own transform. fs0 -> v2.xy
            // (map), fs2 -> v6.xy (roughness), fs3 -> v6.zw (metalness).
            fragSrc +=
                'tex ft2, v2.xy, fs0 <2d,clamp,linear,mipnone>\n' +
                // M17: sRGB -> linear decode of the base-color texel when the
                // texture declares SRGBColorSpace (map_fragment's texel is an
                // encoded color; three.js gets the decode from the GPU's sRGB
                // internal format). D170: the sRGB EOTF (fc41/fc42); ft9 is
                // dead between the tangent-frame stage and stage 4 (D).
                AGALRenderer.srgbDecodeBlock('ft2', decode, AGALRenderer.DECODE_MAP, 'ft9') +
                'mul ft2.xyz, ft2.xyz, fc4.xyz\n' +
                'tex ft4, v6.xy, fs2 <2d,clamp,linear,mipnone>\n' +
                // D171: a color texture reused as a data map is still decoded by
                // the GPU's sRGB sampler in three.js. ft6 is dead here (stage 3
                // writes it before any read), so it is the scratch.
                AGALRenderer.srgbDecodeScalarBlock('ft4', 'y', decode,
                    AGALRenderer.DECODE_ROUGHNESS, 'ft6') +
                'mul ft5.x, fc5.x, ft4.y\n' +   // roughnessFactor
                // + geometryRoughness, clamped to 1 (r187). fc5.x is already
                // max(material.roughness, 0.045) from the CPU side, which is the
                // same thing as r187's max(0.045) as long as the roughness map's
                // .g stays at 1 -- recorded in three-api-design.md §32.
                'add ft5.x, ft5.x, ft12.xxxx\n' +
                'min ft5.x, ft5.x, fc6.wwww\n' +
                'tex ft4, v6.zw, fs3 <2d,clamp,linear,mipnone>\n' +
                AGALRenderer.srgbDecodeScalarBlock('ft4', 'z', decode,
                    AGALRenderer.DECODE_METALNESS, 'ft6') +
                'mul ft5.y, fc5.y, ft4.z\n' +   // metalnessFactor
                'sub ft5.z, fc6.w, ft5.y\n' +   // 1 - metalnessFactor
                'mov ft5.w, fc5.w\n';           // 1/PI

            // --- Stage 3: material params. ft4 = specularColorBlended, ft5(xyz overwritten below after use). ---
            fragSrc +=
                'mul ft6.xyz, fc6.xyz, ft5.zzz\n' + // F0 * (1-metalness)
                'mul ft7.xyz, ft2.xyz, ft5.yyy\n' + // baseColor * metalness
                'add ft6.xyz, ft6.xyz, ft7.xyz\n';  // ft6 = specularColorBlended

            // diffuseContribution = baseColor * (1 - metalness), computed in
            // ft4 (ft2 is still live as the sampled base color... it is not:
            // ft2's last read is above; from here on ft2 is dead).
            fragSrc +=
                'mul ft4.xyz, ft2.xyz, ft5.zzz\n';  // ft4 = diffuseContribution

            // --- Stage 4: GGX scalar terms -> VD = V*D parked in ft4.w. ---
            //
            // roughnessFactor drives the GGX alpha (M4: fc5.x is now the
            // sampled roughness, stored back in ft5.x).
            fragSrc +=
                'mul ft7.x, ft5.x, ft5.x\n' +    // alpha = roughness^2
                'mul ft7.y, ft7.x, ft7.x\n' +    // a2 = roughness^4
                // D_GGX(alpha, dotNH): a2 / (PI * (dotNH^2*(a2-1)+1)^2)
                'mul ft7.z, ft3.z, ft3.z\n' +
                'sub ft7.w, ft7.y, fc6.w\n' +
                'mul ft7.z, ft7.z, ft7.w\n' +
                'add ft7.z, ft7.z, fc6.w\n' +
                'mul ft7.z, ft7.z, ft7.z\n' +
                'mul ft8.x, fc5.w, ft7.y\n' +
                'div ft8.x, ft8.x, ft7.z\n' +    // ft8.x = D
                // V_GGX_SmithCorrelated(alpha, dotNL, dotNV): 0.5/max(gv+gl, eps)
                'sub ft7.z, fc6.w, ft7.y\n' +
                'mul ft7.w, ft3.y, ft3.y\n' +
                'mul ft7.z, ft7.z, ft7.w\n' +
                'add ft7.z, ft7.z, ft7.y\n' +
                'sqt ft7.z, ft7.z\n' +
                'mul ft7.z, ft3.x, ft7.z\n' +    // gv
                'sub ft7.w, fc6.w, ft7.y\n' +
                'mul ft7.x, ft3.x, ft3.x\n' +
                'mul ft7.w, ft7.w, ft7.x\n' +
                'add ft7.w, ft7.w, ft7.y\n' +
                'sqt ft7.w, ft7.w\n' +
                'mul ft7.w, ft3.y, ft7.w\n' +    // gl
                'add ft7.z, ft7.z, ft7.w\n' +
                'max ft7.z, ft7.z, fc0.wwww\n' +
                'rcp ft7.z, ft7.z\n' +
                'mul ft7.z, ft7.z, fc1.wwww\n' + // ft7.z = V
                'mul ft4.w, ft7.z, ft8.x\n';     // ft4.w = VD = V*D

            // --- Stage 5: diffuse (indirect + direct), accumulated into ft4. ---
            // M7/M13 shadow: one PCF block per shadow light, each parking its
            // factor in the .w of its coordinate register (ft9.w = light 0,
            // ft14.w = light 1). The blocks are emitted only for the
            // shadow-casting variants, so a shadow-less scene's direct term stays
            // unattenuated at zero instruction cost.
            if (shadows >= 1)
            {
                fragSrc += AGALRenderer.shadowFactorBlock('v4', 'fc9', 'fc24', 'v5',
                                                          'ft9', 'ft10', 'ft13', 'ft11', 'ft12', 4);
            }
            fragSrc +=
                'mul ft7.xyz, ft4.xyz, fc5.wwww\n' + // diffCont/PI
                // M9: image-based diffuse irradiance, sampled at the shading
                // normal (getIBLIrradiance, envmap_physical_pars_fragment.glsl.js:12).
                // three.js reads `textureLod(envMap, worldNormal, ENVMAP_MAX_LOD)`
                // -- the ROUGHEST level of the pre-filtered chain.
                //
                // M25-R1 changed what is in the slot, not the fetch: with a ladder
                // bound, fs7 holds the level for this material's roughness, so this
                // sample reads the sky already blurred toward that roughness
                // instead of the sharp cube (D174/D175). The one fetch has to serve
                // both roles because AGAL has exactly eight fragment samplers and
                // the standard program uses all eight (see the resolution comment in
                // _renderStandard). Without a ladder nothing changes at all.
                // ft11 is dead here (the normal-map texel it held in stage 1.5 was
                // consumed into ft0).
                'tex ft11, ft0.xyz, fs7 <cube,clamp,linear,mipnone>\n' +
                // M17: the environment cube is a color source (a sky/IBL photo),
                // so SRGBColorSpace decodes it like the base-color map.
                AGALRenderer.srgbDecodeBlock('ft11', decode, AGALRenderer.DECODE_ENV, 'ft8') +
                'mul ft11.xyz, ft11.xyz, fc10.xxxx\n' +
                // ft13 = envColor * envMapIntensity. three.js's
                // cosineWeightedIrradiance is exactly this (iblIrradiance / PI, and
                // iblIrradiance already carries the PI), and D173's
                // multiple-scattering term in stage 6.5 consumes it, so it is
                // parked before the PI below rather than recomputed there.
                //
                // (Until M25-R1 stage 6.5 read ft11 at that point, which by then
                // held the AO TEXEL from the block below -- harmless only because
                // the neutral 1x1 default is white in all three channels. An
                // aoMap made the multiple-scattering lobe red-tinted.)
                'mov ft13.xyz, ft11.xyz\n' +
                // getIBLIrradiance returns PI * envColor * envMapIntensity
                // (envmap_physical_pars_fragment.glsl.js:12); RE_IndirectDiffuse
                // then multiplies by RECIPROCAL_PI, so the PI has to be here or
                // the environment contributes 1/PI too little relative to the
                // AmbientLight term added below.
                'mul ft11.xyz, ft11.xyz, fc13.yyyy\n' + // * PI
                'mul ft4.xyz, ft11.xyz, ft7.xyz\n' +    // env irradiance * diffCont/PI
                // M27: a LightProbe reaches this same fetch (its baked irradiance
                // cube is what fs7 holds when the scene has no environment), so no
                // SH evaluation appears here -- see _resolveLightProbes.
                'mul ft12.xyz, fc3.xyz, ft7.xyz\n' +    // ambient * diffCont/PI
                'add ft4.xyz, ft4.xyz, ft12.xyz\n' +
                // AO (M8 follow-up). ft11 is dead here (the normal-map texel it
                // held in stage 1.5 was consumed into ft0). glTF packs occlusion
                // in .r; the neutral white texel gives ao=1, i.e. no change.
                // AO attenuates the whole indirect diffuse term, which now holds
                // the environment irradiance as well as the ambient light -- the
                // same scope three.js gives ambientOcclusion (lightmap/irradiance
                // are multiplied together in lights_fragment_end).
                'tex ft11, v7.zw, fs6 <2d,clamp,linear,mipnone>\n' +
                'sub ft11.x, ft11.x, fc6.wwww\n' +   // ao - 1
                'mul ft11.x, ft11.x, fc8.wwww\n' +   // * aoMapIntensity
                'add ft11.x, ft11.x, fc6.wwww\n' +   // ao' = mix(1, ao, intensity)
                'mul ft4.xyz, ft4.xyz, ft11.xxxx\n' +// ambient *= ao'
                // 1 - F_Schlick(0.04, 1.0, dotVH). fresnel parks in ft8.z and the
                // scalar F_004/1-F_004 chain rides ft8.w so no partial write-mask
                // ever overwrites a still-needed source channel.
                'sub ft8.y, fc6.w, ft3.w\n' +
                'mul ft8.z, ft8.y, ft8.y\n' +
                'mul ft8.z, ft8.z, ft8.z\n' +
                'mul ft8.z, ft8.z, ft8.y\n' +        // fresnel -> ft8.z
                'sub ft8.w, fc6.w, ft8.z\n' +        // 1-fres -> ft8.w
                'mul ft8.w, fc6.x, ft8.w\n' +        // 0.04*(1-fres)
                'add ft8.w, ft8.w, ft8.z\n' +        // F_004
                'sub ft8.w, fc6.w, ft8.w\n' +        // 1-F_004
                'mul ft8.w, ft8.w, ft3.x\n' +        // (1-F_004)*dotNL
                'mul ft8.xyz, ft8.wwww, fc2.xyz\n' + // * lightColor
                'mul ft8.xyz, ft8.xyz, ft7.xyz\n';   // * diffCont/PI = directDiffuse
            if (shadows >= 1)
            {
                fragSrc += 'mul ft8.xyz, ft8.xyz, ft9.wwww\n'; // * shadowFactor
            }
            fragSrc += 'add ft4.xyz, ft4.xyz, ft8.xyz\n';   // ft4 += directDiffuse

            // --- Stage 5.5 (D173): the DFG pair for the direct-light energy
            // compensation. three.js evaluates material.dfg once at the top of
            // lights_fragment_begin (before any RE_Direct), so the same AB feeds
            // both the direct compensation below and the indirect split-sum in
            // stage 6.5; computing it once here is both cheaper and the correct
            // order.
            fragSrc +=
                AGALRenderer.envBRDFApproxBlock('ft9', 'ft8') +
                AGALRenderer.multiScatterCompBlock('ft10', 'ft9', 'ft8');

            // --- Stage 6: specular (direct only), accumulated into ft4. ---
            fragSrc +=
                // F_blended = F_Schlick(specularColorBlended, 1.0, dotVH)
                'sub ft7.w, fc6.w, ft3.w\n' +
                'mul ft8.y, ft7.w, ft7.w\n' +
                'mul ft8.y, ft8.y, ft8.y\n' +
                'mul ft8.y, ft8.y, ft7.w\n' +        // fresnel
                'sub ft8.z, fc6.w, ft8.y\n' +
                'mul ft7.xyz, ft6.xyz, ft8.zzz\n' +  // specColorBlended*(1-fres)
                'add ft7.xyz, ft7.xyz, ft8.yyy\n' +  // F_blended
                'mul ft7.xyz, ft7.xyz, ft4.wwww\n' + // * VD = specularBRDF
                'mul ft7.xyz, ft7.xyz, ft3.xxxx\n' + // * dotNL
                'mul ft7.xyz, ft7.xyz, fc2.xyz\n' + // * lightColor
                'mul ft7.xyz, ft7.xyz, ft10.xyz\n'; // * multiScatteringCompensation (D173)
            if (shadows >= 1)
            {
                fragSrc += 'mul ft7.xyz, ft7.xyz, ft9.wwww\n'; // * shadowFactor
            }
            fragSrc += 'add ft4.xyz, ft4.xyz, ft7.xyz\n';   // ft4 += directSpecular

            // --- Stage 6.2 (M13): the second directional light. ---
            if (dirs >= 2)
            {
                fragSrc += this._secondLightBlock();
            }

            // --- Stage 6.5 (M9): image-based specular (envMap). ---
            //
            // three.js getIBLRadiance (envmap_physical_pars_fragment.glsl.js:116):
            //   R = normalize( mix( reflect(-V, N), N, roughness^2 ) )
            //   radiance = textureCubeUV(envMap, R, roughness) * envMapIntensity
            // textureCubeUV reads a PMREM mip chain; this backend has no float
            // render targets to build one, so the roughness cue is the mix toward
            // N only (D48). The energy split uses Karis's EnvBRDFApprox instead of
            // sampling three.js's BRDF_LUT (same reasoning, one less sampler).
            //
            // Registers at entry: ft0 = N, ft1 = V, ft3.y = dotNV, ft4 = color,
            // ft5.x = roughness, ft6 = specularColorBlended, ft9.y/.z = AB (from
            // stage 5.5), ft10.xyz = multiScatteringCompensation (dead from here
            // on); ft7/ft8/ft11/ft12 are free.
            fragSrc +=
                // R = 2*dotNV*N - V   (reflect(-V, N))
                'mul ft7.xyz, ft0.xyz, ft3.yyyy\n' +
                'add ft7.xyz, ft7.xyz, ft7.xyz\n' +
                'sub ft7.xyz, ft7.xyz, ft1.xyz\n' +
                'nrm ft7.xyz, ft7.xyz\n' +
                // R = normalize(mix(R, N, pow4(roughness))). r187 uses pow4, not
                // the roughness^2 of older releases
                // (envmap_physical_pars_fragment.glsl.js:29, common.glsl.js:18).
                'mul ft8.x, ft5.x, ft5.x\n' +   // r2
                'mul ft8.x, ft8.x, ft8.x\n' +   // r4 = pow4(roughness)
                'mov ft9.w, ft8.x\n' +          // keep r4 (ft8.x is reused below)
                'sub ft8.y, fc6.w, ft8.x\n' +
                'mul ft7.xyz, ft7.xyz, ft8.yyyy\n' +
                'mul ft8.xyz, ft0.xyz, ft8.xxxx\n' +
                'add ft7.xyz, ft7.xyz, ft8.xyz\n' +
                'nrm ft7.xyz, ft7.xyz\n' +
                // radiance = cubeSample(R) * envMapIntensity
                (AGALRenderer.debugReflect ? 'abs ft7.xyz, ft7.xyz\n'
                    : 'tex ft7, ft7.xyz, fs7 <cube,clamp,linear,mipnone>\n') +
                AGALRenderer.srgbDecodeBlock('ft7', decode, AGALRenderer.DECODE_ENV, 'ft8') +
                'mul ft7.xyz, ft7.xyz, fc10.xxxx\n' +
                // Pre-filter stand-in (M9), emitted only when the draw has NO
                // pre-filtered ladder. three.js reads a PRE-CONVOLVED level of the
                // PMREM chain; a plain CubeTexture has none, so a max-roughness
                // sample is approximated by the same cube sampled at N and the two
                // are mixed by roughness^4. Roughness 1 then resolves to a flat
                // cosine-like tint instead of a mirror image, which is what a r=1
                // PMREM level looks like; the intermediate levels are only roughly
                // reproduced (D48).
                //
                // M25-R1/D174: with the ladder this whole block disappears -- fs7
                // IS the pre-convolved level, and the mix would additionally pull
                // the reflection toward the normal, which a real prefiltered chain
                // does not do.
                (prefiltered ? '' :
                'tex ft11, ft0.xyz, fs7 <cube,clamp,linear,mipnone>\n' +
                AGALRenderer.srgbDecodeBlock('ft11', decode, AGALRenderer.DECODE_ENV, 'ft8') +
                'mul ft11.xyz, ft11.xyz, fc10.xxxx\n' +
                'sub ft8.x, fc6.w, ft9.w\n' +
                'mul ft8.xyz, ft7.xyz, ft8.xxxx\n' +
                'mul ft7.xyz, ft11.xyz, ft9.wwww\n' +
                'add ft7.xyz, ft8.xyz, ft7.xyz\n') +  // ft7 = prefiltered radiance
                // (AB is not recomputed here: stage 5.5 already produced the same
                // pair from the same roughness/dotNV, and three.js evaluates
                // material.dfg exactly once per fragment too.)
                //
                // --- D173: three.js's INDIRECT split-sum, both halves.
                //
                // getIBLRadiance is only the radiance; the BRDF factor comes from
                // computeMultiscattering (lights_physical_pars_fragment.glsl.js
                // :463) which returns TWO terms:
                //
                //   FssEss  = Fr*AB.x + F90*AB.y           (single scatter)
                //   Ess     = AB.x + AB.y, Ems = 1 - Ess
                //   Favg    = Fr + (1-Fr)/21
                //   Fms     = FssEss*Favg / (1 - Ems*Favg)
                //   indirectSpecular = radiance*FssEss + Fms*Ems*irradiance/PI
                //
                // The old code stopped at FssEss, so every rough surface lost the
                // multiple-scattering lobe (for a white metal at roughness 0.2 the
                // furnace albedo is 0.89, i.e. 11% of the energy was simply gone;
                // at roughness 1 it is over half). ft11 holds irradiance/PI --
                // the N-sample is already envColor*envMapIntensity, which is what
                // getIBLIrradiance multiplied by RECIPROCAL_PI comes to.
                'mul ft10.xyz, ft6.xyz, ft9.yyyy\n' +
                'add ft10.xyz, ft10.xyz, ft9.zzzz\n' +  // ft10 = FssEss
                'mul ft12.xyz, ft10.xyz, ft7.xyz\n' +
                'add ft4.xyz, ft4.xyz, ft12.xyz\n' +    // single scattering
                'add ft9.x, ft9.y, ft9.z\n' +           // Ess
                'sub ft9.x, fc6.w, ft9.x\n' +           // Ems
                'sub ft8.xyz, fc6.www, ft6.xyz\n' +     // 1 - Fr
                'mul ft8.xyz, ft8.xyz, fc10.yyyy\n' +   // /21
                'add ft8.xyz, ft8.xyz, ft6.xyz\n' +     // Favg
                'mul ft7.xyz, ft8.xyz, ft9.xxxx\n' +    // Favg*Ems
                'sub ft7.xyz, fc6.www, ft7.xyz\n' +     // 1 - Ems*Favg
                'mul ft12.xyz, ft10.xyz, ft8.xyz\n' +   // FssEss*Favg
                'div ft12.xyz, ft12.xyz, ft7.xyz\n' +   // Fms
                'mul ft12.xyz, ft12.xyz, ft9.xxxx\n' +  // * Ems
                'mul ft12.xyz, ft12.xyz, ft13.xyz\n' +  // * cosineWeightedIrradiance
                'add ft4.xyz, ft4.xyz, ft12.xyz\n';     // multiple scattering


            // --- Stage 7: add emissive, tone map, encode to sRGB, output. ---
            // Emissive (M8 follow-up): three.js computes
            // emissive = emissive * emissiveIntensity * emissiveTexel
            // (emissivemap_fragment.glsl.js:6), then adds it after lighting.
            // fc7.xyz already holds emissive*emissiveIntensity and the neutral
            // white texel leaves a texture-less material's term unchanged.
            //
            // M10: the diffuse alpha is baseColorTexel.a * opacity
            // (map_fragment.glsl.js:14 multiplies diffuseColor, alpha included,
            // by the texel; Material.opacity is fc4.w), so a cutout texture can
            // drive alphaTest. ft2 has been dead since stage 3, so its alpha
            // channel still holds the sampled base-color texel.
            fragSrc +=
                'tex ft11, v7.xy, fs5 <2d,clamp,linear,mipnone>\n' +
                // M17: emissiveMap is a color map (emissivemap_fragment.glsl.js:6).
                AGALRenderer.srgbDecodeBlock('ft11', decode, AGALRenderer.DECODE_EMISSIVE, 'ft10') +
                'mul ft11.xyz, ft11.xyz, fc7.xyz\n' +
                'add ft4.xyz, ft4.xyz, ft11.xyz\n' +
                // M20: fog runs on the LINEAR lit color, before tone mapping
                // (fog_fragment.glsl.js precedes tonemapping_fragment).
                (fog ? this._fogBlock('ft4', 'ft12', 'ft13') : '') +
                this._toneMapBlock('ft4', 'ft8', 'ft9', 'ft10') +
                // R7/D170: linear -> sRGB output encoding (three.js r187 default
                // outputColorSpace = SRGBColorSpace), the exact curve from
                // fc41/fc42 rather than pow(x, 1/2.2). In place, so it needs no
                // scratch: ft8 is still free for the alpha test below.
                'sat ft4.xyz, ft4.xyz\n' +
                AGALRenderer.srgbEncodeBlock('ft4') +
                // M10 alpha test + opacity output.
                'mul ft8, ft2.wwww, fc4.wwww\n' +
                // oc has to be written in ONE instruction with all four
                // components (AIR #3701), so the alpha is parked in ft4.w
                // before ft8 is consumed by the alpha test.
                'mov ft4.w, ft8.xxxx\n' +
                'sub ft8, ft8, fc15.zzzz\n' +
                'kil ft8.xxxx\n' +
                'mov oc, ft4\n';

            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            vertex.assemble(Context3DProgramType.VERTEX, vertexSrc, AGAL_VERSION);

            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT, fragSrc, AGAL_VERSION);

            // Build-time validation (M13). The Stage3D draw path throws an
            // Error whose message the compiler's AGAL bridge leaves NULL
            // ("Uncaught exception: null", no location, invalid program), which
            // is unreportable. Running the same translator here surfaces the
            // real diagnostic while the variant is still identifiable, so a
            // rejected program names itself instead of failing at draw time.
            this._validateAgsl("vertex", vertex, dirs, shadows, flat);
            this._validateAgsl("fragment", fragment, dirs, shadows, flat);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            this._noteStreams(program, vertexSrc, fragSrc);
            if (AGALRenderer.dumpFragSource)
            {
                // The MSL mirror only exists under as-aot: flash.display3D.
                // AGALTranslator is not in AIR's airglobal.swc, so touching it
                // throws #1065. This is a diagnostic switch, so a dump request
                // must degrade (the AGAL text below is always available) rather
                // than take the whole frame down on AIR.
                trace("==== AGAL-FRAGMENT-BEGIN ====");
                trace(fragSrc);
                trace("==== AGAL-FRAGMENT-END ====");
                try
                {
                    trace("==== MSL-FRAGMENT-BEGIN ====");
                    trace(AGALTranslator.translate(fragment.agalcode, "msl"));
                    trace("==== MSL-FRAGMENT-END ====");
                }
                catch (e:Error)
                {
                    trace("==== MSL-FRAGMENT-UNAVAILABLE (" + e.message + ") ====");
                }
            }
            // Instruction budget report (one line per program build, i.e. once
            // per renderer construction). The as-aot AGAL translator rejects a
            // program over 200 instructions, and there is no runtime getter for
            // the count, so this trace is the only observable handle -- probes
            // and demos pin the number from their output.
            var nInstr:int = (fragment.agalcode.length - 7) / 24;
            trace("AGALRenderer: standard fragment " + nInstr + "/400 instructions (dirs=" + dirs + ", shadows=" + shadows + ", tone=" + this._toneMapping + ", flat=" + (flat ? 1 : 0) + ", fog=" + (fog ? 1 : 0) + ", prefiltered=" + (prefiltered ? 1 : 0) + ")");
            return program;
        }

        // M13: translate-only validation of one assembled program. Throws an
        // Error that names the stage and the variant when the AGAL is rejected
        // (the most common cause is a temporary read before it is written --
        // see the vt2 note in the vertex source above).
        // null under AIR, the class under as-aot. Cached: a probing miss is an
        // exception, and this is asked once per program build.
        private static var _translatorResolved:Boolean = false;
        private static var _translator:Object = null;

        private static function translatorClass():Object
        {
            if (!AGALRenderer._translatorResolved)
            {
                AGALRenderer._translatorResolved = true;
                try
                {
                    AGALRenderer._translator = getDefinitionByName("flash.display3D.AGALTranslator");
                }
                catch (e:Error)
                {
                    AGALRenderer._translator = null;
                }
            }
            return AGALRenderer._translator;
        }

        private function _validateAgsl(stage:String, assembler:AGALMiniAssembler, dirs:int, shadows:int, flat:Boolean):void
        {
            var translator:Object = AGALRenderer.translatorClass();
            if (translator == null)
            {
                // Real AIR: no translator to consult, and none is needed -- Context3D
                // rejects a bad program at upload with its own #36xx. Missing
                // capability, stated rather than silently skipped (three-borrow-map.md).
                return;
            }

            try
            {
                translator.translate(assembler.agalcode, "msl");
            }
            catch (e:Error)
            {
                throw new Error("AGALRenderer: " + stage + " program rejected (dirs=" + dirs +
                                ", shadows=" + shadows + ", flat=" + (flat ? 1 : 0) + "): " + e.message);
            }
        }


        // Depth-only shadow program (M7). Vertex transforms to the shadow
        // camera's clip space (vc0..vc3 = shadow view-projection rows) and
        // passes the whole clip position through v0; fragment performs the
        // perspective divide and stores the [0,1] NDC z directly into the color
        // output (the depth attachment is render-target-only, so the depth is
        // stored as color and compared manually in the standard pass). The
        // shadow camera is orthographic (w=1), so the varying depth is linear.
        private function _buildShadowProgram():Program3D
        {
            var vertexSrc:String =
                // Clip position through vt0: reading `op` back as a source is illegal
                // (AIR #3646 "Can not read from output register").
                'dp4 vt0.x, va0, vc0\n' +
                'dp4 vt0.y, va0, vc1\n' +
                'dp4 vt0.z, va0, vc2\n' +
                'dp4 vt0.w, va0, vc3\n' +
                'mov op, vt0\n' +
                'mov v0, vt0\n';

            // fc0 = (0, 0, 0, 1): only fc0.w (output alpha) is used. fc1 =
            // (255, 1/255, 0, 0) drives the depth packing below.
            //
            // M13 depth packing: the shadow map is an 8-bit-per-channel colour
            // target, so a RAW [0,1] depth in one channel resolves 1/255 of the
            // light frustum -- for a 0.5..40 ortho camera that is 0.155 world
            // units per step, which is larger than the whole bias budget and is
            // what makes a low-poly curved surface self-shadow in stripes. The
            // depth is therefore stored as TWO base-255 digits (hi, lo) and
            // unpacked with a dp3 (shadowFactorBlock), giving 65025 steps =
            // 0.0006 units per step. three.js does the same thing for the same
            // reason (packDepthToRGBA in its depth material); two bytes are
            // enough here and cost three instructions fewer than four.
            //
            // `div ft0, v0.z, v0.w` is component-wise (v0.z -> .zzzz, v0.w ->
            // .wwww under AGAL partial-swizzle last-component replication), so
            // all four channels land at clip.z / clip.w = NDC z.
            var fragSrc:String =
                'div ft0, v0.z, v0.w\n' +
                AGALRenderer.packDepthSnippet('ft0', 'ft1') +
                // One full write: AIR refuses a masked write to oc (#3701).
                'mov ft1.z, fc1.zzzz\n' +
                'mov ft1.w, fc0.wwww\n' +
                'mov oc, ft1\n';

            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            vertex.assemble(Context3DProgramType.VERTEX, vertexSrc, AGAL_VERSION);

            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT, fragSrc, AGAL_VERSION);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            this._noteStreams(program, vertexSrc, fragSrc);
            return program;
        }

        // M13 alpha-cutout shadow program: same depth encoding as
        // _buildShadowProgram, plus a base-color texel fetched at the uv varying
        // and a `kil` below `alphaTest * opacity`. three.js renders casters with
        // a depth material that carries the same alphaTest/opacity pair, which is
        // what makes a leaf cutout cast a leaf-shaped shadow instead of a solid
        // quad (D89).
        //
        // fc0 = (alphaTest, opacity, 1.0, 0): alphaTest/opacity are per caster
        // (uploaded per draw), fc0.z is the output alpha of the shadow map.
        private function _buildShadowAlphaProgram():Program3D
        {
            var vertexSrc:String =
                // The clip position is built in vt0 and copied twice: reading `op`
                // back as a source is illegal (AIR #3646 "Can not read from output
                // register"), which as-aot accepted.
                'dp4 vt0.x, va0, vc0\n' +
                'dp4 vt0.y, va0, vc1\n' +
                'dp4 vt0.z, va0, vc2\n' +
                'dp4 vt0.w, va0, vc3\n' +
                'mov op, vt0\n' +
                'mov v0, vt0\n' +
                // M18: the cutout tests the base-color texel, so it has to use the
                // MAP slot's uv transform (vc40/vc41, the same two registers the
                // base pass writes for UV_MAP) -- a tiled leaf cutout must cast a
                // tiled silhouette, not one stretched copy.
                'dp4 vt0.x, va2, vc' + AGALRenderer.UV_CONST_BASE + '\n' +
                'dp4 vt0.y, va2, vc' + (AGALRenderer.UV_CONST_BASE + 1) + '\n' +
                'mov v1.xy, vt0.xy\n' +
                'mov v1.zw, vc0.xxxx\n';   // padding: AIR #3633 needs all four

            var fragSrc:String =
                'tex ft0, v1.xy, fs0 <2d,clamp,linear,mipnone>\n' +
                'mul ft0.w, ft0.w, fc0.y\n' +   // alpha = texel.a * opacity
                'sub ft0.w, ft0.w, fc0.x\n' +   // - alphaTest
                // kil discards when ANY component is negative, so the compare
                // result is broadcast to all four channels first.
                'mov ft0.xyz, ft0.wwww\n' +
                'kil ft0.xxxx\n' +
                'div ft2, v0.z, v0.w\n' +
                AGALRenderer.packDepthSnippet('ft2', 'ft3') +
                'mov ft3.z, fc1.zzzz\n' +
                'mov ft3.w, fc1.wwww\n' +
                'mov oc, ft3\n';

            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            vertex.assemble(Context3DProgramType.VERTEX, vertexSrc, AGAL_VERSION);

            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT, fragSrc, AGAL_VERSION);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            this._noteStreams(program, vertexSrc, fragSrc);
            return program;
        }

        // Point/spot punctual-light program (M6). Both share the standard
        // vertex transform and the normal-mapping + material prefix; they
        // differ only in whether the cone-attenuation stage is appended.
        //
        // The punctual pass runs ADDITIVELY after the base pass, so this
        // fragment computes a single light's direct diffuse + specular
        // contribution (no ambient, no emissive) and encodes to sRGB.
        //
        // fc layout (pinned to _fillPunctualConstants):
        //   fc0 = (cameraPos, EPSILON)
        //   fc1 = (lightPos.xyz, 0.5)
        //   fc2 = (lightColor.rgb, 0)
        //   fc3 = (spotDir.xyz, 0)       [spot] or (0,0,0,0) [point]; .w used to
        //         hold 1/2.2 and is a spare since D170 moved the encode to fc42
        //   fc4 = baseColor
        //   fc5 = (roughness, metalness, 1-metalness, 1/PI)
        //   fc6 = (0.04, 0.04, 0.04, 1.0)
        //   fc7 = unused
        //   fc8 = (normalScale.x, normalScale.y, 2.0, 0)
        //   fc9 = (cutoffInv, decay, 0.01, 0)   [distance attenuation]
        //   fc10 = (coneCos, penumbraCos, 3.0, 2.0)   [spot cone only]
        private function _buildPunctualProgram(isSpot:Boolean, decodeMap:Boolean, flat:Boolean):Program3D
        {
            // Vertex: identical to the standard program (MVP + worldPos +
            // normal + uv). See _buildStandardProgram for the register notes.
            var vertexSrc:String =
                'dp4 op.x, va0, vc0\n' +
                'dp4 op.y, va0, vc1\n' +
                'dp4 op.z, va0, vc2\n' +
                'dp4 op.w, va0, vc3\n' +
                'dp4 v1.x, va0, vc4\n' +
                'dp4 v1.y, va0, vc5\n' +
                'dp4 v1.z, va0, vc6\n' +
                'mov v1.w, vc7.w\n' +
                'dp3 v0.x, va1, vc8\n' +
                'dp3 v0.y, va1, vc9\n' +
                'dp3 v0.z, va1, vc10\n' +
                'mov v0.w, vc10.w\n' +
                AGALRenderer.uvTransformBlock();

            // Fragment prefix: perturb the normal (world-space tangent frame)
            // and compute the view vector V -- identical to the standard
            // program up to this point.
            var fragSrc:String =
                (flat ? '' : 'nrm ft0.xyz, v0.xyz\n') +
                'ddx ft4.xyz, v1.xyz\n' +
                'ddy ft5.xyz, v1.xyz\n' +
                // M18: the normal-map uv is the .zw half of v2 (see uvVaryingOf).
                'ddx ft6.xy, v2.zwzw\n' +
                'ddy ft6.zw, v3.zwzw\n' +
                // M19 flat shading -- identical to the standard program's block.
                (flat ? AGALRenderer.flatNormalBlock() : '') +
                'crs ft7.xyz, ft5.xyz, ft0.xyz\n' +
                'crs ft8.xyz, ft0.xyz, ft4.xyz\n' +
                'mul ft9.xyz, ft7.xyz, ft6.xxxx\n' +
                'mul ft10.xyz, ft8.xyz, ft6.zzzz\n' +
                'add ft9.xyz, ft9.xyz, ft10.xyz\n' +
                'mul ft10.xyz, ft7.xyz, ft6.yyyy\n' +
                'mul ft11.xyz, ft8.xyz, ft6.wwww\n' +
                'add ft10.xyz, ft10.xyz, ft11.xyz\n' +
                'dp3 ft11.x, ft9.xyz, ft9.xyz\n' +
                'dp3 ft11.y, ft10.xyz, ft10.xyz\n' +
                'max ft11.x, ft11.x, ft11.y\n' +
                'max ft11.x, ft11.x, fc0.wwww\n' +
                'sqt ft11.x, ft11.x\n' +
                'rcp ft11.x, ft11.x\n' +
                'mul ft9.xyz, ft9.xyz, ft11.xxxx\n' +
                'mul ft10.xyz, ft10.xyz, ft11.xxxx\n' +
                'tex ft11, v2.zw, fs1 <2d,clamp,linear,mipnone>\n' +
                'mul ft11.xyz, ft11.xyz, fc8.zzzz\n' +
                'sub ft11.xyz, ft11.xyz, fc6.wwww\n' +
                'mul ft11.xy, ft11.xy, fc8.xy\n' +
                'mul ft4.xyz, ft9.xyz, ft11.xxxx\n' +
                'mul ft5.xyz, ft10.xyz, ft11.yyyy\n' +
                'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
                'mul ft5.xyz, ft0.xyz, ft11.zzzz\n' +
                'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
                'nrm ft0.xyz, ft4.xyz\n' +
                'sub ft1.xyz, fc0.xyz, v1.xyz\n' +
                'nrm ft1.xyz, ft1.xyz\n';

            // L = normalize(lightPos - worldPos), distance, and the Frostbite
            // distance attenuation 1/max(dist^decay, 0.01) with the optional
            // cutoff window (three.js getDistanceAttenuation). The result parks
            // in ft10.y.
            fragSrc +=
                'sub ft9.xyz, fc1.xyz, v1.xyz\n' +
                'dp3 ft10.x, ft9.xyz, ft9.xyz\n' +
                'sqt ft10.x, ft10.x\n' +
                'div ft9.xyz, ft9.xyz, ft10.xxxx\n' +
                'pow ft10.y, ft10.x, fc9.y\n' +
                'max ft10.y, ft10.y, fc9.z\n' +
                'rcp ft10.y, ft10.y\n' +
                'mul ft10.z, ft10.x, fc9.x\n' +
                'mul ft10.z, ft10.z, ft10.z\n' +
                'mul ft10.z, ft10.z, ft10.z\n' +
                'sub ft10.w, fc6.w, ft10.z\n' +
                'sat ft10.w, ft10.w\n' +
                'mul ft10.w, ft10.w, ft10.w\n' +
                'mul ft10.y, ft10.y, ft10.w\n';

            // Spot cone: smoothstep(coneCos, penumbraCos, dot(L, spotDir)),
            // multiplying the distance falloff (three.js getSpotAttenuation).
            if (isSpot)
            {
                fragSrc +=
                    'dp3 ft11.x, ft9.xyz, fc3.xyz\n' +
                    'sub ft11.x, ft11.x, fc10.x\n' +
                    'sub ft11.y, fc10.y, fc10.x\n' +
                    'max ft11.y, ft11.y, fc0.wwww\n' +
                    'div ft11.x, ft11.x, ft11.y\n' +
                    'sat ft11.x, ft11.x\n' +
                    'mul ft11.y, ft11.x, ft11.x\n' +
                    'mul ft11.w, ft11.x, fc10.w\n' +
                    'sub ft11.z, fc10.z, ft11.w\n' +
                    'mul ft11.y, ft11.y, ft11.z\n' +
                    'mul ft10.y, ft10.y, ft11.y\n';
            }

            // H + the four dot products against the punctual L (ft9).
            fragSrc +=
                'add ft2.xyz, ft9.xyz, ft1.xyz\n' +
                'nrm ft2.xyz, ft2.xyz\n' +
                'dp3 ft3.x, ft0.xyz, ft9.xyz\n' +
                'sat ft3.x, ft3.x\n' +
                'dp3 ft3.y, ft0.xyz, ft1.xyz\n' +
                'sat ft3.y, ft3.y\n' +
                'dp3 ft3.z, ft0.xyz, ft2.xyz\n' +
                'sat ft3.z, ft3.z\n' +
                'dp3 ft3.w, ft1.xyz, ft2.xyz\n' +
                'sat ft3.w, ft3.w\n';

            // Base color + roughness/metalness factors + specularColorBlended
            // + diffuseContribution (same as the standard Stage 2.5/3).
            fragSrc +=
                'tex ft2, v2.xy, fs0 <2d,clamp,linear,mipnone>\n' +
                // M17: the punctual pass reads the same base-color texel, so it
                // needs the same decode or an sRGB material would be decoded in
                // the base pass and NOT in the additive ones.
                AGALRenderer.srgbDecodeBlock('ft2', decodeMap ? AGALRenderer.DECODE_MAP : 0,
                                             AGALRenderer.DECODE_MAP, 'ft8') +
                'mul ft2.xyz, ft2.xyz, fc4.xyz\n' +
                'tex ft4, v6.xy, fs2 <2d,clamp,linear,mipnone>\n' +
                'mul ft5.x, fc5.x, ft4.y\n' +
                'tex ft4, v6.zw, fs3 <2d,clamp,linear,mipnone>\n' +
                'mul ft5.y, fc5.y, ft4.z\n' +
                'sub ft5.z, fc6.w, ft5.y\n' +
                'mov ft5.w, fc5.w\n' +
                'mul ft6.xyz, fc6.xyz, ft5.zzz\n' +
                'mul ft7.xyz, ft2.xyz, ft5.yyy\n' +
                'add ft6.xyz, ft6.xyz, ft7.xyz\n' +
                'mul ft4.xyz, ft2.xyz, ft5.zzz\n';

            // GGX scalar terms -> VD = V*D in ft4.w (same as Stage 4).
            fragSrc +=
                'mul ft7.x, ft5.x, ft5.x\n' +
                'mul ft7.y, ft7.x, ft7.x\n' +
                'mul ft7.z, ft3.z, ft3.z\n' +
                'sub ft7.w, ft7.y, fc6.w\n' +
                'mul ft7.z, ft7.z, ft7.w\n' +
                'add ft7.z, ft7.z, fc6.w\n' +
                'mul ft7.z, ft7.z, ft7.z\n' +
                'mul ft8.x, fc5.w, ft7.y\n' +
                'div ft8.x, ft8.x, ft7.z\n' +
                'sub ft7.z, fc6.w, ft7.y\n' +
                'mul ft7.w, ft3.y, ft3.y\n' +
                'mul ft7.z, ft7.z, ft7.w\n' +
                'add ft7.z, ft7.z, ft7.y\n' +
                'sqt ft7.z, ft7.z\n' +
                'mul ft7.z, ft3.x, ft7.z\n' +
                'sub ft7.w, fc6.w, ft7.y\n' +
                'mul ft7.x, ft3.x, ft3.x\n' +
                'mul ft7.w, ft7.w, ft7.x\n' +
                'add ft7.w, ft7.w, ft7.y\n' +
                'sqt ft7.w, ft7.w\n' +
                'mul ft7.w, ft3.y, ft7.w\n' +
                'add ft7.z, ft7.z, ft7.w\n' +
                'max ft7.z, ft7.z, fc0.wwww\n' +
                'rcp ft7.z, ft7.z\n' +
                'mul ft7.z, ft7.z, fc1.wwww\n' +
                'mul ft4.w, ft7.z, ft8.x\n';

            // D173: three.js multiplies EVERY direct specular term by
            // material.multiScatteringCompensation (lights_physical_pars_fragment
            // .glsl.js:595), so the additive point/spot passes need the same
            // compensation as the base pass or a lit metal loses energy the
            // moment its light is not a DirectionalLight. This program only uses
            // ft0-ft11, so ft12 (AB), ft13 (scratch) and ft14 (the factor) are
            // free.
            fragSrc +=
                AGALRenderer.envBRDFApproxBlock('ft12', 'ft13') +
                AGALRenderer.multiScatterCompBlock('ft14', 'ft12', 'ft13');

            // Direct diffuse (no ambient): diffCont/PI * lightColor * falloff
            // * dotNL * (1 - F_004). The MOV (not ADD) replaces the dead
            // diffCont baseline in ft4.xyz -- an additive pass has no ambient
            // term, and ADD would leak the un-divided baseColor (near-white)
            // into every output pixel, washing out the light color (M6 bug).
            fragSrc +=
                'mul ft7.xyz, ft4.xyz, fc5.wwww\n' +
                'sub ft8.y, fc6.w, ft3.w\n' +
                'mul ft8.z, ft8.y, ft8.y\n' +
                'mul ft8.z, ft8.z, ft8.z\n' +
                'mul ft8.z, ft8.z, ft8.y\n' +
                'sub ft8.w, fc6.w, ft8.z\n' +
                'mul ft8.w, fc6.x, ft8.w\n' +
                'add ft8.w, ft8.w, ft8.z\n' +
                'sub ft8.w, fc6.w, ft8.w\n' +
                'mul ft8.w, ft8.w, ft3.x\n' +
                'mul ft8.xyz, ft8.wwww, fc2.xyz\n' +
                'mul ft8.xyz, ft8.xyz, ft10.yyyy\n' +
                'mul ft8.xyz, ft8.xyz, ft7.xyz\n' +
                'mov ft4.xyz, ft8.xyz\n';

            // Direct specular: specularBRDF * dotNL * lightColor * falloff.
            fragSrc +=
                'sub ft7.w, fc6.w, ft3.w\n' +
                'mul ft8.y, ft7.w, ft7.w\n' +
                'mul ft8.y, ft8.y, ft8.y\n' +
                'mul ft8.y, ft8.y, ft7.w\n' +
                'sub ft8.z, fc6.w, ft8.y\n' +
                'mul ft7.xyz, ft6.xyz, ft8.zzz\n' +
                'add ft7.xyz, ft7.xyz, ft8.yyy\n' +
                'mul ft7.xyz, ft7.xyz, ft4.wwww\n' +
                'mul ft7.xyz, ft7.xyz, ft3.xxxx\n' +
                'mul ft7.xyz, ft7.xyz, fc2.xyz\n' +
                'mul ft7.xyz, ft7.xyz, ft14.xyz\n' +   // * multiScatteringCompensation (D173)
                'mul ft7.xyz, ft7.xyz, ft10.yyyy\n' +
                'add ft4.xyz, ft4.xyz, ft7.xyz\n';

            // Encode to sRGB (fc41/fc42, D170) and output; no emissive in an
            // additive pass. M10: tone mapping is applied to the linear
            // contribution for consistency with the base pass. This is an
            // APPROXIMATION of the single-pass sum (toneMap(a) + toneMap(b) is
            // not toneMap(a + b)); it keeps the two passes' curve identical so
            // a punctual-only scene still looks tone-mapped rather than
            // clipped. Documented in three-api-design.md §15.
            fragSrc +=
                this._toneMapBlock('ft4', 'ft9', 'ft10', 'ft11') +
                'sat ft4.xyz, ft4.xyz\n' +
                // D170: the same exact sRGB encode as the base pass, or an
                // sRGB material would be encoded differently in the additive
                // punctual passes than in the pass underneath it.
                AGALRenderer.srgbEncodeBlock('ft4') +
                'mov ft4.w, fc6.wwww\n' +
                'mov oc, ft4\n';

            var vertex:AGALMiniAssembler = new AGALMiniAssembler();
            vertex.assemble(Context3DProgramType.VERTEX, vertexSrc, AGAL_VERSION);

            var fragment:AGALMiniAssembler = new AGALMiniAssembler();
            fragment.assemble(Context3DProgramType.FRAGMENT, fragSrc, AGAL_VERSION);

            var program:Program3D = this._context.createProgram();
            program.upload(vertex.agalcode, fragment.agalcode);
            this._noteStreams(program, vertexSrc, fragSrc);
            return program;
        }

        // Fill the fragment constants for one punctual pass (M6). The light
        // color is pre-scaled by intensity; the spot direction is normalized
        // position - target (three.js WebGLLights.js:587-593). See
        // _buildPunctualProgram for the register layout.
        private function _fillPunctualConstants(light:Light, material:MeshStandardMaterial, isSpot:Boolean):void
        {
            var c:Vector.<Number> = this._fragConst;

            // fc0 = (cameraPos, EPSILON)
            c[0] = this._cameraPos.x;
            c[1] = this._cameraPos.y;
            c[2] = this._cameraPos.z;
            c[3] = 1e-9;

            // fc1 = (lightPos.xyz, 0.5)
            light.getWorldPosition(this._tmpA);
            c[4] = this._tmpA.x;
            c[5] = this._tmpA.y;
            c[6] = this._tmpA.z;
            c[7] = 0.5;

            // fc2 = lightColor = color * intensity
            c[8] = light.color.r * light.intensity;
            c[9] = light.color.g * light.intensity;
            c[10] = light.color.b * light.intensity;
            c[11] = 0;

            // fc3 = (spotDir.xyz, gamma) for spot, (0,0,0,gamma) for point.
            if (isSpot)
            {
                var spot:SpotLight = SpotLight(light);
                spot.target.updateMatrixWorld(true);
                spot.target.getWorldPosition(this._tmpB);
                // spotDirection = normalize(position - target)
                this._lightDir.subVectors(this._tmpA, this._tmpB);
                this._lightDir.normalize();
                c[12] = this._lightDir.x;
                c[13] = this._lightDir.y;
                c[14] = this._lightDir.z;
            }
            else
            {
                c[12] = 0;
                c[13] = 0;
                c[14] = 0;
            }
            c[15] = 0;   // fc3.w: spare; held 1/2.2 before D170 moved the encode

            // fc4 = baseColor
            c[16] = material.color.r;
            c[17] = material.color.g;
            c[18] = material.color.b;
            c[19] = 0;

            // fc5 = (roughness, metalness, 1-metalness, 1/PI)
            var roughness:Number = material.roughness < 0.045 ? 0.045 : material.roughness;
            if (roughness > 1) roughness = 1;
            c[20] = roughness;
            c[21] = material.metalness;
            c[22] = 1 - material.metalness;
            c[23] = 1 / Math.PI;

            // fc6 = (0.04, 0.04, 0.04, 1.0)
            c[24] = 0.04;
            c[25] = 0.04;
            c[26] = 0.04;
            c[27] = 1.0;

            // fc7 = unused in a punctual pass.
            c[28] = 0;
            c[29] = 0;
            c[30] = 0;
            c[31] = 0;

            // fc8 = (normalScale.x, normalScale.y, 2.0, 0)
            c[32] = material.normalScale.x;
            c[33] = material.normalScale.y;
            c[34] = 2.0;
            c[35] = 0;

            // fc9 = (cutoffInv, decay, 0.01, 0)
            var distance:Number;
            var decay:Number;
            if (isSpot)
            {
                distance = SpotLight(light).distance;
                decay = SpotLight(light).decay;
            }
            else
            {
                distance = PointLight(light).distance;
                decay = PointLight(light).decay;
            }
            c[36] = distance > 0 ? 1.0 / distance : 0.0;
            c[37] = decay;
            c[38] = 0.01;
            c[39] = 0;

            // fc10 = (coneCos, penumbraCos, 3.0, 2.0) for the spot cone.
            if (isSpot)
            {
                var s:SpotLight = SpotLight(light);
                c[40] = Math.cos(s.angle);
                c[41] = Math.cos(s.angle * (1 - s.penumbra));
            }
            else
            {
                c[40] = 0;
                c[41] = 0;
            }
            c[42] = 3.0;
            c[43] = 2.0;

            // fc11..fc13: Karis's EnvBRDFApprox coefficients (D173). The punctual
            // pass now applies the same multiScatteringCompensation as the base
            // pass, so these three registers have to be uploaded here too. Until
            // D173 the punctual upload stopped at fc10, so those slots still held
            // whatever the last standard draw left there.
            c[44] = -1.0;
            c[45] = -0.0275;
            c[46] = -0.572;
            c[47] = 0.022;
            c[48] = 1.0;
            c[49] = 0.0425;
            c[50] = 1.04;
            c[51] = -0.04;
            c[52] = -9.28;
            c[53] = Math.PI;
            c[54] = -1.04;
            c[55] = 1.04;

            this._context.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, 0, this._fragConst, 14);
            this._uploadSrgbConstants();
            // M10: the punctual fragment tone-maps its additive contribution too,
            // so it needs fc14..fc21 as well.
            this._uploadToneConstants(material.alphaTest, material.opacity);
        }

        // Widen the geometry's Vector.<Number> index attribute to the
        // Vector.<uint> that IndexBuffer3D.uploadFromVector requires (D11).
        private function _toUintVector(index:BufferAttribute):Vector.<uint>
        {
            var src:Vector.<Number> = index.array;
            var n:int = src.length;
            var dst:Vector.<uint> = new Vector.<uint>(n);
            for (var i:int = 0; i < n; i++)
            {
                dst[i] = uint(src[i]);
            }
            return dst;
        }
    }
}
