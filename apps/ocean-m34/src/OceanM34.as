// OceanM34.as -- M34: the rest of the Ultra-Water reproduction, on the native-shader
// channel.
//
// WHAT THIS IS. M32 proved that a Tessendorf FFT ocean COMPOSES on the native channel
// (spectrum -> ping-pong IFFT -> packed displacement). This stage adds the six things
// that separate "an FFT on screen" from the reference image, each ported from
// `Humpalumps/Ultra-Water`:
//
//   1. ATMOSPHERE (src/scene/atmosphere.js, sky.js). Hillaire 2020: a transmittance LUT,
//      a multiple-scattering LUT and a sky-view LUT, baked once, then one fetch per sky
//      pixel plus an analytic sun disc and one cloud deck.
//   2. FOUR CASCADES (src/water/OceanSim.js). 600/85/12/2.1 m, each its own 256x256
//      IFFT. The 2.1 m cascade puts detail on the near water; the 600 m one is what
//      makes the horizon a horizon.
//   3. CAUSTICS (src/water/Caustics.js). Area-ratio splatting: the wave slopes refract
//      the sun onto the seabed and untouched-area/landed-area is the intensity. Three
//      surfaces (1.5/4/10 m) multiplied into one lookup.
//   4. UNDERWATER (src/water/UnderwaterPass.js). A lens map decides per pixel whether
//      the near plane is under the surface, so a wave washing over the camera splits the
//      screen at the exact waterline; under it, Beer-Lambert absorption plus sun shafts
//      marched through the same caustics.
//   5. SPRAY (src/water/Spray.js). Spindrift on the crests. Stateless: the emitter table
//      is uploaded once and the vertex program decides who is alive from the surface
//      height, so there is no particle system to update.
//   6. PLANAR REFLECTION (src/engine/PlanarReflection.js). The scene re-rendered with a
//      mirrored camera; the water samples it by WORLD POSITION through the mirror's own
//      view-projection, which is what makes the reflection stick to the surface instead
//      of sliding with the screen.
//
// THE FRAME, and the ORDER is load-bearing:
//
//   FFT x4 cascades  ->  displacement + slope texts
//   caustics         ->  3 splats, then mips
//   reflection       ->  mirrored scene, y<0 discarded
//   opaque           ->  sky + terrain; alpha = LINEAR VIEW DEPTH
//   water            ->  samples opaque for refraction; alpha = surface tag
//   spray            ->  additive
//   lens + shafts    ->  only when the camera is near/under the surface
//   composite        ->  assemble and absorb, into the linear HDR target
//   post             ->  metered exposure, bloom pyramid, tone map + grade -> back buffer
//
// THE CONTROL PANEL (M35) drives the same parameters `temp/ultra-water/src/main.js`
// exposes through lil-gui: sun & sky, sea state, water optics, exposure and planar
// reflections. It is a LINKED asaotui panel (apps/ocean-m34/class-paths), the same
// arrangement M24 uses, and it follows the same one-writer rule: a widget writes
// panel.OceanParams, and this class's frame loop is the only reader. Two entries
// cost a REBAKE rather than a uniform write (the atmosphere LUTs and the JONSWAP
// spectra are baked), which is why applyParams() compares against the last applied
// values instead of pushing every slider every frame.
//
// WRITING DEPTH INTO ALPHA is the one decision the reference does not make. three.js can
// sample a depth texture; this channel cannot (sampler2D depth is not portable through
// SPIRV-Cross/Metal, measured in M31 -- see three-api-design.md). The water pass has to
// know what is behind it, so the opaque pass stores view-space metres in alpha. Every
// depth comparison below is then a plain float compare, in the same unit the projection
// produces.
//
// Run (from asaot3d/):
//   ./apps/ocean-m34/build.sh aot --run
package
{
    import flash.desktop.NativeApplication;
    import flash.display.BitmapData;
    import flash.filesystem.File;
    import flash.filesystem.FileMode;
    import flash.filesystem.FileStream;
    import flash.geom.Matrix;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;
    import flash.display3D.Context3DTextureFormat;

    import asaot.three.NativeShaderRenderer;
    import asaot.three.RendererFactory;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.controls.OrbitControls;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.materials.Material;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    import asaot.ui.Dirty;
    import asaot.ui.Theme;
    import asaot.ui.ThemeTokens;
    import asaot.ui.UiApp;

    import panel.OceanParams;
    import panel.OceanPanelView;

    public class OceanM34 extends Stage3DApp
    {
        // ------------------------------------------------------------------
        // Tuning
        // ------------------------------------------------------------------
        private static const N:int = 256;                       // FFT tile per cascade

        // Cascade patch lengths, the reference's values.
        private static const P0:Number = 600.0;
        private static const P1:Number = 85.0;
        private static const P2:Number = 12.0;
        private static const P3:Number = 2.1;

        // (WIND_ANGLE is gone: the wind bearing is panel.OceanParams.windDirection,
        // seeded to this 0.6 rad. Keeping a second copy here is how a "constant" and a
        // slider end up disagreeing.)

        // Internal render size. Fixed, not the stage size: a readback is then 768x480 in
        // both the AOT and the adl run, and the composite is the only pass that touches
        // the window's own resolution.
        private static const NEAR:Number = 0.5;
        private static const FAR:Number = 12000.0;

        private static const RW:int = 1152;
        private static const RH:int = 720;

        private static const TRANS_W:int = 256;
        private static const TRANS_H:int = 64;
        private static const MS_N:int = 32;
        private static const SKY_W:int = 192;
        private static const SKY_H:int = 108;

        private static const CAUSTIC_NEAR:int = 512;
        private static const CAUSTIC_DEEP:int = 256;
        private static const CAUSTIC_CELLS:int = 128;

        // Bloom pyramid depth and the auto-exposure metering grid, both the
        // reference's (src/engine/PostFX.js: LEVELS = 6, METER = 32).
        private static const BLOOM_LEVELS:int = 6;
        private static const METER:int = 32;

        // Adaptation rates, 1/s: the scene brightening closes the iris faster than it
        // opens (~0.4 s vs ~1 s), so a flash does not chase the exposure for a second.
        private static const ADAPT_UP:Number = 2.5;
        private static const ADAPT_DOWN:Number = 1.0;

        private static const SPRAY_COUNT:int = 2600;
        private static const CHECK_ENABLED:Boolean = true;

        // Application clock ceiling, in Hz. The host otherwise runs the clock at the
        // panel rate (120 Hz here), which doubled this demo's CPU for frames nobody
        // asked for: one frame is a 4.6 ms CPU/GPU composite that already looks
        // complete at 60. 60 Hz is also the cadence the browser reference actually
        // presents at, so the two become comparable instead of "half the frames".
        private static const FRAME_RATE_CAP:Number = 60;

        // The camera control's two numbers, both the reference's: `maxDistance = 6000`
        // (main.js:46) and the ground clearance `islandHeight(x, z) + 0.8`
        // (main.js:417-421). No minDistance and no polar limits -- the reference
        // leaves three.js's defaults, which is what lets the camera dive under the
        // surface and orbit from below.
        private static const ORBIT_MAX_DISTANCE:Number = 6000.0;
        private static const CAMERA_FLOOR:Number = 0.8;

        // Write the composed frame to temp/m34-frame.ppm once the checks are in. A
        // window capture reads the window server's last snapshot, which goes stale for
        // this demo (the Metal layer presents without an AppKit redraw), so the only
        // frame worth judging is the one read back out of the back buffer.
        private static const DUMP_FRAME:Boolean = false;

        // Freeze the animation once this frame count is reached, so a window capture
        // and an in-app readback can be compared pixel for pixel. -1 disables it.
        private static const FREEZE_AT:int = -1;
        private static const DUMP_AT:int = 60;

        // Dump the material reflection tables (every uniform's slot and type) once, on
        // the first water/composite draw. Off by default: it is a diagnosis for "the
        // program does not declare uX" warnings, not part of a demo run.
        private static const TRACE_PROGRAMS:Boolean = false;

        // Absorption in 1/m. Red dies an order of magnitude faster than blue, which is
        // the whole difference between blue water and green water. The VALUES now live
        // in panel.OceanParams (a preset + clarity), because the panel owns the sea's
        // colour; these two are only the defaults' documentation.
        // Reference units: radiance is relative to the sun's illuminance outside the
        // atmosphere, and the sun's own colour at sea level is its transmittance times
        // sunIntensity (Ultra-Water src/scene/sky.js). At the 11 degree elevation used
        // here that integral is [0.675, 0.451, 0.232], so the colour is that times 9 --
        // NOT a hand-picked [1.35, 1.16, 0.94], which made the whole scene ~4x dark and
        // the sun's disc 16x dark.
        //
        // SUNCOL_REF is the colour at the reference's own sunIntensity of 9; the panel's
        // intensity slider scales BOTH it and the sky's illuminance,
        // `sunColor = T * intensity` and `PI * intensity` in the reference
        // (src/scene/sky.js applySun), i.e. linearly and independently -- scaling one of
        // the two would be an intensity SQUARED.
        private static const SUN_INTENSITY_REF:Number = 9.0;
        private static const SUNCOL_REF:Array = [3.186, 1.177, 0.191];

        private static const DEG2RAD:Number = 0.017453292519943295;

        // Sea state, from Ultra-Water's OceanSim defaults: two JONSWAP trains (a 9 m/s
        // wind sea over a 120 km fetch and a 7 m/s swell over 900 km), 3.3 peak
        // enhancement, a 0.04 short-wave fade, and 0.08 on the capillary cascade --
        // 0.004 there is the bare spectrum, whose mean square slope is 3x Cox-Munk for
        // the whole sea and turns the water to brushed metal. The wind speed, fetch,
        // directions and scales are panel parameters now (panel.OceanParams).
        private static const SWELL_SPEED:Number = 7.0;
        private static const SWELL_FETCH_KM:Number = 900.0;
        private static const CAP_FADE:Number = 0.08;

        private static const PROBE_FS:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uSrc;\n" +
            "uniform int uChan;\n" +
            "uniform float uGain;\n" +
            "uniform float uBias;\n" +
            "in vec2 vUV;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  vec4 t = textureLod(uSrc, vUV, 0.0);\n" +
            "  float v = uChan == 0 ? t.r : (uChan == 1 ? t.g : (uChan == 2 ? t.b : t.a));\n" +
            "  float e = clamp(v * uGain + uBias, 0.0, 1.0);\n" +
            "  fragColor = vec4(e, e, e, 1.0);\n" +
            "}\n";

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------
        private var _native:Object;
        // Hot-path native entry points, resolved once (see NativeShaderRenderer for the
        // measurement: a bracket call costs ~25 us in this runtime, a field call ~0.5 us,
        // and this demo issues 10 bind-target + 7 mipmap calls every frame).
        private var _fnSetTargets:Function;
        private var _fnMips:Function;
        private var _fnBackBuffer:Function;
        private var _fnSetSamples:Function;
        private var _nr:NativeShaderRenderer;
        private var _noChannel:Boolean = false;

        private var _quad:Mesh;
        private var _waterMesh:Mesh;
        private var _terrainMain:Mesh;
        private var _terrainRefl:Mesh;
        private var _skyMain:Mesh;
        private var _skyRefl:Mesh;
        private var _causticMesh:Mesh;
        private var _sprayMesh:Mesh;

        private var _h0:Array = [];             // [c] -> spectrum
        private var _fftA:Array = [];           // [c] -> [MRT slot 0, slot 1]
        private var _fftB:Array = [];
        private var _disp:Array = [];           // [c] -> [this frame, last frame]
        private var _slope:Array = [];          // [c] -> (sx, sz, sx^2, sz^2), mipmapped
        private var _cur:int = 0;               // which _disp slot simulate is writing

        private var _transLut:Object;
        private var _msLut:Object;
        private var _skyLut:Object;

        private var _causticNear:Object;
        private var _causticDeep:Object;

        private var _refl:Object;
        private var _reflDepth:Object;
        private var _reflOff:Object;
        // The internal render size. RW/RH are render scale 1.0's base (1152x720, i.e.
        // 1.2x the 960x600 window); the panel's QUALITY row multiplies them and
        // applyRenderScale() rebuilds the size-dependent targets when it changes.
        private var _rw:int = RW;
        private var _rh:int = RH;
        private var _scaleApplied:Number = 1.0;
        // Last multisample level pushed to the scene targets. 0 = "not yet applied", so a
        // rebuilt target set (render scale) re-acquires its level instead of keeping the
        // fresh textures single-sample.
        private var _appliedMsaa:int = 0;
        private var _opaque:Object;
        private var _opaqueDepth:Object;
        private var _water:Object;
        private var _spray:Object;
        private var _lens:Object;
        private var _shafts:Object;

        // The post chain. `_hdr` is what composite.frag writes (linear, pre-grade) and
        // grade.frag reads; the bloom pyramid and the metered-exposure state hang off it.
        private var _hdr:Object;
        private var _bloom:Array = [];          // [i] -> level i, half, quarter, ...
        private var _meter:Object;              // METER x METER log2 luminance
        private var _adapt:Array = [];          // 1x1 ping-pong, [_adaptCur] is current
        private var _adaptCur:int = 0;
        private var _adaptSnap:Boolean = true;  // next metered frame replaces the state
        private var _bloomW:Array = [];
        private var _bloomH:Array = [];

        // Smoothed underwater exposure compensation (the reference's `uwComp`): 1 above
        // the surface, `underwaterExposure` below, eased so surfacing does not flash.
        private var _uwComp:Number = 1.0;

        private var _mTrans:ShaderMaterial;
        private var _mMs:ShaderMaterial;
        private var _mSkyLut:ShaderMaterial;
        private var _mSky:ShaderMaterial;
        private var _mInit:ShaderMaterial;
        private var _mEvolve:ShaderMaterial;
        private var _mFft:ShaderMaterial;
        private var _mAssemble:ShaderMaterial;
        private var _mCaustic:ShaderMaterial;
        private var _mTerrain:ShaderMaterial;
        private var _mWater:ShaderMaterial;
        private var _mSpray:ShaderMaterial;
        private var _mLens:ShaderMaterial;
        private var _mShafts:ShaderMaterial;
        private var _mComposite:ShaderMaterial;
        private var _mDownPre:ShaderMaterial;
        private var _mDown:ShaderMaterial;
        private var _mUp:ShaderMaterial;
        private var _mMeter:ShaderMaterial;
        private var _mAdapt:ShaderMaterial;
        private var _mGrade:ShaderMaterial;
        private var _mProbe:ShaderMaterial;
        private var _mPresent:ShaderMaterial;

        // _scene and _camera are inherited from Stage3DApp: re-declaring them here
        // would create a SECOND field that the base class's own null check cannot see.
        private var _reflScene:Scene;
        private var _mirror:PerspectiveCamera;
        private var _mvp:Matrix4 = new Matrix4();
        private var _invProj:Matrix4 = new Matrix4();
        private var _invVP:Matrix4 = new Matrix4();

        private var _time:Number = 0;
        private var _frames:int = 0;
        private var _dbgDescribed:Boolean = false;
        private var _dumped:Boolean = false;
        private var _dbgWaterDescribed:Boolean = false;
        private var _belowFrames:int = 0;
        private var _checked:Boolean = false;
        private var _checkedBelow:Boolean = false;
        private var _underwater:Boolean = false;
        private var _failures:int = 0;
        private var _quitAt:int = -1;

        private var _sunX:Number = 0;
        private var _sunY:Number = 0;
        private var _sunZ:Number = 0;
        // Sun radiance and the sky LUT's illuminance scale, both derived from the
        // panel's intensity: `sunColor = transmittance * intensity` and
        // `illuminance = PI * intensity` in the reference.
        private var _sunCol:Array = [3.186, 1.177, 0.191];
        private var _sunIllum:Number = Math.PI * SUN_INTENSITY_REF;

        // The control panel. `_params` is the only thing a widget writes; see
        // applyParams() for the single reader.
        private var _params:OceanParams;
        private var _panel:OceanPanelView;
        private var _ui:UiApp;

        // Last APPLIED parameter values. The atmosphere LUTs and the JONSWAP
        // spectra are BAKED, so a drag must trigger one bake, not one per frame;
        // and a uniform write on a value that did not move is a wasted
        // setUniformValue per material per frame.
        private var _appliedElev:Number = -1e9;
        private var _appliedAzim:Number = -1e9;
        private var _appliedSunI:Number = -1e9;
        private var _appliedCloud:Number = -1e9;
        private var _appliedWindSpeed:Number = -1e9;
        private var _appliedWindDir:Number = -1e9;
        private var _appliedFetch:Number = -1e9;
        private var _appliedWaveScale:Number = -1e9;
        private var _appliedSpread:Number = -1e9;
        private var _appliedSwellScale:Number = -1e9;
        private var _appliedSwellDir:Number = -1e9;

        // Camera selection: 0 is the demo's own 26 s loop, 1.. index the reference's
        // named views. `_viewApplied` makes a fixed view a one-shot (a view that
        // reinstalled its camera every frame would fight nothing, but it would also
        // make "look around then switch back" impossible to add later).
        private var _viewApplied:int = -1;
        private var _viewReqApplied:int = -1;

        // THE POINTER-DRIVEN CAMERA. `_controls` is always connected -- the same
        // arrangement the reference has (main.js:44) -- and `_freeCam` is the cruise
        // YIELDING to it. There is deliberately no "manual" entry in the camera menu:
        // the reference's menu only names the last preset, and orbiting afterwards
        // leaves it there (main.js:217). `_freeCam` is therefore "who writes the
        // camera this frame", not a mode the UI has to display.
        private var _controls:OrbitControls;
        private var _freeCam:Boolean = false;

        // The pose the cruise wrote last frame. Nothing else writes the camera while
        // the cruise runs, so a pose that differs can only be OrbitControls answering
        // a drag or a wheel -- which is how a takeover is detected without listening
        // to the same events twice (see detectCameraTakeover).
        private var _cruisePos:Vector3 = new Vector3();
        private var _cruiseQuat:Quaternion = new Quaternion();
        private var _haveCruisePose:Boolean = false;

        // Draws issued this frame, for the HUD's CALLS tile: this demo issues ~80
        // offscreen passes plus two scene renders, and `renderer.drawCalls` only ever
        // reports the LAST render, i.e. `1`.
        private var _draws:int = 0;

        // ------------------------------------------------------------------
        // Scene construction
        // ------------------------------------------------------------------
        override protected function createScene():void
        {
            // This demo owns the back buffer: every pass from the FFT to the graded
            // composite is issued here, so the host must not render _scene on top of it.
            _ownsFrame = true;

            // The panel's model exists BEFORE the scene, because the scene is built
            // from it: the sun's bearing, the sea state and the water colour are all
            // parameters now, not constants. `_params` keeps the reference's defaults,
            // so this is the same scene the previous revision built.
            _params = new OceanParams();
            this.updateSun();

            // One HUD tile shows ~86 passes; the default 40 would pin the bar at full
            // height on every frame and hide the variation a HUD is for.
            hudCallsMax = 120;
            hudTrisMax = 400000;

            if (!RendererFactory.hasNativeChannel() || !(_renderer is NativeShaderRenderer))
            {
                // The AIR / default-build answer is not a failure: the enhancement is
                // opt-in and its absence is reported loudly, not approximated in AGAL.
                _noChannel = true;
                _scene = new Scene();
                _camera = new PerspectiveCamera(50, 1, 0.5, 12000);
                return;
            }
            _nr = NativeShaderRenderer(_renderer);
            _native = _nr.context3DNative;
            _fnSetTargets = _native["setRenderTargets"];
            _fnMips = _native["generateMipmaps"];
            _fnBackBuffer = _native["setBackBuffer"];
            _fnSetSamples = _native["setRenderTargetSamples"];

            this.makeTargets();
            this.makeMaterials();
            this.makeGeometry();

            _camera = new PerspectiveCamera(50, Number(_rw) / _rh, 0.5, 12000);
            _camera.position.set(0, 9, 150);
            this.makeControls();

            // The reflection needs its own camera object: `render()` computes a camera's
            // world matrix from its transform, so the mirrored matrix has to be handed
            // over as a matrix (matrixAutoUpdate off) rather than decomposed.
            _mirror = new PerspectiveCamera(50, Number(_rw) / _rh, 0.5, 12000);
            _mirror.matrixAutoUpdate = false;

            this.bakeAtmosphere();
            this.bakeSpectra();
            _fnBackBuffer();

            // The reflection stand-in: one clear into a 1x1 target, once.
            _fnSetTargets([_reflOff], null);
            _context.clear(0, 0, 0, 1, 1, 0, 7);

            // Remember what the bakes were made from, so the first frame does not
            // immediately re-bake them (applyParams() compares against these).
            this.markParamsApplied();

            this.buildPanel();

            logLine("ocean-m34: 4 cascades (" + P0 + "/" + P1 + "/" + P2 + "/" + P3 + " m) x " +
                N + " FFT, " + _rw + "x" + _rh + " internal; atmosphere + caustics + spray + " +
                "underwater + planar reflection; " + (18 * 4 + 14) + " passes/frame");
            logLine("ocean-m34 panel: " + _params.describe());
        }

        // THE CAMERA CONTROL. three.js binds OrbitControls to the canvas
        // (`renderer.domElement`), where the GUI is a sibling element and never
        // shares its pointer stream; AIR has one display list, so the panel's
        // presses bubble into the same stage listener. `pointerFilter` is that
        // missing separation, answered by the panel's own layout (see
        // OceanPanelView.blocksPointer and R94).
        //
        // Everything else is the reference's configuration, unmodified: damping on
        // with r187's default factor (main.js:45 never sets one), and a 6 km dolly
        // ceiling (main.js:46). No minDistance, no polar/azimuth clamps -- three.js's
        // defaults are what make the underwater views usable.
        private function makeControls():void
        {
            var self:OceanM34 = this;
            _controls = new OrbitControls(_camera, stage);
            _controls.enableDamping = true;
            _controls.maxDistance = ORBIT_MAX_DISTANCE;
            // The cruise's own aim (see updateCamera), so grabbing the camera during
            // the loop pivots around what is actually on screen.
            _controls.target.set(0, 5.2, 0);
            _controls.setSize(stage.stageWidth, stage.stageHeight);
            _controls.pointerFilter = function (x:Number, y:Number):Boolean
            {
                if (self._panel == null) return true;
                return !self._panel.blocksPointer(x, y);
            };
            _controls.update();
        }

        // The asaotui control panel, linked in place (class-paths). Built from
        // createScene() so the first painted frame already has it: a panel that waits
        // for a click shows an empty strip in every screenshot.
        private function buildPanel():void
        {
            // Dark palette: the panel is a dark slab over a dark sea, and the light
            // default would put grey-on-grey labels next to a golden sky.
            Theme.setTheme(ThemeTokens.dark());

            var self:OceanM34 = this;
            this._panel = new OceanPanelView(this._params, function (d:int):void
            {
                self._ui.invalidate(d);
            });
            this._panel.setStageSize(stage.stageWidth, stage.stageHeight);

            this._ui = new UiApp(this._panel);
            this._ui.mount(stage);
            this._ui.attachRoot();
            this._ui.invalidate(Dirty.ALL);
            this._ui.reflow();
        }

        // Every render target. Float where the payload is not a colour: an FFT
        // intermediate and a view depth both need exact values, and half-float would
        // quantise a 4 km depth into ~4 m steps.
        // Two sets, because only one of them depends on the render size.
        //
        // FIXED: the FFT cascades (N x N), the atmosphere LUTs, the caustics, the lens
        // map, the metering grid and the exposure state. They are baked once -- the LUTs
        // and the spectra in createScene, the caustics every frame -- so recreating them
        // on a resize would throw away the bake and leave a black sky until the next edit
        // of the sun. (Measured: it did exactly that.)
        //
        // SCREEN: everything sized from _rw x _rh, i.e. the scene targets, the reflection,
        // the shafts and the post chain. Only this half is rebuilt by applyRenderScale().
        private function makeTargets():void
        {
            this.makeFixedTargets();
            this.makeScreenTargets();
        }

        private function makeFixedTargets():void
        {
            _h0 = []; _fftA = []; _fftB = []; _disp = []; _slope = [];
            _adapt = []; _adaptCur = 0; _adaptSnap = true;

            var c:int;
            for (c = 0; c < 4; c++)
            {
                _h0.push(_native["createTexture"](N, N, "rgba32f", true, false));
                _fftA.push([_native["createTexture"](N, N, "rgba32f", true, false),
                            _native["createTexture"](N, N, "rgba32f", true, false)]);
                _fftB.push([_native["createTexture"](N, N, "rgba32f", true, false),
                            _native["createTexture"](N, N, "rgba32f", true, false)]);
                // mipmapped: water.vert derives its per-vertex LOD from the vertex's own
                // cell size, so the cascades MUST have a chain to sample
                _disp.push([_native["createTexture"](N, N, Context3DTextureFormat.RGBA_HALF_FLOAT, true, true),
                            _native["createTexture"](N, N, Context3DTextureFormat.RGBA_HALF_FLOAT, true, true)]);
                _slope.push(_native["createTexture"](N, N, Context3DTextureFormat.RGBA_HALF_FLOAT, true, true));
            }

            _transLut = _native["createTexture"](TRANS_W, TRANS_H, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _msLut = _native["createTexture"](MS_N, MS_N, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            // mipmapped: the water looks the sky up at a roughness-driven LOD (a sharp
            // lookup turns every steep facet into a streak of cloud edge), and a LOD past
            // the last level of an unmipmapped target is black, not blurred.
            _skyLut = _native["createTexture"](SKY_W, SKY_H, Context3DTextureFormat.RGBA_HALF_FLOAT, true, true);

            _causticNear = _native["createTexture"](CAUSTIC_NEAR, CAUSTIC_NEAR, "rgba32f", true, true);
            _causticDeep = _native["createTexture"](CAUSTIC_DEEP, CAUSTIC_DEEP, "rgba32f", true, true);

            _lens = _native["createTexture"](64, 36, "rgba32f", true, false);
            _meter = _native["createTexture"](METER, METER, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            // 1x1 ping-pong state, float: it holds one log-luminance and a half float
            // would quantise it to ~1/1000 of an EV at the top of its range while the
            // adaptation blends it over seconds.
            _adapt.push(_native["createTexture"](1, 1, "rgba32f", true, false));
            _adapt.push(_native["createTexture"](1, 1, "rgba32f", true, false));

            // Stand-in for "reflections off": the water program ALWAYS samples
            // uReflection, and an unbound sampler is a Metal validation failure that
            // draws nothing. 1x1 black, cleared once below.
            _reflOff = _native["createTexture"](1, 1, Context3DTextureFormat.RGBA_HALF_FLOAT, false, false);
        }

        private function makeScreenTargets():void
        {
            _bloom = []; _bloomW = []; _bloomH = [];
            // Fresh textures carry no multisample companion, so the level is re-applied
            // on the next frame (applyMsaa sees a different value and pushes it).
            _appliedMsaa = 0;

            // mipmapped: the water samples this at a roughness-driven LOD, and a LOD past
            // the last level of an unmipmapped target is black, not blurred.
            _refl = _native["createTexture"](_rw / 2, _rh / 2, Context3DTextureFormat.RGBA_HALF_FLOAT, true, true);
            _reflDepth = _native["createDepthTexture"](_rw / 2, _rh / 2, "depth32f");
            _opaque = _native["createTexture"](_rw, _rh, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _opaqueDepth = _native["createDepthTexture"](_rw, _rh, "depth32f");
            _water = _native["createTexture"](_rw, _rh, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _spray = _native["createTexture"](_rw, _rh, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _shafts = _native["createTexture"](_rw / 4, _rh / 4, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);

            // --- post -------------------------------------------------------
            // Linear HDR: half float because the sun disc and the glitter road are well
            // above 1 and the bloom threshold is a real value on this scale.
            _hdr = _native["createTexture"](_rw, _rh, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);

            var w:int = _rw;
            var h:int = _rh;
            var i:int;
            for (i = 0; i < BLOOM_LEVELS; i++)
            {
                w = w / 2; if (w < 1) w = 1;
                h = h / 2; if (h < 1) h = 1;
                _bloomW.push(w);
                _bloomH.push(h);
                _bloom.push(_native["createTexture"](w, h, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false));
            }
        }

        private function makeMaterials():void
        {
            var L:Array;

            // --- atmosphere LUT bakes, each runs once ---
            _mTrans = this.mat(OceanM34Assets.program("trans_frag", ["atmo_core", "atmo_math"]),
                               OceanM34Assets.program("quad", null));

            _mMs = this.mat(OceanM34Assets.program("ms_frag",
                                ["atmo_core", "atmo_math", "atmo_lut", "atmo_integrate_ms"]),
                            OceanM34Assets.program("quad", null));

            _mSkyLut = this.mat(OceanM34Assets.program("sky_lut_frag",
                                   ["atmo_core", "atmo_math", "atmo_lut", "atmo_phases",
                                    "atmo_ms", "atmo_integrate"]),
                                OceanM34Assets.program("quad", null));

            // --- the sky itself: LUT + sun disc + one cloud deck ---
            _mSky = this.mat(OceanM34Assets.program("sky_frag",
                                 ["atmo_core", "atmo_math", "atmo_lut", "atmo_phases", "atmo_sky"]),
                             OceanM34Assets.program("sky_vert", null));
            _mSky.side = Material.DoubleSide;

            // --- FFT ---
            _mInit = this.mat(OceanM34Assets.program("sim_init", ["sim_common"]),
                              OceanM34Assets.program("quad", null));
            _mEvolve = this.mat(OceanM34Assets.program("sim_evolve", ["sim_common"]),
                                OceanM34Assets.program("quad", null));
            _mFft = this.mat(OceanM34Assets.program("sim_fft", ["sim_common"]),
                             OceanM34Assets.program("quad", null));
            _mAssemble = this.mat(OceanM34Assets.program("sim_assemble", ["sim_common"]),
                                  OceanM34Assets.program("quad", null));

            // --- caustics ---
            _mCaustic = this.mat(OceanM34Assets.program("caustics_frag", null),
                                 OceanM34Assets.program("caustics_vert", null));
            _mCaustic.samplers = { uSlope: "repeat" };

            // --- terrain / water / spray ---
            _mTerrain = this.mat(OceanM34Assets.program("terrain_frag", ["atmo_core", "atmo_sky", "caustics_lookup"]),
                                 OceanM34Assets.program("terrain_vert", null));
            _mTerrain.side = Material.DoubleSide;
            _mTerrain.samplers = { uCaustics: "repeat", uCausticsDeep: "repeat" };

            // No atmospheric includes: the port this file came from lights the body with
            // a flat uSkyAmbient instead of tracing the LUT, and pulling atmo_core in
            // would also force `precision highp sampler2D` to match between stages.
            _mWater = this.mat(OceanM34Assets.program("water_frag", null),
                               OceanM34Assets.program("water_vert", null));
            // Every cascade atlas tiles, so its sampler must repeat; uOpaque and
            // uReflection are screen-sized and clamp. Both stages declare the cascades
            // in the same order, which is what makes one shared sampler unit safe.
            _mWater.samplers = { uDisp0: "repeat", uDisp1: "repeat", uDisp2: "repeat",
                                 uSlope0: "repeat", uSlope1: "repeat", uSlope2: "repeat",
                                 uSlope3: "repeat" };

            _mSpray = this.mat(OceanM34Assets.program("spray_frag", null),
                               OceanM34Assets.program("spray_vert", null));
            _mSpray.samplers = { uDisp0: "repeat", uDisp1: "repeat" };

            // --- underwater + composite ---
            _mLens = this.mat(OceanM34Assets.program("lens_frag", ["water_at"]),
                              OceanM34Assets.program("quad", null));
            _mLens.samplers = { uDisp0: "repeat", uDisp1: "repeat", uDisp2: "repeat" };

            _mShafts = this.mat(OceanM34Assets.program("shafts_frag", ["caustics_lookup"]),
                                OceanM34Assets.program("quad", null));
            _mShafts.samplers = { uCaustics: "repeat", uCausticsDeep: "repeat" };

            _mComposite = this.mat(OceanM34Assets.program("composite_frag", null),
                                   OceanM34Assets.program("quad", null));

            // --- post: bloom pyramid, auto exposure, grade ---
            // The prefilter is the SAME shader with the PREFILTER define, so the soft
            // knee and the Karis weighting exist in exactly one place (PostFX.js builds
            // its two downsample materials the same way).
            _mDownPre = this.mat(OceanM34Assets.program("bloom_down_frag", null),
                                 OceanM34Assets.program("quad", null));
            _mDownPre.defines = { PREFILTER: 1 };
            _mDown = this.mat(OceanM34Assets.program("bloom_down_frag", null),
                              OceanM34Assets.program("quad", null));
            _mUp = this.mat(OceanM34Assets.program("bloom_up_frag", null),
                            OceanM34Assets.program("quad", null));
            _mMeter = this.mat(OceanM34Assets.program("meter_frag", null),
                               OceanM34Assets.program("quad", null));
            _mAdapt = this.mat(OceanM34Assets.program("adapt_frag", null),
                               OceanM34Assets.program("quad", null));
            _mGrade = this.mat(OceanM34Assets.program("grade_frag", null),
                               OceanM34Assets.program("quad", null));

            _mProbe = this.mat(PROBE_FS, OceanM34Assets.program("quad", null));
            _mPresent = this.mat(OceanM34Assets.program("present_frag", null), OceanM34Assets.program("quad", null));
        }

        // ------------------------------------------------------------------
        // Atmosphere: three bakes, once -- and again on every sun/cloud edit, which is
        // why it takes its inputs from `_params` instead of constants. The bake is three
        // full-screen passes at 256x64 / 32x32 / 192x108, so a drag that re-bakes every
        // frame is affordable; that is the trade the reference makes too (`sunDirty` ->
        // applySun() on the next frame).
        // ------------------------------------------------------------------
        private function bakeAtmosphere():void
        {
            this.air(_mTrans);
            this.pass(_mTrans, [_transLut], null);

            // Each bake samples the LUT the previous one wrote, so the bindings are
            // declared here rather than discovered per frame: an unbound sampler in a
            // Metal draw is a validation failure, and the pass then writes nothing.
            this.air(_mMs);
            _mMs.setUniformValue("uTransLut", _transLut);
            this.pass(_mMs, [_msLut], null);

            this.air(_mSkyLut);
            _mSkyLut.setUniformValue("uTransLut", _transLut);
            _mSkyLut.setUniformValue("uMsLut", _msLut);
            _mSkyLut.setUniformValue("uSunMu", _sunY);
            _mSkyLut.setUniformValue("uSunIllum", _sunIllum);
            this.pass(_mSkyLut, [_skyLut], null);
            _fnMips(_skyLut);

            _mSky.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            _mSky.setUniformValue("uSunColor", _sunCol);
            _mSky.setUniformValue("uSunIllum", _sunIllum);
            _mSky.setUniformValue("uCloudCoverage", _params.cloudCoverage);
            _mSky.setUniformValue("uTransLut", _transLut);
            _mSky.setUniformValue("uSkyView", _skyLut);
            // The terrain keeps its own copy of the sun (it is drawn in two scenes, so
            // its uniforms are set once outside the per-frame water path).
            _mTerrain.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            _mTerrain.setUniformValue("uSunColor", _sunCol);
        }

        // Rayleigh / Mie / ozone coefficients in 1/km, Hillaire's measured set. Set per
        // material rather than once, because a uniform the program does not declare is a
        // native-channel ArgumentError: only the bakes that read the LUTs get them.
        private function air(m:ShaderMaterial):void
        {
            m.setUniformValue("uRayleigh", [5.802e-3, 13.558e-3, 33.1e-3]);
            m.setUniformValue("uMie", [3.996e-3, 4.440e-3]);
            m.setUniformValue("uOzone", [0.65e-3, 1.881e-3, 0.085e-3]);
        }

        // ------------------------------------------------------------------
        // Spectrum, once per cascade. Baked on the GPU from a counter hash, so the ocean
        // is a pure function of (texel, cascade, seed): nothing is uploaded, and the two
        // runtimes produce the same sea.
        // ------------------------------------------------------------------
        // Ultra-Water OceanSim.jonswapParams: significant-wave-height scaling from the
        // wind speed and the fetch length (km). Kept as the reference's formula, not as
        // a table of results, so changing the weather changes the sea coherently.
        private function jonswapParams(windSpeed:Number, fetchKm:Number):Array
        {
            var G:Number = 9.81;
            var fetch:Number = fetchKm * 1000.0;
            var alpha:Number = 0.076 * Math.pow((G * fetch) / (windSpeed * windSpeed), -0.22);
            var peakOmega:Number = 22.0 * Math.pow((windSpeed * fetch) / (G * G), -0.33);
            return [alpha, peakOmega];
        }

        private function bakeSpectra():void
        {
            // Ultra-Water derives the JONSWAP alpha and peak frequency from the wind
            // speed and the fetch (OceanSim.jonswapParams), so the sea state is a
            // property of the weather rather than six magic numbers. uSpecA.x is the
            // WAVE SCALE (1), not the wind speed: with the wind speed there the sea
            // came out ~11x too steep, which is what turned the surface into a lattice
            // of near-vertical facets.
            //
            // Directions are degrees in the panel and radians in the spectrum, which is
            // the same conversion the reference makes at its single call site
            // (`MathUtils.degToRad(p.windDirection)`).
            var p:OceanParams = _params;
            var wind:Array = jonswapParams(p.windSpeed, p.fetchKm);
            var swell:Array = jonswapParams(SWELL_SPEED, SWELL_FETCH_KM);
            var specA:Array = [[p.waveScale, p.windDirection * DEG2RAD, p.spreadBlend, 0.25],
                               [p.swellScale, p.swellDirection * DEG2RAD, 1.0, 1.0]];
            var specB:Array = [[wind[0], wind[1], 3.3, 0.04],
                               [swell[0], swell[1], 3.3, 0.04]];
            // cascade cut frequencies: six wavelengths of the next cascade's tile, so
            // the bands overlap instead of leaving a seam
            _mInit.setUniformValue("uLength", [P0, P1, P2, P3]);
            _mInit.setUniformValue("uCut", [2.0 * Math.PI / P1 * 6.0,
                                            2.0 * Math.PI / P2 * 6.0,
                                            2.0 * Math.PI / P3 * 6.0, 0.0]);
            _mInit.setUniformValue("uCapFade", CAP_FADE);
            _mInit.setUniformValue("uSpecA", specA);
            _mInit.setUniformValue("uSpecB", specB);
            _mInit.setUniformValue("uSeed", 20261102);

            var c:int;
            for (c = 0; c < 4; c++)
            {
                _mInit.setUniformValue("uCascade", c);
                this.pass(_mInit, [_h0[c]], null);
            }

            _mEvolve.setUniformValue("uLength", [P0, P1, P2, P3]);
            // Choppiness is a live uniform (see simulate()), but it has to be right
            // before the first assemble, which happens before applyParams() has run
            // on some frames.
            _mAssemble.setUniformValue("uLambda", p.choppiness);
            _mAssemble.setUniformValue("uFoamRecovery", 0.45);
        }

        // ------------------------------------------------------------------
        // Simulation: 18 passes per cascade (1 evolve, 16 butterflies, 1 assemble), 72
        // per frame. Four cascades in one frame is only affordable because each pass is
        // one full-screen draw into a 256x256 target.
        // ------------------------------------------------------------------
        private function simulate(dt:Number):void
        {
            var c:int, s:int, axis:int, sub:int;
            for (c = 0; c < 4; c++)
            {
                _mEvolve.setUniformValue("uH0", _h0[c]);
                _mEvolve.setUniformValue("uTime", _time);
                _mEvolve.setUniformValue("uCascade", c);
                this.pass(_mEvolve, _fftA[c], null);

                var src:Array = _fftA[c];
                var dst:Array = _fftB[c];
                for (axis = 0; axis < 2; axis++)
                {
                    sub = 2;
                    for (s = 0; s < 8; s++)
                    {
                        _mFft.setUniformValue("uIn0", src[0]);
                        _mFft.setUniformValue("uIn1", src[1]);
                        _mFft.setUniformValue("uSub", sub);
                        _mFft.setUniformValue("uVertical", axis);
                        this.pass(_mFft, dst, null);
                        var t:Array = src; src = dst; dst = t;
                        sub = sub * 2;
                    }
                }
                var cur:Object = _disp[c][_cur];
                var prev:Object = _disp[c][1 - _cur];
                _mAssemble.setUniformValue("uIn0", src[0]);
                _mAssemble.setUniformValue("uIn1", src[1]);
                _mAssemble.setUniformValue("uPrev", prev);
                _mAssemble.setUniformValue("uDt", dt);
                // Choppiness is a uniform of the assemble pass, so the panel's slider is
                // live without a re-bake (the reference does the same: `uLambda` is set
                // from params on every update, not only when the spectrum is dirty).
                _mAssemble.setUniformValue("uLambda", _params.choppiness);
                this.pass(_mAssemble, [cur, _slope[c]], null);

                // the water vertex program derives its roughness from the slope chain's
                // coarsest mip, so the chain has to exist before the surface reads it
                _fnMips(cur);
                _fnMips(_slope[c]);
            }
            _cur = 1 - _cur;   // next frame's "previous" is this frame's output
        }

        // ------------------------------------------------------------------
        // Caustics: three splats, one per stored depth. Additive blending IS the
        // accumulation model -- each splat contributes untouched/landed area, and the sum
        // over the map is 1 by construction, so "flat water" reads exactly 1.0.
        // ------------------------------------------------------------------
        private function buildCaustics():void
        {
            _mCaustic.setUniformValue("uSlope", _slope[2]);
            _mCaustic.setUniformValue("uSun", [_sunX, _sunY, _sunZ]);
            _mCaustic.setUniformValue("uCells", CAUSTIC_CELLS);
            _mCaustic.setUniformValue("uLod", 1.0);          // 256 slope texels / 128 cells
            _mCaustic.setUniformValue("uMargin", 0.35);

            _fnSetTargets([_causticNear], null);
            _context.clear(0, 0, 0, 1, 1, 0, 7);
            _mCaustic.setUniformValue("uRes", CAUSTIC_NEAR);
            _mCaustic.setUniformValue("uDepth", 1.5);
            _mCaustic.setUniformValue("uMask", [1.0, 0.0, 0.0]);
            _context.setBlendFactors("one", "one");
            _context.setCulling("frontAndBack");
            _nr.drawNative(_causticMesh, _mCaustic);
            _context.setBlendFactors("one", "zero");
            _context.setCulling("back");
            _fnMips(_causticNear);

            _fnSetTargets([_causticDeep], null);
            _context.clear(0, 0, 0, 1, 1, 0, 7);
            _mCaustic.setUniformValue("uRes", CAUSTIC_DEEP);
            _context.setBlendFactors("one", "one");
            _context.setCulling("frontAndBack");
            _mCaustic.setUniformValue("uDepth", 4.0);
            _mCaustic.setUniformValue("uMask", [1.0, 0.0, 0.0]);
            _nr.drawNative(_causticMesh, _mCaustic);
            _mCaustic.setUniformValue("uDepth", 10.0);
            _mCaustic.setUniformValue("uMask", [0.0, 1.0, 0.0]);
            _nr.drawNative(_causticMesh, _mCaustic);
            _context.setBlendFactors("one", "zero");
            _context.setCulling("back");
            _fnMips(_causticDeep);
        }

        // ------------------------------------------------------------------
        // The frame
        // ------------------------------------------------------------------

        // 60 Hz, not the panel rate: see FRAME_RATE_CAP. Must be an override that
        // returns a constant -- the host calls it from init(), which can run from the
        // base constructor before this class's fields exist.
        override protected function frameRateCap():Number
        {
            return FRAME_RATE_CAP;
        }

        override protected function updateFrame(dt:Number):void
        {
            if (_noChannel) return;
            if (dt > 0.05) dt = 0.05;          // a stalled first frame must not teleport
            if (FREEZE_AT < 0 || _frames < FREEZE_AT) _time += dt;
            // A frozen frame must be bit-identical run to run, so the wave/foam
            // accumulator stops too: uDt is part of the simulation state.
            if (FREEZE_AT >= 0 && _frames >= FREEZE_AT) dt = 0;
            _draws = 0;

            // 1. the camera. A named view installs its own camera (and its own sun,
            //    like the reference's `views`); the cruise animates it until the
            //    pointer takes over; after that OrbitControls owns it (damping too).
            this.applyView();
            this.detectCameraTakeover();
            // 2. the panel. Before simulate(), because a sun edit re-bakes the LUTs the
            //    water and sky read and a wave edit re-bakes the spectra the FFT reads.
            this.applyParams();
            // 3. the sea state's own clock: timeScale scales the SIMULATION, not the
            //    demo's camera loop (the reference does the same: `dt *= timeScale`
            //    inside OceanSim.update).
            var simDt:Number = dt * _params.timeScale;
            if (simDt > 0.2) simDt = 0.2;

            if (this.isFreeCamera()) this.updateOrbit();
            else this.updateCamera();
            this.simulate(simDt);
            this.buildCaustics();
            this.drawReflection();
            this.drawOpaque();
            this.drawWater();
            this.drawSpray();
            this.drawUnderwater();
            this.drawComposite();
            this.drawPost(dt);
            _frames++;
        }

        // ------------------------------------------------------------------
        // Panel parameters -> uniforms / bakes
        // ------------------------------------------------------------------

        // Sun vector + radiance from the panel's elevation/azimuth/intensity. Cheap, so
        // it is called whenever something that depends on it needs it rather than
        // stored.
        private function updateSun():void
        {
            var el:Number = _params.sunElevation * DEG2RAD;
            var az:Number = _params.sunAzimuth * DEG2RAD;
            var ce:Number = Math.cos(el);
            _sunX = ce * Math.sin(az);
            _sunY = Math.sin(el);
            _sunZ = ce * Math.cos(az);
            var k:Number = _params.sunIntensity / SUN_INTENSITY_REF;
            this._sunCol[0] = SUNCOL_REF[0] * k;
            this._sunCol[1] = SUNCOL_REF[1] * k;
            this._sunCol[2] = SUNCOL_REF[2] * k;
            this._sunIllum = Math.PI * SUN_INTENSITY_REF * k;
        }

        // Record the values the bakes were made from. Called after the initial bakes and
        // at the end of applyParams(), so "changed" means "changed since the last bake"
        // and not "differs from a constant".
        private function markParamsApplied():void
        {
            var p:OceanParams = _params;
            _appliedElev = p.sunElevation;
            _appliedAzim = p.sunAzimuth;
            _appliedSunI = p.sunIntensity;
            _appliedCloud = p.cloudCoverage;
            _appliedWindSpeed = p.windSpeed;
            _appliedWindDir = p.windDirection;
            _appliedFetch = p.fetchKm;
            _appliedWaveScale = p.waveScale;
            _appliedSpread = p.spreadBlend;
            _appliedSwellScale = p.swellScale;
            _appliedSwellDir = p.swellDirection;
        }

        // The single reader of the panel's model. Two kinds of work:
        //   * BAKES -- the atmosphere LUTs (sun/cloud) and the JONSWAP spectra (sea
        //     state). Keyed off the last applied values, so a drag re-bakes once per
        //     frame it actually moved.
        //   * UNIFORMS -- water optics, absorption, exposure, choppiness. Pushed every
        //     frame from the model, which is why there is no "dirty" flag to fall out of
        //     sync: the draw* methods read `_params` directly.
        private function applyParams():void
        {
            var p:OceanParams = _params;

            var sunMoved:Boolean = (p.sunElevation != _appliedElev ||
                                    p.sunAzimuth != _appliedAzim ||
                                    p.sunIntensity != _appliedSunI);
            if (sunMoved) this.updateSun();
            var sunDirty:Boolean = sunMoved || (p.cloudCoverage != _appliedCloud);

            var seaMoved:Boolean = (p.windSpeed != _appliedWindSpeed ||
                                    p.windDirection != _appliedWindDir ||
                                    p.fetchKm != _appliedFetch ||
                                    p.waveScale != _appliedWaveScale ||
                                    p.spreadBlend != _appliedSpread ||
                                    p.swellScale != _appliedSwellScale ||
                                    p.swellDirection != _appliedSwellDir);

            this.markParamsApplied();
            this.applyRenderScale();
            this.applyMsaa();
            if (sunDirty) this.bakeAtmosphere();
            if (seaMoved) this.bakeSpectra();
        }

        // QUALITY -> the internal render size. The reference does the same thing through
        // three's setPixelRatio(devicePixelRatio * quality.resolution) and a makeTargets()
        // that disposes the old render targets; here the size-dependent set is _opaque /
        // _water / _spray / _shafts / _refl / _hdr / the bloom pyramid, and the native
        // channel has no texture dispose, so the old set is left to the collector and the
        // panel offers six steps instead of a continuous slider (see OceanParams.SCALES).
        //
        // Below 1.0 the frame is rendered smaller than the window and the grade pass
        // magnifies it: a real speed knob at the cost of sharpness. Above 1.0 the grade
        // pass runs its four-tap box (`uSuper`) and that is this chain's antialiasing.
        // QUALITY -> multisample level of the SCENE targets. Unlike the render scale this
        // needs no rebuild: the level is a companion surface swapped in place
        // (Context3DNative.setRenderTargetSamples), so a switch costs one allocation and
        // keeps every bake, the FFT state and the colour path untouched.
        //
        // WHICH targets: the ones geometry rasterises into -- opaque (sky/terrain/
        // islands), water, spray and the planar reflection -- plus their two depth
        // buffers, because Metal requires ONE sample count per pass. NOT the data
        // targets: the FFT atlases, the metering grid, the 1x1 exposure state and the
        // bloom pyramid are written by full-screen quads, which cover every sample
        // identically; multisampling there would cost memory and a resolve per pass for
        // a bit-identical result (see docs/zh-cn/native-shader.md §9).
        private function applyMsaa():void
        {
            var n:int = _params.msaa;
            if (n == _appliedMsaa) return;
            _appliedMsaa = n;

            var tex:Array = [_opaque, _water, _spray, _refl, _opaqueDepth, _reflDepth];
            var nm:Array = ["opaque", "water", "spray", "reflection", "opaqueDepth", "reflDepth"];
            var bad:String = "";
            for (var i:int = 0; i < tex.length; i++)
            {
                if (tex[i] == null) continue;
                if (_fnSetSamples(tex[i], n) == false && bad == "") bad = nm[i];
            }
            logLine("ocean-m34 msaa " + (n > 1 ? n + "x" : "off") +
                    (bad == "" ? "" : " -- the device refused " + bad + " (see stderr); it stays single-sample"));
        }

        private function applyRenderScale():void
        {
            var s:Number = _params.renderScale;
            if (!(s > 0.05)) s = 1.0;
            if (s == _scaleApplied) return;

            var w:int = Math.round(RW * s);
            var h:int = Math.round(RH * s);
            if (w < 64) w = 64;
            if (h < 64) h = 64;
            if (w == _rw && h == _rh) { _scaleApplied = s; return; }

            _scaleApplied = s;
            _rw = w;
            _rh = h;
            this.makeScreenTargets();
            _fnBackBuffer();
            logLine("ocean-m34 render scale " + s + " -> " + _rw + "x" + _rh +
                    " (drawable " + stage.stageWidth + "x" + stage.stageHeight + ")");
        }

        // ------------------------------------------------------------------
        // Named cameras (the reference's «views» menu)
        // ------------------------------------------------------------------

        private function isAutoCamera():Boolean
        {
            return _params.view == 0;
        }

        // The reference's seven views, same order, same sun per view. They are
        // ONE-SHOT: applied when the selection changes, then left alone (lil-gui's
        // onChange behaves the same way -- it moves the camera once).
        //
        // The geometry is the port's own: the reference walks an islandHeight() field
        // from the origin; this demo has seabedH() and three island cones, and
        // `coast()` below is the same "walk out until the height comes up" rule.
        private function applyView():void
        {
            var v:int = _params.view;
            // The counter is part of the identity: it lets a pick of the entry that is
            // ALREADY selected still re-apply (that is how the camera is handed back
            // from an orbit to the cruise -- see OceanParams.viewReq).
            if (v == _viewApplied && _params.viewReq == _viewReqApplied) return;
            _viewApplied = v;
            _viewReqApplied = _params.viewReq;

            // A view is an instruction about WHO OWNS the camera: it takes it back
            // from OrbitControls and drops any damped motion the last gesture left
            // behind, so the new pose is not nudged by a previous drag.
            _freeCam = false;
            _haveCruisePose = false;
            this.clearOrbitDamping();

            if (v == 0)
            {
                // Back to the loop: it re-installs the camera every frame anyway, and
                // the sun is left as the user set it (a view switch is not a reset).
                return;
            }

            var p:OceanParams = _params;
            var bearing:Number, c:Array, b:Number;
            if (v == 1)             // Golden hour
            {
                this.setSunFromView(3.5, 205.0);
                bearing = p.sunAzimuth * DEG2RAD;
                c = this.coast(p.sunAzimuth + 18.0);
                // relative to the SHORE POINT, offset along the sun's bearing (the
                // reference's `c.x + cos(b)*120`), so the sun road is in frame
                this.placeCamera(c[0] + Math.cos(bearing) * 120.0, 5.0,
                                 c[1] + Math.sin(bearing) * 120.0,
                                 c[0] + Math.cos(bearing) * 400.0, 0.0,
                                 c[1] + Math.sin(bearing) * 400.0);
            }
            else if (v == 2)        // Breakers
            {
                this.setSunFromView(22.0, 205.0);
                c = this.coast(p.sunAzimuth + 1.9 / DEG2RAD);
                // stand on the shore, 35 m back and 40 m to the side, looking along it
                b = c[2] * DEG2RAD;
                this.placeCamera(c[0] + Math.cos(b) * 35.0 + Math.sin(b) * 40.0, 3.2,
                                 c[1] + Math.sin(b) * 35.0 - Math.cos(b) * 40.0,
                                 c[0] - Math.sin(b) * 30.0, 0.0,
                                 c[1] + Math.cos(b) * 30.0);
            }
            else if (v == 3)        // Lagoon
            {
                this.setSunFromView(52.0, 205.0);
                c = this.coast(p.sunAzimuth + 180.0);
                // inside the lagoon, looking out at the island it belongs to
                this.placeCamera(c[0] * 0.86, 28.0, c[1] * 0.86,
                                 c[0] * 1.25, 0.0, c[1] * 1.25);
            }
            else if (v == 4)        // Open ocean
            {
                this.setSunFromView(14.0, 205.0);
                b = p.sunAzimuth * DEG2RAD + 0.5;
                this.placeCamera(Math.cos(b) * 1500.0, 9.0, Math.sin(b) * 1500.0,
                                 Math.cos(b) * 2400.0, 0.0, Math.sin(b) * 2400.0 + 600.0);
            }
            else if (v == 5)        // Aerial
            {
                this.setSunFromView(30.0, 205.0);
                this.placeCamera(900.0, 420.0, 900.0, 0.0, 0.0, 0.0);
            }
            else                    // Underwater
            {
                this.setSunFromView(48.0, 205.0);
                b = p.sunAzimuth * DEG2RAD + Math.PI + 0.3;
                var r:Number = 200.0;
                while (r < 1000.0 && this.seabedH(Math.cos(b) * r, Math.sin(b) * r) > -9.0) r = r + 2.0;
                var x:Number = Math.cos(b) * r;
                var z:Number = Math.sin(b) * r;
                this.placeCamera(x, -3.2, z,
                                 x - Math.cos(b) * 25.0, -1.8, z - Math.sin(b) * 25.0);
            }
            _underwater = _camera.position.y < 0.0;
            // The view is the model's SECOND writer: it moves the sun, which the
            // panel's sliders display. A widget-driven change re-describes itself; this
            // one has to say so, or the elevation slider keeps pointing at the previous
            // view's sun until the next click anywhere (measured: Lagoon selected, sun
            // 52 deg applied, slider still at 70).
            if (_ui != null) _ui.invalidate(Dirty.ALL);
        }

        // A view carries a sun, exactly like the reference's `setSun(...)` calls inside
        // each view. The bakes are picked up by applyParams() on the same frame.
        private function setSunFromView(elevation:Number, azimuth:Number):void
        {
            _params.sunElevation = elevation;
            _params.sunAzimuth = azimuth;
        }

        private function placeCamera(x:Number, y:Number, z:Number,
                                     tx:Number, ty:Number, tz:Number):void
        {
            _camera.position.set(x, y, z);
            _camera.lookAt(tx, ty, tz);
            _camera.updateMatrixWorld(true);
            _camera.updateMatrixWorldInverse();
            // OrbitControls orbits around the view's own aim from now on. The reference
            // writes both in the same breath in every view (main.js:165-208:
            // `camera.position.set(...)` + `controls.target.set(...)`), and that pairing
            // is what makes an orbit after a view pivot on the subject instead of on
            // wherever the previous view happened to look.
            if (_controls != null) _controls.target.set(tx, ty, tz);
        }

        // Walk out along a bearing until the seabed rises above the waterline: the
        // reference's `coast()`, against this demo's height field. Returns
        // [x, z, bearingDeg].
        //
        // WHY IT SWEEPS. The reference's height field is ONE island, so a ray in
        // almost any direction meets its shore and the single-ray loop is enough.
        // This demo's field is a lagoon with three separate cones (r 70..120 m at
        // 200..400 m), so the requested bearing usually misses all three: the loop
        // then returns its 800 m limit, which put the Lagoon view 725 m out over open
        // water with no land in frame at all (measured in the window, not inferred).
        // So the search widens the bearing in 5 deg steps, nearest deviation first,
        // and returns the bearing it actually hit -- the callers that place a camera
        // relative to the shore use THAT bearing (c[2]), not the one they asked for.
        //
        // Cost: worst case 73 rays x 350 steps, and only when a view is selected.
        private function coast(bearingDeg:Number):Array
        {
            var delta:int = 0;
            while (delta <= 180)
            {
                var side:int = 1;
                while (side >= -1)
                {
                    var a:Number = (bearingDeg + delta * side) * DEG2RAD;
                    var r:Number = 100.0;
                    while (r < 800.0 && this.seabedH(Math.cos(a) * r, Math.sin(a) * r) <= 0.0)
                    {
                        r = r + 2.0;
                    }
                    if (r < 800.0) return [Math.cos(a) * r, Math.sin(a) * r, bearingDeg + delta * side];
                    if (delta == 0) break;   // +0 and -0 are the same ray
                    side = side - 2;
                }
                delta = delta + 5;
            }
            // No land anywhere: the reference's own fallback (its limit), so a view
            // still gets a finite camera instead of a NaN.
            var f:Number = bearingDeg * DEG2RAD;
            return [Math.cos(f) * 800.0, Math.sin(f) * 800.0, bearingDeg];
        }

        // A 26 s loop that spends 10 s of it UNDER the surface, so both halves of the
        // post effect are exercised by every run without a key press. A camera that never
        // crosses y=0 would leave the meniscus, the shafts and the Snell window as dead
        // code that no run ever proves.
        private function updateCamera():void
        {
            var phase:Number = _time % 26.0;
            var dist:Number, height:Number;
            if (phase < 12.0)
            {
                dist = 150.0 - phase * 3.0;
                // Reference eye height: 5 m is what makes the horizon sit low in frame
                // and the near water occupy the bottom half.
                height = 5.0 + Math.sin(phase * 0.6) * 0.5;
            }
            else
            {
                dist = 110.0;
                height = -4.5 - Math.sin((phase - 12.0) * 0.35) * 1.5;
            }
            _underwater = height < 0.0;
            // Orbit just OFF the sun's own bearing, looking back towards the island: the
            // reference's golden-hour camera does the same, and it is why the water shows
            // a glitter road. Orbiting away from the sun gives a dark, mirror-like sea
            // with no highlights at all, however correct the shading maths is.
            var a:Number = _params.sunAzimuth * DEG2RAD + Math.PI + 0.04 + Math.sin(phase * 0.09) * 0.05;
            _camera.position.set(Math.sin(a) * dist, height, Math.cos(a) * dist);
            var aimY:Number = _underwater ? 8.0 : 5.2;
            _camera.lookAt(0, aimY, 0);   // near level: horizon just above centre
            _camera.updateMatrixWorld(true);
            _camera.updateMatrixWorldInverse();
            // Hand the same aim to the control, so a drag that interrupts the cruise
            // pivots around the island the cruise was looking at.
            if (_controls != null) _controls.target.set(0, aimY, 0);
            // The pose this frame wrote. detectCameraTakeover compares against it.
            _cruisePos.copy(_camera.position);
            _cruiseQuat.copy(_camera.quaternion);
            _haveCruisePose = true;
        }

        // ---- pointer-owned camera (OrbitControls) -------------------------

        // True when OrbitControls, not the cruise, writes the camera this frame: a
        // named view is already static (the pointer may orbit around it), and the
        // cruise steps aside the moment a gesture moves the camera.
        private function isFreeCamera():Boolean
        {
            return _params.view != 0 || _freeCam;
        }

        // THE CRUISE GIVES WAY TO THE POINTER. Nothing else writes the camera while the
        // cruise runs -- a sun slider changes what the NEXT cruise frame will write,
        // not where the camera is now -- so a pose that differs from the one written
        // last frame can only be OrbitControls answering a drag or a wheel. A plain
        // click moves nothing and therefore does not steal the camera (three.js: no
        // move, no change).
        //
        // Why not listen for MOUSE_DOWN instead: the press alone is not a decision.
        // This way "hold the button and let go without moving" leaves the cruise
        // running, which is what the web does too (its menu is not a mode switch and
        // its camera does not stop because you clicked the canvas).
        private function detectCameraTakeover():void
        {
            if (_freeCam || !this.isAutoCamera() || !_haveCruisePose || _controls == null) return;
            var moved:Boolean =
                _camera.position.distanceToSquared(_cruisePos) > 1e-8 ||
                8.0 * (1.0 - _camera.quaternion.dot(_cruiseQuat)) > 1e-6;
            if (!moved) return;
            _freeCam = true;
            logLine("ocean-m34 camera: cruise released to OrbitControls");
        }

        // One frame of pointer-owned camera: the control's own update (it also applies
        // damping), then the reference's clampCamera -- free to dive, but not through
        // the seabed (main.js:417-421).
        private function updateOrbit():void
        {
            if (_controls == null) return;
            _controls.update();
            var floorY:Number = this.seabedH(_camera.position.x, _camera.position.z) + CAMERA_FLOOR;
            if (_camera.position.y < floorY)
            {
                _camera.position.y = floorY;
                // Re-aim after the clamp: update() aimed from the pre-clamp position,
                // and a camera that is 5 m higher is no longer looking at the target.
                _camera.lookAt(_controls.target.x, _controls.target.y, _controls.target.z);
            }
            _camera.updateMatrixWorld(true);
            _camera.updateMatrixWorldInverse();
            _underwater = _camera.position.y < 0.0;
        }

        // Zero the control's pending damping without adding API: with damping off, one
        // update() applies nothing and clears both accumulators (OrbitControls.update).
        // Used when a view takes the camera back, so a drag that was still coasting
        // does not add itself to the new pose.
        private function clearOrbitDamping():void
        {
            if (_controls == null) return;
            var damping:Boolean = _controls.enableDamping;
            _controls.enableDamping = false;
            _controls.update();
            _controls.enableDamping = damping;
        }

        // Mirror about y=0: multiply the world matrix by diag(1,-1,1) on the left, which
        // negates the world-Y row. Reflecting the POSITION only is the classic planar
        // reflection bug: the mirrored camera keeps its original orientation and the
        // reflection rotates the wrong way.
        private function drawReflection():void
        {
            // Reflections off is a real switch, not a black overlay: the pass (two
            // draws + a mip chain over a half-res target) is skipped and the water
            // samples a 1x1 black stand-in -- the program always samples uReflection,
            // and an unbound sampler in a Metal draw is a validation failure that
            // writes nothing.
            if (!_params.reflections) return;

            var e:Vector.<Number> = _camera.matrixWorld.elements;
            var me:Vector.<Number> = _mirror.matrix.elements;
            var r:int, c:int;
            for (c = 0; c < 4; c++)
            {
                for (r = 0; r < 4; r++)
                {
                    var v:Number = e[c * 4 + r];
                    me[c * 4 + r] = (r == 1) ? -v : v;
                }
            }
            _mirror.matrixWorldNeedsUpdate = true;
            _mirror.projectionMatrix.copy(_camera.projectionMatrix);
            _mirror.projectionMatrixInverse.copy(_camera.projectionMatrixInverse);

            _fnSetTargets([_refl], _reflDepth);
            // Premultiplied, alpha = coverage: the water samples this blurred, and a mip
            // of black would drag the reflection to black instead of to the sky.
            _context.clear(0, 0, 0, 0, 1, 0, 7);
            _mSky.setUniformValue("uAlpha", 0.0);
            _mTerrain.setUniformValue("uReflPass", 1.0);
            _nr.render(_reflScene, _mirror);
            _mSky.setUniformValue("uAlpha", 1e4);
            _mTerrain.setUniformValue("uReflPass", 0.0);
            _fnMips(_refl);
            _draws = _draws + _nr.drawCalls;
        }

        // Sky + terrain into _opaque. Alpha is the pass's linear view depth: the water and
        // composite passes read it as "what is behind me".
        private function drawOpaque():void
        {
            _fnSetTargets([_opaque], _opaqueDepth);
            _context.clear(0, 0, 0, 0, 1, 0, 7);
            // The sky's per-pixel world ray comes from the camera basis, not from an
            // inverted view-projection: `inverse(mat4)` in the native path produced NaN
            // rays, and a black sky with a working forced-constant sky is exactly what a
            // NaN ray looks like. tan(fov/2) at unit depth keeps it a scale-and-add.
            var ce:Vector.<Number> = _camera.matrixWorld.elements;
            // tan(fov/2) on both axes, straight out of the projection matrix (p[5] = 1/tanY,
            // p[0] = 1/tanX): no camera subclass cast, and it follows any fov change.
            var pe:Vector.<Number> = _camera.projectionMatrix.elements;
            var tanY:Number = 1.0 / pe[5];
            var tanX:Number = 1.0 / pe[0];
            _mSky.setUniformValue("uRayFwd", [-ce[8], -ce[9], -ce[10]]);
            _mSky.setUniformValue("uRayRight", [ce[0] * tanX, ce[1] * tanX, ce[2] * tanX]);
            _mSky.setUniformValue("uRayUp", [ce[4] * tanY, ce[5] * tanY, ce[6] * tanY]);
            // NOT uAbsorption/uScatterColor here: terrain.frag DECLARES both and uses
            // neither (the seabed is absorbed by the water and composite passes, which
            // read it as a texture), so the reflection drops them and setting them here
            // only earned one "material.uniforms carries 'uAbsorption' but the program
            // does not declare it" warning per run. The warning was right, the code was
            // not -- and the panel's water colour still reaches the seabed, through the
            // passes that actually do the absorbing.
            _nr.render(_scene, _camera);
            _draws = _draws + _nr.drawCalls;
        }

        private function drawWater():void
        {
            var m:ShaderMaterial = _mWater;
            var cur:Array = [_disp[0][_cur], _disp[1][_cur], _disp[2][_cur], _disp[3][_cur]];
            m.setUniformValue("uDisp0", cur[0]);
            m.setUniformValue("uDisp1", cur[1]);
            m.setUniformValue("uDisp2", cur[2]);
            m.setUniformValue("uSlope0", _slope[0]);
            m.setUniformValue("uSlope1", _slope[1]);
            m.setUniformValue("uSlope2", _slope[2]);
            m.setUniformValue("uSlope3", _slope[3]);
            m.setUniformValue("uOpaque", _opaque);
            m.setUniformValue("uReflection", this.reflectionTexture());
            m.setUniformValue("uLength", [P0, P1, P2, P3]);
            // Roughness/refraction/distortion/fog straight from OceanSurface.js: 0.02 is
            // the reference's base roughness (0.055 was smooth enough to hide the sun's
            // road), and 1/18000 is its aerial-perspective density. The first three are
            // panel parameters (the web GUI's Water folder); the fourth is not exposed
            // there either.
            var p:OceanParams = _params;
            m.setUniformValue("uOptics", [p.roughness, p.refraction, p.reflectionDistort,
                                          1.0 / 18000.0]);
            m.setUniformValue("uFoam", [p.foamBias, p.foamScale, 0.35, 0.85]);
            m.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            m.setUniformValue("uSunColor", _sunCol);
            m.setUniformValue("uAbsorption", p.absorption);
            m.setUniformValue("uScatterColor", p.scatter);
            // The original port lights the body with one flat sky colour; the LUT-driven
            // version that replaced it is not in this file any more (see the header of
            // assets/ocean/water.frag), so the uniform stays a constant.
            m.setUniformValue("uSkyAmbient", [0.32, 0.42, 0.52]);
            m.setUniformValue("uGlint", p.glint);
            var f:Vector.<Number> = _camera.matrixWorld.elements;
            m.setUniformValue("uCamForward", [-f[8], -f[9], -f[10]]);
            m.setUniformValue("uCellStep", 6.283185307179586 / 320.0);
            m.setUniformValue("uWind", p.windSpeed);

            // clear alpha 1 = "no water here": the tag the composite keys on. 0 is the
            // underside and 2 the top, so a cleared pixel cannot be read as a surface.
            if (TRACE_PROGRAMS && !_dbgWaterDescribed)
            {
                _dbgWaterDescribed = true;
                logLine("WATER PROGRAM:\n" + _nr.describeProgram(m));
            }
            _fnSetTargets([_water], null);
            _context.clear(0, 0, 0, 1, 1, 0, 7);
            _context.setCulling("frontAndBack");   // gl_FrontFacing must be able to differ
            _nr.drawNative(_waterMesh, m);
            _context.setCulling("back");
            _draws++;
        }

        private function drawSpray():void
        {
            var m:ShaderMaterial = _mSpray;
            m.setUniformValue("uDisp0", _disp[0][_cur]);
            m.setUniformValue("uDisp1", _disp[1][_cur]);
            m.setUniformValue("uLength", [P0, P1, P2, P3]);
            m.setUniformValue("uSpray", [1.5, 2.6, 4.2, 0.9]);
            m.setUniformValue("uSprayBox", [_camera.position.x, _camera.position.z, 260.0, 0.55]);
            m.setUniformValue("uWind", [0.7, 0.4]);
            m.setUniformValue("uTime", _time);
            m.setUniformValue("uSprayColor", [0.85, 0.92, 1.0]);

            _fnSetTargets([_spray], null);
            _context.clear(0, 0, 0, 0, 1, 0, 7);
            _context.setBlendFactors("one", "one");
            _context.setCulling("frontAndBack");
            _nr.drawNative(_sprayMesh, m);
            _context.setBlendFactors("one", "zero");
            _context.setCulling("back");
            _draws++;
        }

        // Lens (64x36) decides per pixel whether the near plane is submerged; shafts
        // (quarter res) accumulate the sun along the view ray. Both are skipped when the
        // camera is high above the water, which is most of the loop.
        private function drawUnderwater():void
        {
            var camY:Number = _camera.position.y;
            _mComposite.setUniformValue("uActive", 0.0);
            _mComposite.setUniformValue("uFull", 0.0);
            if (camY > 5.0) return;

            _invProj.copy(_camera.projectionMatrix).invert();
            _mLens.setUniformValue("uInvProj", _invProj.elements);
            _mLens.setUniformValue("uCamWorld", _camera.matrixWorld.elements);
            _mLens.setUniformValue("uDisp0", _disp[0][_cur]);
            _mLens.setUniformValue("uDisp1", _disp[1][_cur]);
            _mLens.setUniformValue("uDisp2", _disp[2][_cur]);
            _mLens.setUniformValue("uLength", [P0, P1, P2, P3]);
            this.pass(_mLens, [_lens], null);
            _mComposite.setUniformValue("uActive", 1.0);
            _mComposite.setUniformValue("uFull", camY < -1.5 ? 1.0 : 0.0);

            if (camY > -1.5) return;               // straddling: absorption is per pixel

            var m:ShaderMaterial = _mShafts;
            m.setUniformValue("uInvProj", _invProj.elements);
            m.setUniformValue("uCamWorld", _camera.matrixWorld.elements);
            m.setUniformValue("uColor", _opaque);
            m.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            m.setUniformValue("uAbsorption", _params.absorption);
            // Turbidity belongs to THIS pass: it is the extinction the shaft march
            // integrates, so a muddy column both kills the god rays and fogs from the
            // camera out. (It was left as a constant here after the panel landed, and
            // the self-check's shaft statistics stayed identical at every turbidity --
            // that is what caught it.)
            m.setUniformValue("uUnder", [_params.scattering, _params.shafts,
                                         _params.shaftRange, 0.0]);
            m.setUniformValue("uFrame", _frames % 64);
            m.setUniformValue("uCaustics", _causticNear);
            m.setUniformValue("uCausticsDeep", _causticDeep);
            this.pass(m, [_shafts], null);
        }

        // Assemble + absorb into `_hdr` (LINEAR). The grade moved out: bloom and auto
        // exposure both need values before the tone map, and a pass cannot read the
        // target it is writing.
        private function drawComposite():void
        {
            var m:ShaderMaterial = _mComposite;
            m.setUniformValue("uColor", _opaque);
            m.setUniformValue("uWater", _water);
            m.setUniformValue("uSpray", _spray);
            m.setUniformValue("uShafts", _shafts);
            m.setUniformValue("uLens", _lens);
            m.setUniformValue("uAbsorption", _params.absorption);
            m.setUniformValue("uScatterColor", _params.scatter);
            m.setUniformValue("uSunColor", _sunCol);
            // Turbidity and the shaft strength are panel state now (UNDERWATER
            // section); the fourth word is unused by the pass.
            m.setUniformValue("uUnder", [_params.scattering, _params.shafts,
                                         _params.shaftRange, 0.0]);

            if (TRACE_PROGRAMS && !_dbgDescribed)
            {
                _dbgDescribed = true;
                logLine("COMPOSITE PROGRAM:\n" + _nr.describeProgram(m));
            }
            // Straight into the HDR target, which is an ordinary render target and so
            // agrees with the row convention every other offscreen pass uses. It is
            // grade.frag (drawPost) that writes the DRAWABLE, and it is why the earlier
            // "_final + copy" experiment disagreed with the window: the back buffer is
            // the only surface whose row order differs, so it must be written once, by
            // the pass that also does the sRGB encode.
            this.pass(m, [_hdr], null);
        }

        // ------------------------------------------------------------------
        // Post: metered exposure, bloom, tone map, grade -- the reference's PostFX.js
        // reduced to the passes this port has a backer for. Everything stays on the
        // GPU: the adapted exposure lives in a 1x1 float target and is read by the
        // grade pass with texelFetch, so a frame never stalls on a readback.
        // ------------------------------------------------------------------
        private function drawPost(dt:Number):void
        {
            var p:OceanParams = _params;
            var i:int;
            var key:Number = Math.max(p.keyValue, 1e-4);
            var lo:Number = Math.min(p.minExposure, p.maxExposure);
            var hi:Number = Math.max(p.minExposure, p.maxExposure);
            if (lo < 1e-4) lo = 1e-4;

            // Underwater exposure compensation, eased like the reference's `uwComp`.
            var want:Number = _underwater ? p.underwaterExposure : 1.0;
            var ease:Number = dt * 3.0;
            if (ease > 1.0) ease = 1.0;
            _uwComp = _uwComp + (want - _uwComp) * ease;

            // --- 1. meter the frame, then adapt the 1x1 state ------------------
            if (p.autoExposure)
            {
                var f:int = _frames % 256;
                // R2 sequence: every pair of consecutive frames fills the grid more
                // evenly than a random jitter would, and it never repeats early.
                _mMeter.setUniformValue("uSrc", _hdr);
                _mMeter.setUniformValue("uJitter",
                    [frac(f * 0.7548776662466927), frac(f * 0.5698402909980532)]);
                this.pass(_mMeter, [_meter], null);

                _mAdapt.setUniformValue("uSrc", _meter);
                _mAdapt.setUniformValue("uPrev", _adapt[_adaptCur]);
                _mAdapt.setUniformValue("uK",
                    [_adaptSnap ? 1.0 : 1.0 - Math.exp(-dt * ADAPT_UP),
                     _adaptSnap ? 1.0 : 1.0 - Math.exp(-dt * ADAPT_DOWN)]);
                // keep the state inside the range the exposure clamp can show, so it
                // never winds up during a long underwater stretch
                _mAdapt.setUniformValue("uRange",
                    [Math.log(key / hi) * 1.4426950408889634,
                     Math.log(key / lo) * 1.4426950408889634]);
                _adaptCur = 1 - _adaptCur;
                this.pass(_mAdapt, [_adapt[_adaptCur]], null);
                _adaptSnap = false;
            }
            else
            {
                // the state goes stale while auto is off; snap when it comes back
                _adaptSnap = true;
            }

            // --- 2. bloom pyramid ---------------------------------------------
            // Skipped entirely at strength 0 (the reference does the same): six
            // downsamples plus five upsamples cost more than this demo's water pass.
            if (p.bloomStrength > 0.0)
            {
                var th:Number = p.bloomThreshold;
                var knee:Number = Math.max(th * 0.5, 1e-4);
                _mDownPre.setUniformValue("uSrc", _hdr);
                _mDownPre.setUniformValue("uTexel", [1.0 / _rw, 1.0 / _rh]);
                _mDownPre.setUniformValue("uCurve", [th - knee, 2.0 * knee, 0.25 / knee, th]);
                _mDownPre.setUniformValue("uClamp", p.bloomClamp);
                this.pass(_mDownPre, [_bloom[0]], null);

                for (i = 1; i < BLOOM_LEVELS; i++)
                {
                    _mDown.setUniformValue("uSrc", _bloom[i - 1]);
                    _mDown.setUniformValue("uTexel", [1.0 / _bloomW[i - 1], 1.0 / _bloomH[i - 1]]);
                    this.pass(_mDown, [_bloom[i]], null);
                }
                for (i = BLOOM_LEVELS - 2; i >= 0; i--)
                {
                    _mUp.setUniformValue("uSrc", _bloom[i + 1]);
                    _mUp.setUniformValue("uTexel", [1.0 / _bloomW[i + 1], 1.0 / _bloomH[i + 1]]);
                    // additive: the pyramid accumulates downwards, so the wide dim tail
                    // comes from the small levels instead of replacing them
                    _fnSetTargets([_bloom[i]], null);
                    _context.setBlendFactors("one", "one");
                    _context.setCulling("frontAndBack");
                    _nr.drawNative(_quad, _mUp);
                    _context.setCulling("back");
                    _context.setBlendFactors("one", "zero");
                    _draws++;
                }
            }

            // --- 3. grade into the back buffer --------------------------------
            _mGrade.setUniformValue("uHdr", _hdr);
            // Both samplers must stay bound even when their pass was skipped: an
            // unbound sampler in a Metal draw is a validation failure that writes
            // nothing (measured in this demo, not assumed).
            _mGrade.setUniformValue("uBloom", _bloom[0]);
            _mGrade.setUniformValue("uExpo", _adapt[_adaptCur]);
            _mGrade.setUniformValue("uExposure", p.exposure * _uwComp);
            _mGrade.setUniformValue("uAuto", p.autoExposure ? 1.0 : 0.0);
            _mGrade.setUniformValue("uExpoRange", [key, lo, hi]);
            _mGrade.setUniformValue("uBloomStrength", p.bloomStrength);
            _mGrade.setUniformValue("uContrast", p.contrast);
            _mGrade.setUniformValue("uSaturation", p.saturation);
            _mGrade.setUniformValue("uVignette", p.vignette);
            // The drawable's texel size drives the four-tap box, and the box is only
            // wanted when the internal frame is LARGER than the drawable -- at scale <= 1
            // the grade is a magnifier, and four taps there would cost three reads for a
            // filter bilinear already does.
            _mGrade.setUniformValue("uDstTexel", [1.0 / stage.stageWidth, 1.0 / stage.stageHeight]);
            _mGrade.setUniformValue("uSuper", _rw > stage.stageWidth ? 1.0 : 0.0);

            _fnBackBuffer();
            _context.clear(0, 0, 0, 1);
            _context.setCulling("frontAndBack");
            _nr.drawNative(_quad, _mGrade);
            _context.setCulling("back");
            _draws++;

            if (DUMP_FRAME && _frames == DUMP_AT && !_dumped)
            {
                _dumped = true;
                logLine("dbg: uw=" + _underwater + " uwComp=" + _uwComp + " expo=" + p.exposure +
                        " auto=" + p.autoExposure + " bloom=" + p.bloomStrength +
                        " contrast=" + p.contrast + " sat=" + p.saturation + " vig=" + p.vignette);
                this.dumpFrame("../../temp/m34-frame.ppm");
            }
            if (DUMP_FRAME && _frames == DUMP_AT + 1)
            {
                this.dumpSource(_hdr, "../../temp/m34-hdr.ppm");
            }
        }

        private static function frac(v:Number):Number
        {
            var f:Number = v - Math.floor(v);
            return f;
        }

        // Read the composed frame back with drawToBitmapData and write it as a binary
        // PPM. Development only: it allocates a full-resolution bitmap and touches the
        // filesystem. The back buffer is the only frame worth judging -- a window
        // capture goes through the compositor and can disagree.
        private function dumpFrame(path:String):void
        {
            this.dumpSource(null, path);
        }

        // Same present/readback pipeline for any source texture, so a pass's own
        // contents can be compared against what the window is actually showing.
        private function dumpSource(src:Object, path:String):void
        {
            if (src != null)
            {
                _mPresent.setUniformValue("uSrc", src);
                _fnBackBuffer();
                _context.clear(0, 0, 0, 1);
                _context.setCulling("frontAndBack");
                _nr.drawNative(_quad, _mPresent);
                _context.setCulling("back");
            }

            var w:int = stage.stageWidth;
            var h:int = stage.stageHeight;
            var bmd:BitmapData = new BitmapData(w, h, false, 0x000000);
            _context.drawToBitmapData(bmd);

            // getPixel, not getPixels: the bulk accessor is not implemented on this
            // runtime (#2004). Full resolution: half-size turned antialiasing artefacts
            // into "detail" and hid exactly what the dump is for.
            var dw:int = w;
            var dh:int = h;
            var out:ByteArray = new ByteArray();
            out.writeUTFBytes("P6\n" + dw + " " + dh + "\n255\n");
            var x:int, y:int;
            for (y = 0; y < dh; y++)
            {
                for (x = 0; x < dw; x++)
                {
                    var c:int = bmd.getPixel(x, y);
                    out.writeByte((c >> 16) & 0xFF);
                    out.writeByte((c >> 8) & 0xFF);
                    out.writeByte(c & 0xFF);
                }
            }
            try
            {
                var f:File = File.applicationDirectory.resolvePath(path);
                var fs:FileStream = new FileStream();
                fs.open(f, FileMode.WRITE);
                fs.writeBytes(out);
                fs.close();
            }
            catch (e:Error)
            {
                logLine("dbg: write failed " + e.errorID + " " + e.message);
            }
            logLine("ocean-m34 dumped " + w + "x" + h + " to " + path);
        }

        // Every offscreen draw goes through here: bind the target(s), draw the quad.
        private function pass(material:ShaderMaterial, colors:Array, depth:Object):void
        {
            if (colors != null) _fnSetTargets(colors, depth);
            _context.setCulling("frontAndBack");
            _nr.drawNative(_quad, material);
            _context.setCulling("back");
            _draws++;
        }

        // ------------------------------------------------------------------
        // Self-checks. Every one reads a target back: the frame can look plausible while
        // one pass writes black, and "the sky is dark blue" is not evidence that the
        // atmosphere LUT was baked.
        // ------------------------------------------------------------------
        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_noChannel)
            {
                if (_frames++ > 0) return;
                logLine("ocean-m34 NO-CHANNEL: " + RendererFactory.describe());
                logLine("ocean-m34 OK (channel absent, reported loudly; --features native-shader enables it)");
                NativeApplication.nativeApplication.exit();
                return;
            }

            if (!CHECK_ENABLED) return;
            if (!_checked && _frames > 4)
            {
                this.checkAbove();
                return;
            }
            if (_checked && !_checkedBelow && _underwater)
            {
                _belowFrames++;
                if (_belowFrames > 4) this.checkBelow();
                return;
            }
            if (_checkedBelow)
            {
                if (_quitAt < 0) _quitAt = _frames + 100000;
                if (_frames >= _quitAt) NativeApplication.nativeApplication.exit();
            }
        }

        // The HUD's CALLS / TRIS tiles. This demo issues ~86 draws (72 FFT butterflies
        // + caustics + bakes) and two whole scene renders per frame, so the renderer's
        // own tally -- which every render() resets -- would report `1`. `_draws` is a
        // frame-accumulated count instead (reset at the top of updateFrame).
        override protected function frameDrawCalls():int
        {
            return _draws;
        }

        override protected function frameTriangles():int
        {
            // The scene renders report their own triangles; the full-screen passes are
            // 2 each. Good enough for a bar gauge, and it is not a fake pixel count.
            return (_renderer == null ? 0 : _renderer.triangles) + _draws * 2;
        }

        private function checkAbove():void
        {
            _checked = true;

            var h:Object = this.readStats(_disp[0][_cur], 1, 0.05, 0.5);
            logLine("ocean-m34 displacement (600 m cascade): " + h["lo"].toFixed(2) + ".." +
                h["hi"].toFixed(2) + " m, mean " + h["abs"].toFixed(3) + " m");
            this.verdict("four-cascade FFT gives a varying surface", (h["hi"] - h["lo"]) > 0.6);

            var s:Object = this.readStats(_skyLut, 0, 0.05, 0.0);
            logLine("ocean-m34 sky-view LUT: " + s["lo"].toFixed(3) + ".." + s["hi"].toFixed(3) +
                ", mean " + s["mean"].toFixed(3));
            this.verdict("atmosphere LUT bake produced radiance", (s["hi"] - s["lo"]) > 0.01);

            var r:Object = this.readStats(_refl, 2, 0.1, 0.0);
            logLine("ocean-m34 planar reflection (.b): " + r["lo"].toFixed(3) + ".." +
                r["hi"].toFixed(3) + ", mean " + r["mean"].toFixed(3));
            this.verdict("mirrored scene rendered into the reflection target",
                (r["hi"] - r["lo"]) > 0.01);

            var k:Object = this.readStats(_causticNear, 0, 0.35, 0.0);
            logLine("ocean-m34 caustics: " + k["lo"].toFixed(3) + ".." + k["hi"].toFixed(3) +
                ", mean " + k["mean"].toFixed(3) + " (1.0 == flat water)");
            this.verdict("caustic splat accumulated a non-uniform intensity",
                (k["hi"] - k["lo"]) > 0.05);

            var w:Object = this.readStats(_water, 3, 0.5, 0.0);
            logLine("ocean-m34 water tag: " + w["top"].toFixed(1) + "% top side, " +
                w["back"].toFixed(1) + "% underside, " + w["none"].toFixed(1) + "% open");
            this.verdict("the surface pass covered the lower frame", w["top"] > 20.0);
        }

        private function checkBelow():void
        {
            _checkedBelow = true;
            // In-scatter is a physically small number (the 16-step march over ~40 m of
            // 0.055/m water lands around 0.01), so the readback gain has to be large
            // enough to see it at all: at gain 1 the whole target quantises to zero.
            var sh:Object = this.readStats(_shafts, 0, 8.0, 0.0);
            logLine("ocean-m34 underwater shafts: " + sh["lo"].toFixed(4) + ".." +
                sh["hi"].toFixed(4) + ", mean " + sh["mean"].toFixed(4) + " (gain 8)");
            this.verdict("sun shafts scatter under the surface", sh["mean"] > 0.0005);

            var w:Object = this.readStats(_water, 3, 0.5, 0.0);
            logLine("ocean-m34 from below: " + w["back"].toFixed(1) + "% underside, " +
                w["top"].toFixed(1) + "% top side");
            this.verdict("the surface is seen from underneath", w["back"] > 5.0);
        }

        // One channel of one target, scaled into 8-bit and read on a grid. `bias` makes
        // signed payloads (a height, a slope) readable: value = (px/255 - bias) / gain.
        private function readStats(tex:Object, chan:int, gain:Number, bias:Number):Object
        {
            _mProbe.setUniformValue("uSrc", tex);
            _mProbe.setUniformValue("uChan", chan);
            _mProbe.setUniformValue("uGain", gain);
            _mProbe.setUniformValue("uBias", bias);

            _fnBackBuffer();
            _context.clear(0, 0, 0, 0);
            _context.setCulling("frontAndBack");
            _nr.drawNative(_quad, _mProbe);
            _context.setCulling("back");

            var w:int = stage.stageWidth;
            var h:int = stage.stageHeight;
            var bmd:BitmapData = new BitmapData(w, h, false, 0x000000);
            _context.drawToBitmapData(bmd);

            var lo:Number = 1e9, hi:Number = -1e9, sum:Number = 0, absSum:Number = 0;
            var n:int = 0, top:int = 0, back:int = 0, none:int = 0;
            var x:int, y:int;
            for (y = 4; y < h; y = y + 12)
            {
                for (x = 4; x < w; x = x + 12)
                {
                    var px:int = (bmd.getPixel(x, y) >> 16) & 0xFF;
                    var v:Number = (px / 255.0 - bias) / gain;
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                    sum = sum + v;
                    absSum = absSum + (v < 0 ? -v : v);
                    n++;
                    if (chan == 3)
                    {
                        if (px > 192) top++;
                        else if (px > 64) none++;
                        else back++;
                    }
                }
            }
            var pct:Number = 100.0 / (n > 0 ? n : 1);
            return { lo: lo, hi: hi, mean: sum / (n > 0 ? n : 1),
                     abs: absSum / (n > 0 ? n : 1),
                     top: top * pct, back: back * pct, none: none * pct };
        }

        private function verdict(what:String, ok:Boolean):void
        {
            if (ok) logLine("PASS " + what);
            else
            {
                _failures++;
                logLine("FAIL " + what);
            }
        }

        // ------------------------------------------------------------------
        // Geometry
        // ------------------------------------------------------------------

        // Camera-centred ocean disc: rings grow geometrically from 2 m to 6 km so the
        // vertex density follows the perspective, and every vertex has the same angular
        // cell so the shader can derive its own LOD from its radius.
        private function polarMesh():BufferGeometry
        {
            // Ring spacing is (r1/r0)^(1/rings) - 1 ~ 3.4% and the angular step is
            // 2pi/sectors: the reference runs 384 sectors and a 1.64% radial step, and at
            // these numbers the mid-field grid was coarser than the 12 m cascade, so the
            // surface kept its fine slope detail in the shading while the geometry under
            // it stayed flat -- which reads as sparkle with no swell.
            var rings:int = 240;
            var sectors:int = 320;
            var r0:Number = 2.0;
            var r1:Number = 6000.0;
            var pos:Vector.<Number> = new Vector.<Number>((rings + 1) * sectors * 3, false);
            var idx:Vector.<Number> = new Vector.<Number>(rings * sectors * 6, false);
            var i:int = 0;
            var ring:int, sec:int, a0:int, a1:int, b0:int, b1:int, k:int = 0;
            for (ring = 0; ring <= rings; ring++)
            {
                var r:Number = r0 * Math.pow(r1 / r0, ring / rings);
                for (sec = 0; sec < sectors; sec++)
                {
                    var a:Number = sec / sectors * Math.PI * 2.0;
                    pos[i * 3] = Math.cos(a) * r;
                    pos[i * 3 + 1] = 0;
                    pos[i * 3 + 2] = Math.sin(a) * r;
                    i++;
                }
            }
            for (ring = 0; ring < rings; ring++)
            {
                for (sec = 0; sec < sectors; sec++)
                {
                    a0 = ring * sectors + sec;
                    a1 = ring * sectors + (sec + 1) % sectors;
                    b0 = a0 + sectors;
                    b1 = a1 + sectors;
                    idx[k] = a0; k++;
                    idx[k] = b0; k++;
                    idx[k] = a1; k++;
                    idx[k] = a1; k++;
                    idx[k] = b0; k++;
                    idx[k] = b1; k++;
                }
            }
            var g:BufferGeometry = new BufferGeometry();
            g.setAttribute("position", new BufferAttribute(pos, 3));
            g.setIndex(new BufferAttribute(idx, 1));
            return g;
        }

        // Seabed + islands as one heightfield. The dunes are under the waterline and the
        // three island cones break it, so one mesh gives refraction (dunes through the
        // surface), occlusion (islands in front of water) and something for the planar
        // reflection to mirror.
        private function terrainMesh():BufferGeometry
        {
            var cells:int = 190;
            var span:Number = 1500.0;
            var verts:int = (cells + 1) * (cells + 1);
            var pos:Vector.<Number> = new Vector.<Number>(verts * 3, false);
            var nrm:Vector.<Number> = new Vector.<Number>(verts * 3, false);
            var idx:Vector.<Number> = new Vector.<Number>(cells * cells * 6, false);
            var i:int = 0;
            var gx:int, gz:int, k:int = 0;
            for (gz = 0; gz <= cells; gz++)
            {
                for (gx = 0; gx <= cells; gx++)
                {
                    var x:Number = (gx / cells - 0.5) * span;
                    var z:Number = (gz / cells - 0.5) * span;
                    pos[i * 3] = x;
                    pos[i * 3 + 1] = seabedH(x, z);
                    pos[i * 3 + 2] = z;
                    var dx:Number = seabedH(x + 2.0, z) - seabedH(x - 2.0, z);
                    var dz:Number = seabedH(x, z + 2.0) - seabedH(x, z - 2.0);
                    var nx:Number = -dx, ny:Number = 4.0, nz:Number = -dz;
                    var len:Number = Math.sqrt(nx * nx + ny * ny + nz * nz);
                    nrm[i * 3] = nx / len;
                    nrm[i * 3 + 1] = ny / len;
                    nrm[i * 3 + 2] = nz / len;
                    i++;
                }
            }
            var w:int = cells + 1;
            for (gz = 0; gz < cells; gz++)
            {
                for (gx = 0; gx < cells; gx++)
                {
                    var a:int = gz * w + gx;
                    idx[k] = a; k++;
                    idx[k] = a + w; k++;
                    idx[k] = a + 1; k++;
                    idx[k] = a + 1; k++;
                    idx[k] = a + w; k++;
                    idx[k] = a + w + 1; k++;
                }
            }
            var g:BufferGeometry = new BufferGeometry();
            g.setAttribute("position", new BufferAttribute(pos, 3));
            g.setAttribute("normal", new BufferAttribute(nrm, 3));
            g.setIndex(new BufferAttribute(idx, 1));
            return g;
        }

        // The caustic splat grid: cells x cells quads over the 12 m tile. Position IS the
        // cell coordinate; the vertex shader maps it to tile uv itself.
        private function causticSplatMesh():BufferGeometry
        {
            var n:int = CAUSTIC_CELLS;
            var verts:int = (n + 1) * (n + 1);
            var pos:Vector.<Number> = new Vector.<Number>(verts * 3, false);
            var idx:Vector.<Number> = new Vector.<Number>(n * n * 6, false);
            var i:int = 0, gx:int, gz:int, k:int = 0;
            for (gz = 0; gz <= n; gz++)
            {
                for (gx = 0; gx <= n; gx++)
                {
                    pos[i * 3] = gx;
                    pos[i * 3 + 1] = gz;
                    pos[i * 3 + 2] = 0;
                    i++;
                }
            }
            var w:int = n + 1;
            for (gz = 0; gz < n; gz++)
            {
                for (gx = 0; gx < n; gx++)
                {
                    var a:int = gz * w + gx;
                    idx[k] = a; k++;
                    idx[k] = a + w; k++;
                    idx[k] = a + 1; k++;
                    idx[k] = a + 1; k++;
                    idx[k] = a + w; k++;
                    idx[k] = a + w + 1; k++;
                }
            }
            var g:BufferGeometry = new BufferGeometry();
            g.setAttribute("position", new BufferAttribute(pos, 3));
            g.setIndex(new BufferAttribute(idx, 1));
            return g;
        }

        // Spray: a fixed emitter table. xy is a point in the [-1,1] box the vertex shader
        // scales to uSprayBox.z around the camera; .z is a seed, .w the droplet's phase.
        // The whole trajectory is a function of those, so nothing is updated per frame.
        private function sprayMesh():BufferGeometry
        {
            var n:int = SPRAY_COUNT;
            var pos:Vector.<Number> = new Vector.<Number>(n * 4 * 3, false);
            var col:Vector.<Number> = new Vector.<Number>(n * 4 * 4, false);
            var idx:Vector.<Number> = new Vector.<Number>(n * 6, false);
            var cornerX:Array = [-1, 1, 1, -1];
            var cornerY:Array = [-1, -1, 1, 1];
            var seed:int = 12345;
            var q:int, c:int, i:int = 0, j:int = 0, k:int = 0;
            for (q = 0; q < n; q++)
            {
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
                var ex:Number = ((seed % 2048) / 1024.0) - 1.0;
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
                var ez:Number = ((seed % 2048) / 1024.0) - 1.0;
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
                var sa:Number = (seed % 997) / 997.0;
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
                var sb:Number = (seed % 991) / 991.0;
                for (c = 0; c < 4; c++)
                {
                    pos[i * 3] = cornerX[c];
                    pos[i * 3 + 1] = cornerY[c];
                    pos[i * 3 + 2] = 0;
                    col[j] = ex; col[j + 1] = ez; col[j + 2] = sa; col[j + 3] = sb;
                    i++;
                    j = j + 4;
                }
                k = q * 4;
                idx[q * 6] = k;
                idx[q * 6 + 1] = k + 1;
                idx[q * 6 + 2] = k + 2;
                idx[q * 6 + 3] = k;
                idx[q * 6 + 4] = k + 2;
                idx[q * 6 + 5] = k + 3;
            }
            var g:BufferGeometry = new BufferGeometry();
            g.setAttribute("position", new BufferAttribute(pos, 3));
            g.setAttribute("color", new BufferAttribute(col, 4));
            g.setIndex(new BufferAttribute(idx, 1));
            return g;
        }

        private function makeGeometry():void
        {
            _quad = new Mesh(new PlaneGeometry(2, 2), _mTrans);
            _quad.frustumCulled = false;

            // Two scenes share the geometry and materials: `render()` assigns a parent,
            // so one mesh cannot live in both, and the reflection needs its own instance
            // to discard the underwater half.
            _scene = new Scene();
            _reflScene = new Scene();

            _skyMain = new Mesh(_quad.geometry, _mSky);
            _skyMain.frustumCulled = false;
            _skyMain.renderOrder = -10;
            _scene.add(_skyMain);
            _skyRefl = new Mesh(_quad.geometry, _mSky);
            _skyRefl.frustumCulled = false;
            _skyRefl.renderOrder = -10;
            _reflScene.add(_skyRefl);

            var tm:BufferGeometry = this.terrainMesh();
            _mTerrain.setUniformValue("uCaustics", _causticNear);
            _mTerrain.setUniformValue("uCausticsDeep", _causticDeep);
            // uSunDir/uSunColor are set by bakeAtmosphere(), which runs after this and
            // again on every sun edit: one writer, so the sky and the seabed cannot end
            // up lit by two different suns.
            _mTerrain.setUniformValue("uSkyView", _skyLut);
            _mTerrain.setUniformValue("uSand", [0.80, 0.64, 0.44]);
            _mTerrain.setUniformValue("uRock", [0.52, 0.47, 0.38]);   // the lagoon floor is sand all the way down; a dark rock albedo put black patches under an otherwise uniform sea
            _mTerrain.setUniformValue("uCausticStrength", 1.0);
            _mTerrain.setUniformValue("uReflPass", 0.0);
            _terrainMain = new Mesh(tm, _mTerrain);
            _terrainMain.frustumCulled = false;
            _scene.add(_terrainMain);
            _terrainRefl = new Mesh(tm, _mTerrain);
            _terrainRefl.frustumCulled = false;
            _reflScene.add(_terrainRefl);

            _waterMesh = new Mesh(this.polarMesh(), _mWater);
            _waterMesh.frustumCulled = false;
            _causticMesh = new Mesh(this.causticSplatMesh(), _mCaustic);
            _sprayMesh = new Mesh(this.sprayMesh(), _mSpray);
            _sprayMesh.frustumCulled = false;
        }

        // Seabed + islands, in metres. Dunes sit at about -7 m; the three cones rise to
        // +12..+20 m, which is what puts a silhouette on the horizon for the reflection.
        private function seabedH(x:Number, z:Number):Number
        {
            // The sea floor is a shallow lagoon that deepens with distance: near the
            // camera the sand sits ~7 m down, so the light that comes back up through the
            // surface still carries its colour (Beer-Lambert at 7 m keeps green and blue
            // and kills red, which is where the teal in the troughs comes from). Past a
            // kilometre it is deep enough to read as open sea. A flat deep floor was what
            // made the near water a black slab.
            var r:Number = Math.sqrt(x * x + z * z);
            var h:Number = -3.2 - 0.018 * r
                + 1.0 * Math.sin(x * 0.021) * Math.cos(z * 0.017)
                + 0.5 * Math.sin((x + z) * 0.043)
                + 0.28 * Math.sin(x * 0.11 + 1.3) * Math.cos(z * 0.09);
            // Peaks stay at roughly +12/+6/+4 m so the horizon still has a silhouette;
            // the amplitudes are measured from the lagoon floor under each island.
            h = h + this.island(x, z, -230.0, -180.0, 120.0, 24.0);
            h = h + this.island(x, z, 260.0, -320.0, 90.0, 19.0);
            h = h + this.island(x, z, 60.0, 330.0, 70.0, 16.0);
            return h;
        }

        private function island(x:Number, z:Number, cx:Number, cz:Number, r:Number, h:Number):Number
        {
            var dx:Number = x - cx, dz:Number = z - cz;
            var d:Number = Math.sqrt(dx * dx + dz * dz) / r;
            if (d >= 1.0) return 0;
            var t:Number = 1.0 - d;
            return h * t * t * (1.0 + 0.18 * Math.sin(d * 21.0));
        }

        // ------------------------------------------------------------------
        // Small helpers
        // ------------------------------------------------------------------

        // What the water program samples for its planar reflection: the real half-res
        // target, or the 1x1 black stand-in when the panel switched reflections off.
        private function reflectionTexture():Object
        {
            return _params.reflections ? _refl : _reflOff;
        }

        // The internal render size is fixed (RW x RH) and the composite maps it onto the
        // back buffer, so a resize only reaches the panel: its scroll viewport is sized
        // from the stage height.
        override protected function onViewportResize(w:int, h:int):void
        {
            // The control normalises rotation and pan by the VIEWPORT height (three.js
            // reads clientHeight), so a resize has to reach it or a drag stops tracking
            // the pointer.
            if (_controls != null) _controls.setSize(w, h);
            if (_panel == null) return;
            _panel.setStageSize(w, h);
            _ui.invalidate(Dirty.ALL);
        }

        private function mat(fs:String, vs:String):ShaderMaterial
        {
            var m:ShaderMaterial = new ShaderMaterial();
            m.vertexShader = vs;
            m.fragmentShader = fs;
            m.toneMapped = false;
            m.samplers = {};
            return m;
        }
    }
}