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
//   composite        ->  assemble, absorb, grade, one draw to the back buffer
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
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.materials.Material;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.math.Matrix4;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

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

        private static const WIND_ANGLE:Number = 0.6;

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

        private static const SPRAY_COUNT:int = 2600;
        private static const CHECK_ENABLED:Boolean = true;

        // Visual diagnosis switch: 0 = shaded, 1..8 = one water term per build (see the
        // tail of assets/ocean/water.frag). Kept as a constant so a probe run is exactly
        // reproducible; nothing in a shipped frame reads it.
        private static const DEBUG:int = 0;

        // Write the composed frame to temp/m34-frame.ppm once the checks are in. A
        // window capture reads the window server's last snapshot, which goes stale for
        // this demo (the Metal layer presents without an AppKit redraw), so the only
        // frame worth judging is the one read back out of _final.
        private static const DUMP_FRAME:Boolean = true;

        // Absorption in 1/m. Red dies an order of magnitude faster than blue, which is
        // the whole difference between blue water and green water.
        private static const ABSORB:Array = [0.17, 0.055, 0.038];
        private static const SCATTER:Array = [0.010, 0.062, 0.085];
        // Reference units: radiance is relative to the sun's illuminance outside the
        // atmosphere, and the sun's own colour at sea level is its transmittance times
        // sunIntensity (Ultra-Water src/scene/sky.js). At the 11 degree elevation used
        // here that integral is [0.675, 0.451, 0.232], so the colour is that times 9 --
        // NOT a hand-picked [1.35, 1.16, 0.94], which made the whole scene ~4x dark and
        // the sun's disc 16x dark.
        private static const SUN_INTENSITY:Number = 9.0;
        private static const SUN_ILLUM:Number = Math.PI * SUN_INTENSITY;   // sky LUT scale
        private static const SUNCOL:Array = [3.186, 1.177, 0.191];

        // 3.5 degrees above the horizon: the reference's "Golden hour" default, and the
        // reason its water is a long amber road rather than a glare disc. SUNCOL is the
        // same transmittance integral times 9, evaluated at this elevation (the CPU mirror
        // of the LUT in Ultra-Water src/scene/atmosphere.js): at 11 degrees it is
        // [6.077, 4.062, 2.087], and the ten degrees of path closer to the horizon is
        // most of the difference between daylight blue and this.
        private static const SUN_ELEV:Number = 0.06109;
        private static const SUN_AZIM:Number = 3.5779;   // 205 deg, the reference's azimuth

        // Sea state, from Ultra-Water's OceanSim defaults: two JONSWAP trains (a 9 m/s
        // wind sea over a 120 km fetch and a 7 m/s swell over 900 km), 3.3 peak
        // enhancement, a 0.04 short-wave fade, and 0.08 on the capillary cascade --
        // 0.004 there is the bare spectrum, whose mean square slope is 3x Cox-Munk for
        // the whole sea and turns the water to brushed metal.
        private static const WIND_SPEED:Number = 9.0;
        private static const SWELL_SPEED:Number = 7.0;
        private static const CHOPPINESS:Number = 0.85;
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
        private var _final:Object;
        private var _opaque:Object;
        private var _opaqueDepth:Object;
        private var _water:Object;
        private var _spray:Object;
        private var _lens:Object;
        private var _shafts:Object;

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

        // ------------------------------------------------------------------
        // Scene construction
        // ------------------------------------------------------------------
        override protected function createScene():void
        {
            _sunX = Math.cos(SUN_ELEV) * Math.sin(SUN_AZIM);
            _sunY = Math.sin(SUN_ELEV);
            _sunZ = Math.cos(SUN_ELEV) * Math.cos(SUN_AZIM);

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

            this.makeTargets();
            this.makeMaterials();
            this.makeGeometry();

            _camera = new PerspectiveCamera(50, RW / RH, 0.5, 12000);
            _camera.position.set(0, 9, 150);

            // The reflection needs its own camera object: `render()` computes a camera's
            // world matrix from its transform, so the mirrored matrix has to be handed
            // over as a matrix (matrixAutoUpdate off) rather than decomposed.
            _mirror = new PerspectiveCamera(50, RW / RH, 0.5, 12000);
            _mirror.matrixAutoUpdate = false;

            this.bakeAtmosphere();
            this.bakeSpectra();
            _native["setBackBuffer"]();

            logLine("ocean-m34: 4 cascades (" + P0 + "/" + P1 + "/" + P2 + "/" + P3 + " m) x " +
                N + " FFT, " + RW + "x" + RH + " internal; atmosphere + caustics + spray + " +
                "underwater + planar reflection; " + (18 * 4 + 14) + " passes/frame");
        }

        // Every render target. Float where the payload is not a colour: an FFT
        // intermediate and a view depth both need exact values, and half-float would
        // quantise a 4 km depth into ~4 m steps.
        private function makeTargets():void
        {
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

            // mipmapped: the water samples this at a roughness-driven LOD, and a LOD past
            // the last level of an unmipmapped target is black, not blurred.
            _refl = _native["createTexture"](RW / 2, RH / 2, Context3DTextureFormat.RGBA_HALF_FLOAT, true, true);
            _reflDepth = _native["createDepthTexture"](RW / 2, RH / 2, "depth32f");
            // The composite writes here, not straight to the back buffer: reading a
            // Metal drawable back with drawToBitmapData any time before present gave
            // the clear colour instead of the frame, so the graded image gets a target
            // it can be probed from, and one cheap copy presents it.
            _final = _native["createTexture"](RW, RH, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _opaque = _native["createTexture"](RW, RH, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _opaqueDepth = _native["createDepthTexture"](RW, RH, "depth32f");
            _water = _native["createTexture"](RW, RH, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _spray = _native["createTexture"](RW, RH, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
            _lens = _native["createTexture"](64, 36, "rgba32f", true, false);
            _shafts = _native["createTexture"](RW / 4, RH / 4, Context3DTextureFormat.RGBA_HALF_FLOAT, true, false);
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

            _mWater = this.mat(OceanM34Assets.program("water_frag", ["atmo_core", "atmo_sky"]),
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

            _mProbe = this.mat(PROBE_FS, OceanM34Assets.program("quad", null));
            _mPresent = this.mat(OceanM34Assets.program("present_frag", null), OceanM34Assets.program("quad", null));
        }

        // ------------------------------------------------------------------
        // Atmosphere: three bakes, once. The sky-view bake is 32 samples over 192x108,
        // so it is the one that would be felt if it ran per frame.
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
            _mSkyLut.setUniformValue("uSunIllum", SUN_ILLUM);
            this.pass(_mSkyLut, [_skyLut], null);
            _native["generateMipmaps"](_skyLut);

            _mSky.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            _mSky.setUniformValue("uSunColor", SUNCOL);
            _mSky.setUniformValue("uSunIllum", SUN_ILLUM);
            _mSky.setUniformValue("uCloudCoverage", 0.42);
            _mSky.setUniformValue("uTransLut", _transLut);
            _mSky.setUniformValue("uSkyView", _skyLut);
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
            var wind:Array = jonswapParams(WIND_SPEED, 120.0);
            var swell:Array = jonswapParams(SWELL_SPEED, 900.0);
            var specA:Array = [[1.0, WIND_ANGLE, 0.85, 0.25],
                               [0.7, WIND_ANGLE - 0.9, 1.0, 1.0]];
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
            _mAssemble.setUniformValue("uLambda", CHOPPINESS);
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

                // 16 butterflies flip A<->B an even number of times, so the result is
                // back in A -- stated rather than relied on by luck.
                var cur:Object = _disp[c][_cur];
                var prev:Object = _disp[c][1 - _cur];
                _mAssemble.setUniformValue("uIn0", src[0]);
                _mAssemble.setUniformValue("uIn1", src[1]);
                _mAssemble.setUniformValue("uPrev", prev);
                _mAssemble.setUniformValue("uDt", dt);
                this.pass(_mAssemble, [cur, _slope[c]], null);

                // the water vertex program derives its roughness from the slope chain's
                // coarsest mip, so the chain has to exist before the surface reads it
                _native["generateMipmaps"](cur);
                _native["generateMipmaps"](_slope[c]);
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

            _native["setRenderTargets"]([_causticNear], null);
            _context.clear(0, 0, 0, 1, 1, 0, 7);
            _mCaustic.setUniformValue("uRes", CAUSTIC_NEAR);
            _mCaustic.setUniformValue("uDepth", 1.5);
            _mCaustic.setUniformValue("uMask", [1.0, 0.0, 0.0]);
            _context.setBlendFactors("one", "one");
            _context.setCulling("frontAndBack");
            _nr.drawNative(_causticMesh, _mCaustic);
            _context.setBlendFactors("one", "zero");
            _context.setCulling("back");
            _native["generateMipmaps"](_causticNear);

            _native["setRenderTargets"]([_causticDeep], null);
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
            _native["generateMipmaps"](_causticDeep);
        }

        // ------------------------------------------------------------------
        // The frame
        // ------------------------------------------------------------------
        override protected function updateFrame(dt:Number):void
        {
            if (_noChannel) return;
            if (dt > 0.05) dt = 0.05;          // a stalled first frame must not teleport
            _time += dt;
            this.updateCamera();
            this.simulate(dt);
            this.buildCaustics();
            this.drawReflection();
            this.drawOpaque();
            this.drawWater();
            this.drawSpray();
            this.drawUnderwater();
            this.drawComposite();
            _frames++;
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
            var a:Number = SUN_AZIM + Math.PI + 0.04 + Math.sin(phase * 0.09) * 0.05;
            _camera.position.set(Math.sin(a) * dist, height, Math.cos(a) * dist);
            if (_underwater) _camera.lookAt(0, 8.0, 0);
            else _camera.lookAt(0, 5.2, 0);   // near level: horizon just above centre
            _camera.updateMatrixWorld(true);
            _camera.updateMatrixWorldInverse();
        }

        // Mirror about y=0: multiply the world matrix by diag(1,-1,1) on the left, which
        // negates the world-Y row. Reflecting the POSITION only is the classic planar
        // reflection bug: the mirrored camera keeps its original orientation and the
        // reflection rotates the wrong way.
        private function drawReflection():void
        {
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

            _native["setRenderTargets"]([_refl], _reflDepth);
            // Premultiplied, alpha = coverage: the water samples this blurred, and a mip
            // of black would drag the reflection to black instead of to the sky.
            _context.clear(0, 0, 0, 0, 1, 0, 7);
            _mSky.setUniformValue("uAlpha", 0.0);
            _mTerrain.setUniformValue("uReflPass", 1.0);
            _nr.render(_reflScene, _mirror);
            _mSky.setUniformValue("uAlpha", 1e4);
            _mTerrain.setUniformValue("uReflPass", 0.0);
            _native["generateMipmaps"](_refl);

        }

        // Sky + terrain into _opaque. Alpha is the pass's linear view depth: the water and
        // composite passes read it as "what is behind me".
        private function drawOpaque():void
        {
            _native["setRenderTargets"]([_opaque], _opaqueDepth);
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
            _nr.render(_scene, _camera);
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
            m.setUniformValue("uReflection", _refl);
            m.setUniformValue("uLength", [P0, P1, P2, P3]);
            // Roughness/refraction/distortion/fog straight from OceanSurface.js: 0.02 is
            // the reference's base roughness (0.055 was smooth enough to hide the sun's
            // road), and 1/18000 is its aerial-perspective density.
            m.setUniformValue("uOptics", [0.02, 0.06, 0.04, 1.0 / 18000.0]);
            m.setUniformValue("uFoam", [0.05, 1.3, 0.35, 0.85]);
            m.setUniformValue("uSSS", [1.6, 0.06, 0.05, 0.0]);
            m.setUniformValue("uSkyView", _skyLut);
            m.setUniformValue("uTime", _time);
                    m.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            m.setUniformValue("uSunColor", SUNCOL);
            m.setUniformValue("uAbsorption", ABSORB);
            m.setUniformValue("uScatterColor", SCATTER);
            m.setUniformValue("uSkyView", _skyLut);
            m.setUniformValue("uSkyAmbient", [0.32, 0.42, 0.52]);
            m.setUniformValue("uGlint", 0.6);
                var f:Vector.<Number> = _camera.matrixWorld.elements;
            m.setUniformValue("uCamForward", [-f[8], -f[9], -f[10]]);
            m.setUniformValue("uDebug", DEBUG);
            m.setUniformValue("uCellStep", 6.283185307179586 / 320.0);
            m.setUniformValue("uWind", WIND_SPEED);

            // clear alpha 1 = "no water here": the tag the composite keys on. 0 is the
            // underside and 2 the top, so a cleared pixel cannot be read as a surface.
            if (!_dbgWaterDescribed) { _dbgWaterDescribed = true; logLine("WATER PROGRAM:\n" + _nr.describeProgram(m)); }
            _native["setRenderTargets"]([_water], null);
            _context.clear(0, 0, 0, 1, 1, 0, 7);
            _context.setCulling("frontAndBack");   // gl_FrontFacing must be able to differ
            _nr.drawNative(_waterMesh, m);
            _context.setCulling("back");
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

            _native["setRenderTargets"]([_spray], null);
            _context.clear(0, 0, 0, 0, 1, 0, 7);
            _context.setBlendFactors("one", "one");
            _context.setCulling("frontAndBack");
            _nr.drawNative(_sprayMesh, m);
            _context.setBlendFactors("one", "zero");
            _context.setCulling("back");
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
            m.setUniformValue("uAbsorption", ABSORB);
            m.setUniformValue("uUnder", [0.055, 0.9, 42.0, 0.0]);
            m.setUniformValue("uFrame", _frames % 64);
            m.setUniformValue("uCaustics", _causticNear);
            m.setUniformValue("uCausticsDeep", _causticDeep);
            this.pass(m, [_shafts], null);
        }

        private function drawComposite():void
        {
            var m:ShaderMaterial = _mComposite;
            m.setUniformValue("uColor", _opaque);
            m.setUniformValue("uWater", _water);
            m.setUniformValue("uSpray", _spray);
            m.setUniformValue("uShafts", _shafts);
            m.setUniformValue("uLens", _lens);
            m.setUniformValue("uAbsorption", ABSORB);
            m.setUniformValue("uScatterColor", SCATTER);
            m.setUniformValue("uSunColor", SUNCOL);
            m.setUniformValue("uUnder", [0.055, 0.9, 42.0, 0.0]);
            m.setUniformValue("uExposure", 0.45);
            m.setUniformValue("uDebug", DEBUG);

            if (!_dbgDescribed) { _dbgDescribed = true; logLine("COMPOSITE PROGRAM:\n" + _nr.describeProgram(m)); }
            this.pass(m, [_final], null);
            _mPresent.setUniformValue("uSrc", _final);
            _native["setBackBuffer"]();
            _context.clear(0, 0, 0, 1);
            _context.setCulling("frontAndBack");
            _nr.drawNative(_quad, _mPresent);
            _context.setCulling("back");
            if (DUMP_FRAME && _frames == 30 && !_dumped) { _dumped = true; this.dumpFrame("../../temp/m34-frame.ppm"); }
        }

        // Copy _final into the back buffer and write it as a binary PPM. Development
        // only: it allocates a full-resolution bitmap and touches the filesystem.
        private function dumpFrame(path:String):void
        {
            _mPresent.setUniformValue("uSrc", _final);
            _native["setBackBuffer"]();
            _context.clear(0, 0, 0, 1);
            _context.setCulling("frontAndBack");
            _nr.drawNative(_quad, _mPresent);
            _context.setCulling("back");

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
            if (colors != null) _native["setRenderTargets"](colors, depth);
            _context.setCulling("frontAndBack");
            _nr.drawNative(_quad, material);
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

            _native["setBackBuffer"]();
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
            _mTerrain.setUniformValue("uSunDir", [_sunX, _sunY, _sunZ]);
            _mTerrain.setUniformValue("uSunColor", SUNCOL);
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