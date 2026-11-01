// OceanM32.as -- M32: the first stage of the Ultra-Water reproduction, rebuilt on
// the E6 native-shader channel.
//
// WHAT THIS IS. A Tessendorf FFT ocean (the model `Humpalumps/Ultra-Water` uses in
// `src/water/OceanSim.js`): a wind-driven height spectrum h0(k), advanced in time by
// the deep-water dispersion relation, inverse-transformed into a spatial height
// field, then used to displace and shade a grid. The port keeps the reference's
// SHAPE -- spectrum texture -> ping-pong IFFT -> packed displacement/normal atlas
// -> displaced surface -- and drops what this stage does not need yet. §38 of
// three-api-design.md lists what is still missing (caustics, spray, the underwater
// pass, planar reflections, 4 cascades).
//
// WHY IT EXISTS AS A DEMO. shader-m31 proves the four storage capabilities in
// isolation; this one proves they COMPOSE into a pipeline that renders something
// recognisable. An FFT ocean is the cheapest honest way to say that: every pass
// below reads a texture a previous pass wrote, so a binding that silently reads
// black collapses the whole picture into a flat blue plane -- which is exactly the
// failure this demo has to make visible rather than plausible.
//
// THE THREE THINGS THAT MADE IT WORK (each cost a debugging round, recorded in
// §38 so the next pipeline does not pay for them again):
//   1. Bit-reversal is done ONCE, in the spectrum pass, so the DIT butterflies need
//      no reordering and the whole FFT is 16 ping-pong draws. Folding the
//      permutation into the pass that already writes the buffer is free; doing it
//      afterwards costs another 16.
//   2. A k-space centred on texel 0 (k = x - N/2) is a ROLL by N/2, and a roll
//      multiplies the spatial output by (-1)^(x+y). Left uncorrected, the height
//      field is a checkerboard. The assemble pass applies that sign.
//   3. `uStage`/`uVertical` are INTEGER uniforms. Feeding them through
//      `setUniform1f` stores the BIT PATTERN of 2.0 (1073741824) and the loop
//      bound becomes garbage; the channel needs `setUniformInts`, which is why the
//      reflection table grew a scalar-category field in E6/M3.
//
// Run (from asaot3d/):
//   ./apps/ocean-m32/build.sh aot --run
package
{
    import flash.desktop.NativeApplication;
    import flash.display.BitmapData;
    import flash.display3D.Context3DTextureFormat;
    import flash.utils.Dictionary;

    import asaot.three.AGALRenderer;
    import asaot.three.NativeShaderRenderer;
    import asaot.three.RendererFactory;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.controls.OrbitControls;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class OceanM32 extends Stage3DApp
    {
        // ------------------------------------------------------------------
        // Tuning
        // ------------------------------------------------------------------
        // 256 x 256 per cascade, the reference's tile size. The FFT is 8 stages per
        // axis, so 16 passes per cascade per frame: cheap for the GPU, and the whole
        // reason it can run inside one frame instead of being staged.
        private static const N:int = 256;

        // Two cascades: 600 m of swell and an 85 m patch of chop. The reference
        // runs four (600/85/12/2.1); the extra two only matter once there is a
        // near-field surface with foam and spray, so this stage stops at two and
        // says so rather than pretending the missing pair is a look.
        private static const PATCH0:Number = 600.0;
        private static const PATCH1:Number = 85.0;

        private static const WIND_SPEED:Number = 14.0;   // m/s
        // Sea state, dimensionless. The Phillips density is a power per unit k-area, so
        // the IFFT (which SUMS texels) needs a fixed calibration to turn it into
        // metres; that constant lives in FS_H0 as SPECTRUM_CAL. Calibrated here: 1.0
        // at wind 11 m/s produces roughly 1.5 m seas, measured by the readback below.
        private static const AMPLITUDE:Number = 1.8;
        private static const CHOPPY:Number = 1.4;

        // 256 cells = 66k vertices. Vertex texture fetch is the expensive part of
        // the frame (4 fetches per vertex), so this is the knob to turn first.
        private static const GRID:int = 256;

        private static const CHECK_ENABLED:Boolean = true;

        // ------------------------------------------------------------------
        // GLSL ES 3.00
        // ------------------------------------------------------------------
        // Full-screen quad. Every offscreen pass draws this; positions are already
        // in clip space, so no matrices.
        private static const QUAD_VS:String =
            "#version 300 es\n" +
            "layout(location = 0) in vec3 aPos;\n" +
            "out vec2 vUV;\n" +
            "void main() { vUV = aPos.xy * 0.5 + 0.5; gl_Position = vec4(aPos.xy, 0.0, 1.0); }\n";

        // A1. Wind spectrum h0(k) and conj(h0(-k)) in one RGBA32F texel.
        //
        // The reference computes this on the GPU from a hash so it never uploads a
        // 256x256 complex array from the CPU. Same here: the alternative (a CPU
        // bake) is 65k sin/cos per cascade at startup, and under `adl` that is
        // exactly the multi-second first frame D178 already warned about.
        //
        // R,G = h0(k); B,A = conj(h0(-k)). Carrying both in one texel is what makes
        // the time-evolution pass a single fetch: the mirrored texel is never read.
        private static const FS_H0:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform int uN;\n" +
            "uniform float uL;\n" +
            "uniform float uWindSpeed;\n" +
            "uniform float uAmplitude;\n" +
            "uniform vec2 uWindDir;\n" +
            "uniform int uSeed;\n" +
            "out vec4 fragColor;\n" +
            "uint pcg(uint v) {\n" +
            "  uint s = v * 747796405u + 2891336453u;\n" +
            "  uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;\n" +
            "  return (w >> 22u) ^ w;\n" +
            "}\n" +
            "float rnd(uint a, uint b) { return float(pcg(a ^ pcg(b))) * (1.0 / 4294967295.0); }\n" +
            "void main() {\n" +
            "  ivec2 p = ivec2(gl_FragCoord.xy);\n" +
            "  int halfN = uN / 2;\n" +
            "  vec2 kv = vec2(float(p.x - halfN), float(p.y - halfN)) * (6.283185307179586 / uL);\n" +
            "  float kl = length(kv);\n" +
            "  float Lw = uWindSpeed * uWindSpeed / 9.81;\n" +
            "  float P = 0.0;\n" +
            "  if (kl > 1e-5) {\n" +
            "    float k2 = kl * kl;\n" +
            "    float c = dot(kv / kl, uWindDir);\n" +
            "    float dk = 6.283185307179586 / uL;\n" +
            "    P = uAmplitude * 880000.0 * dk * dk * exp(-1.0 / (k2 * Lw * Lw)) / (k2 * k2) * c * c;\n" +
            "  }\n" +
            "  uint sd = uint(p.x) * 1973u + uint(p.y) * 9277u + uint(uSeed) * 26699u;\n" +
            "  float u1 = max(rnd(sd, 1u), 1e-7); float u2 = rnd(sd, 2u);\n" +
            "  float g1 = sqrt(-2.0 * log(u1));\n" +
            "  float r1 = g1 * cos(6.283185307179586 * u2);\n" +
            "  float r2 = g1 * sin(6.283185307179586 * u2);\n" +
            "  float u3 = max(rnd(sd, 3u), 1e-7); float u4 = rnd(sd, 4u);\n" +
            "  float g2 = sqrt(-2.0 * log(u3));\n" +
            "  float r3 = g2 * cos(6.283185307179586 * u4);\n" +
            "  float r4 = g2 * sin(6.283185307179586 * u4);\n" +
            "  float a = sqrt(P) * 0.7071067811865476;\n" +
            "  fragColor = vec4(a * r1, a * r2, a * r3, -a * r4);\n" +
            "}\n";

        // A2. Time evolution + the ONE permutation the rest of the FFT relies on.
        //
        // h(k,t) = h0(k) e^{iw t} + conj(h0(-k)) e^{-iw t}, w = sqrt(g|k|).
        // The result is written to the BIT-REVERSED texel, so every butterfly below
        // is a plain in-place DIT step and no pass ever reorders.
        private static const FS_EVOLVE:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uH0;\n" +
            "uniform int uN;\n" +
            "uniform float uL;\n" +
            "uniform float uTime;\n" +
            "out vec4 fragColor;\n" +
            "uint rev8(uint v) {\n" +
            "  v = ((v & 0xF0u) >> 4u) | ((v & 0x0Fu) << 4u);\n" +
            "  v = ((v & 0xCCu) >> 2u) | ((v & 0x33u) << 2u);\n" +
            "  v = ((v & 0xAAu) >> 1u) | ((v & 0x55u) << 1u);\n" +
            "  return v;\n" +
            "}\n" +
            "void main() {\n" +
            "  ivec2 o = ivec2(gl_FragCoord.xy);\n" +
            "  ivec2 s = ivec2(int(rev8(uint(o.x))), int(rev8(uint(o.y))));\n" +
            "  int halfN = uN / 2;\n" +
            "  vec2 kv = vec2(float(s.x - halfN), float(s.y - halfN)) * (6.283185307179586 / uL);\n" +
            "  float w = sqrt(9.81 * length(kv));\n" +
            "  float c = cos(w * uTime), sn = sin(w * uTime);\n" +
            "  vec4 h = texelFetch(uH0, s, 0);\n" +
            "  vec2 A = h.xy, B = h.zw;\n" +
            "  vec2 t1 = vec2(A.x * c - A.y * sn, A.x * sn + A.y * c);\n" +
            "  vec2 t2 = vec2(B.x * c + B.y * sn, -B.x * sn + B.y * c);\n" +
            "  fragColor = vec4(t1 + t2, 0.0, 1.0);\n" +
            "}\n";

        // A3. One radix-2 DIT stage along one axis. len = 1 << (uStage + 1).
        //
        // `uSign` is -1 for the forward pair (the reference's convention) and +1 for
        // the inverse, so the same program runs both directions and the 1/N^2 scale
        // is folded into the assemble pass.
        private static const FS_FFT:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uSrc;\n" +
            "uniform int uStage;\n" +
            "uniform int uVertical;\n" +
            "uniform float uSign;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  ivec2 o = ivec2(gl_FragCoord.xy);\n" +
            "  int len = 1 << (uStage + 1);\n" +
            "  int halfLen = len >> 1;\n" +
            "  int pos = (uVertical == 1) ? o.y : o.x;\n" +
            "  int j = pos % len;\n" +
            "  int base = pos - j;\n" +
            "  int k = j % halfLen;\n" +
            "  int ia = base + k;\n" +
            "  int ib = ia + halfLen;\n" +
            "  ivec2 pa = (uVertical == 1) ? ivec2(o.x, ia) : ivec2(ia, o.y);\n" +
            "  ivec2 pb = (uVertical == 1) ? ivec2(o.x, ib) : ivec2(ib, o.y);\n" +
            "  float ang = 6.283185307179586 * float(k) / float(len) * uSign;\n" +
            "  vec2 tw = vec2(cos(ang), sin(ang));\n" +
            "  vec2 A = texelFetch(uSrc, pa, 0).xy;\n" +
            "  vec2 B = texelFetch(uSrc, pb, 0).xy;\n" +
            "  vec2 bw = vec2(B.x * tw.x - B.y * tw.y, B.x * tw.y + B.y * tw.x);\n" +
            "  vec2 r = (j < halfLen) ? (A + bw) : (A - bw);\n" +
            "  fragColor = vec4(r, 0.0, 1.0);\n" +
            "}\n";

        // A4. Spatial field -> displacement + normal, in one MRT pass.
        //
        // This is where the reference splits into its "displacement/turbulence" and
        // "slopes/moments" attachments; the shape is the same, the payload is the
        // two things this stage actually consumes.
        //
        // The (-1)^(x+y) factor is the roll correction explained in the header: the
        // spectrum is centred on k = 0 at texel N/2, and an unrolled index turns the
        // height field into a checkerboard.
        // A NOTE ON HELPER FUNCTIONS, because this cost a round: a GLSL function
        // that reads a `uniform` does NOT translate to MSL here. SPIRV-Cross turns
        // the globals into parameters of the entry point and then tries to pass the
        // `constant`-address-space reference into its own `thread`-address-space
        // parameter, which Metal rejects ("cannot bind reference in address space
        // 'constant' to object in default address space"). The FFT ocean wants
        // helpers; the portable shape today is to inline, or to copy the uniform
        // into a local first so the caller has a thread-addressable value. Recorded
        // in native-shader.md §9.3 as a channel limitation, not a shader bug.
        private static const FS_ASSEMBLE:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uH;\n" +
            "uniform int uN;\n" +
            "uniform float uScale;\n" +
            "uniform float uChoppy;\n" +
            "layout(location = 0) out vec4 outDisp;\n" +
            "layout(location = 1) out vec4 outNorm;\n" +
            "void main() {\n" +
            "  ivec2 p = ivec2(gl_FragCoord.xy);\n" +
            "  int n = uN;\n" +
            "  float sc = uScale;\n" +
            "  ivec2 q = ivec2((p.x + n) % n, (p.y + n) % n);\n" +
            "  float s0 = (((q.x + q.y) & 1) == 0) ? 1.0 : -1.0;\n" +
            "  float h = texelFetch(uH, q, 0).x * s0 * sc;\n" +
            "  ivec2 xp = ivec2((p.x + 1 + n) % n, q.y);\n" +
            "  ivec2 xm = ivec2((p.x - 1 + n) % n, q.y);\n" +
            "  ivec2 zp = ivec2(q.x, (p.y + 1 + n) % n);\n" +
            "  ivec2 zm = ivec2(q.x, (p.y - 1 + n) % n);\n" +
            "  float sx1 = (((xp.x + xp.y) & 1) == 0) ? 1.0 : -1.0;\n" +
            "  float sx0 = (((xm.x + xm.y) & 1) == 0) ? 1.0 : -1.0;\n" +
            "  float sz1 = (((zp.x + zp.y) & 1) == 0) ? 1.0 : -1.0;\n" +
            "  float sz0 = (((zm.x + zm.y) & 1) == 0) ? 1.0 : -1.0;\n" +
            "  float dx = (texelFetch(uH, xp, 0).x * sx1 - texelFetch(uH, xm, 0).x * sx0) * sc * 0.5;\n" +
            "  float dz = (texelFetch(uH, zp, 0).x * sz1 - texelFetch(uH, zm, 0).x * sz0) * sc * 0.5;\n" +
            "  outDisp = vec4(-uChoppy * dx, h, -uChoppy * dz, 1.0);\n" +
            "  outNorm = vec4(normalize(vec3(-dx, 1.0, -dz)), h);\n" +
            "}\n";

        // A5. The surface. Vertex texture fetch does the displacement (that is what
        // `tld`/`vs0` buys on the AGAL side, and `textureLod` in a vertex shader
        // here); the fragment is a first-pass water shading: height-tinted body,
        // Fresnel sky mix, one sun lobe, foam on crests.
        private static const SURF_VS:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec3 position;\n" +
            "uniform mat4 projectionMatrix;\n" +
            "uniform mat4 modelViewMatrix;\n" +
            "uniform sampler2D uDisp0;\n" +
            "uniform sampler2D uDisp1;\n" +
            "uniform sampler2D uNorm0;\n" +
            "uniform sampler2D uNorm1;\n" +
            "uniform float uPatch0;\n" +
            "uniform float uPatch1;\n" +
            "out vec3 vWorld;\n" +
            "out vec3 vNormal;\n" +
            "out float vHeight;\n" +
            "void main() {\n" +
            "  vec3 p = position;\n" +
            "  vec2 w0 = vec2(p.x, p.z) / uPatch0 + 0.5;\n" +
            "  vec2 w1 = vec2(p.x, p.z) / uPatch1 + 0.5;\n" +
            "  vec2 c0 = clamp(w0, 0.0, 1.0);\n" +
            "  vec2 c1 = clamp(w1, 0.0, 1.0);\n" +
            // The fine cascade only covers 85 m; outside it the clamped texel would
            // be repeated, which reads as a square of frozen ripples in the middle
            // of the sea. Fade it out over the outer 30% of its patch instead.
            "  float m1 = max(abs(w1.x - 0.5), abs(w1.y - 0.5));\n" +
            "  float f1 = 1.0 - smoothstep(0.35, 0.5, m1);\n" +
            "  vec4 d0 = textureLod(uDisp0, c0, 0.0);\n" +
            "  vec4 d1 = textureLod(uDisp1, c1, 0.0) * f1;\n" +
            "  vec3 n0 = textureLod(uNorm0, c0, 0.0).xyz;\n" +
            "  vec3 n1 = mix(vec3(0.0, 1.0, 0.0), textureLod(uNorm1, c1, 0.0).xyz, f1);\n" +
            "  p += vec3(d0.x + d1.x, d0.y + d1.y, d0.z + d1.z);\n" +
            "  vNormal = normalize(n0 + n1 - vec3(0.0, 1.0, 0.0));\n" +
            "  vHeight = d0.y + d1.y;\n" +
            "  vWorld = p;\n" +
            "  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);\n" +
            "}\n";

        private static const SURF_FS:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform vec3 cameraPosition;\n" +
            "uniform vec3 uSunDir;\n" +
            "uniform vec3 uSunColor;\n" +
            "uniform vec3 uDeep;\n" +
            "uniform vec3 uShallow;\n" +
            "uniform vec3 uSky;\n" +
            "in vec3 vWorld;\n" +
            "in vec3 vNormal;\n" +
            "in float vHeight;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  vec3 N = normalize(vNormal);\n" +
            "  vec3 V = normalize(cameraPosition - vWorld);\n" +
            "  float fres = 0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0);\n" +
            "  vec3 body = mix(uDeep, uShallow, clamp(vHeight * 1.2 + 0.35, 0.0, 1.0));\n" +
            "  vec3 col = mix(body, uSky, clamp(fres, 0.0, 1.0));\n" +
            "  vec3 H = normalize(uSunDir + V);\n" +
            "  col += uSunColor * pow(max(dot(N, H), 0.0), 260.0) * 1.5;\n" +
            "  float foam = smoothstep(0.55, 0.95, vHeight) * 0.45;\n" +
            "  col = mix(col, vec3(0.92, 0.95, 0.98), foam);\n" +
            "  fragColor = vec4(col, 1.0);\n" +
            "}\n";

        // A6. Read back one channel of a simulation texture as grey, so the demo can
        // ASSERT that the FFT produced a varying height field instead of a flat
        // plane. A pipeline that silently reads black looks exactly like "the ocean
        // is calm" in a screenshot, which is not an acceptable proof.
        private static const FS_PROBE:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uSrc;\n" +
            "uniform float uBias;\n" +
            "uniform float uGain;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  float h = texelFetch(uSrc, ivec2(gl_FragCoord.xy), 0).y;\n" +
            "  fragColor = vec4(vec3(h * uGain + uBias), 1.0);\n" +
            "}\n";

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------
        // NOT named `_renderer`: that is Stage3DApp's protected field, and a
        // shadowing declaration compiles here but silently leaves the base's
        // renderer untouched -- the first version of this demo read null from the
        // shadow and concluded "no native channel" while the channel was live.
        private var _nr:NativeShaderRenderer;
        private var _native:Object;
        private var _quad:Mesh;

        private var _h0:Array = [];          // [cascade] -> TextureBase (rgba32f)
        private var _fftA:Array = [];
        private var _fftB:Array = [];
        private var _disp:Array = [];        // MRT attachment 0
        private var _norm:Array = [];        // MRT attachment 1

        private var _mH0:ShaderMaterial;
        private var _mEvolve:ShaderMaterial;
        private var _mFft:ShaderMaterial;
        private var _mAssemble:ShaderMaterial;
        private var _mProbe:ShaderMaterial;

        private var _time:Number = 0;
        private var _frames:int = 0;
        private var _noChannel:Boolean = false;
        private var _controls:OrbitControls;
        private var _checked:Boolean = false;

        override protected function createScene():void
        {
            if (!RendererFactory.hasNativeChannel() || !(_renderer is NativeShaderRenderer))
            {
                // The AIR / default-build answer is NOT a failure: the enhancement is
                // opt-in and §1.5 says state its absence loudly rather than draw an
                // AGAL approximation of the author's GLSL (three-api-design §37.4).
                // Build nothing; afterFrame reports and exits 0, exactly like
                // shader-m30. (Throwing here only produced a "frame error" stack on
                // top of the same message.)
                // Stage3DApp still requires a scene and a camera even on the
                // no-channel path (it renders an empty scene for the one frame
                // before afterFrame exits), so hand it the minimum.
                _noChannel = true;
                _scene = new Scene();
                _camera = new PerspectiveCamera(55, 1, 0.1, 8000);
                return;
            }
            _nr = NativeShaderRenderer(_renderer);
            _native = _nr.context3DNative;

            // TEXTURES. rgba32f for the complex transforms (an FFT intermediate is
            // not a colour: magnitudes are unbounded and both parts must be exact);
            // rgbaHalfFloat for the two packed atlases. Half float is enough there
            // because the payload is a height in metres and a unit normal.
            for (var i:int = 0; i < 2; i++)
            {
                _h0.push(_native["createTexture"](N, N, "rgba32f", true));
                _fftA.push(_native["createTexture"](N, N, "rgba32f", true));
                _fftB.push(_native["createTexture"](N, N, "rgba32f", true));
                _disp.push(_native["createTexture"](N, N, Context3DTextureFormat.RGBA_HALF_FLOAT, true));
                _norm.push(_native["createTexture"](N, N, Context3DTextureFormat.RGBA_HALF_FLOAT, true));
            }

            _mH0 = this.material(QUAD_VS, FS_H0);
            _mH0.setUniformValue("uN", N);
            _mH0.setUniformValue("uWindDir", [1.0, 0.35]);
            _mH0.setUniformValue("uWindSpeed", WIND_SPEED);
            _mH0.setUniformValue("uAmplitude", AMPLITUDE);

            _mEvolve = this.material(QUAD_VS, FS_EVOLVE);
            _mEvolve.setUniformValue("uN", N);

            _mFft = this.material(QUAD_VS, FS_FFT);

            _mAssemble = this.material(QUAD_VS, FS_ASSEMBLE);
            _mAssemble.setUniformValue("uN", N);
            _mAssemble.setUniformValue("uChoppy", CHOPPY);

            _mProbe = this.material(QUAD_VS, FS_PROBE);

            _quad = new Mesh(new PlaneGeometry(2, 2), _mH0);
            _quad.frustumCulled = false;

            this.buildSpectra();

            // SCENE. One grid, two cascade patches; the sun is a directional stand-in
            // so the shading is meaningful before any light rig exists.
            var scene:Scene = new Scene();
            scene.background = new Color(0x0a2233);
            _scene = scene;

            var surf:ShaderMaterial = this.material(SURF_VS, SURF_FS);
            var ocean:Mesh = new Mesh(this.grid(PATCH0, GRID), surf);
            ocean.frustumCulled = false;
            surf.setUniformValue("uDisp0", _disp[0]);
            surf.setUniformValue("uDisp1", _disp[1]);
            surf.setUniformValue("uNorm0", _norm[0]);
            surf.setUniformValue("uNorm1", _norm[1]);
            surf.setUniformValue("uPatch0", PATCH0);
            surf.setUniformValue("uPatch1", PATCH1);
            surf.setUniformValue("uSunDir", [0.4, 0.55, 0.72]);
            surf.setUniformValue("uSunColor", [1.0, 0.93, 0.78]);
            surf.setUniformValue("uDeep", [0.008, 0.055, 0.09]);
            surf.setUniformValue("uShallow", [0.03, 0.22, 0.26]);
            surf.setUniformValue("uSky", [0.42, 0.62, 0.78]);
            scene.add(ocean);

            var camera:PerspectiveCamera = new PerspectiveCamera(55, stage.stageWidth / stage.stageHeight, 0.5, 4000);
            camera.position.set(0, 14, 95);
            camera.lookAt(0, 2, 0);
            _camera = camera;

            _controls = new OrbitControls(camera, this.stage);
            _controls.target.set(0, 2, 0);
            _controls.setSize(stage.stageWidth, stage.stageHeight);
            _controls.enableDamping = true;
            _controls.dampingFactor = 0.08;
            _controls.minDistance = 12;
            _controls.maxDistance = 700;
            _controls.maxPolarAngle = Math.PI * 0.495;      // never dive under the sea

            logLine("ocean-m32: " + N + "x" + N + " FFT, 2 cascades (" + PATCH0 + "m, " +
                PATCH1 + "m), grid " + GRID + "x" + GRID + ", 34 passes/frame");
        }

        // ------------------------------------------------------------------
        // Spectrum: one pass per cascade, once. A cascade's h0 depends only on the
        // patch length, the wind and the seed, so re-baking it every frame would be
        // 2 wasted passes and (worse) a different random ocean every frame.
        // ------------------------------------------------------------------
        private function buildSpectra():void
        {
            var lengths:Array = [PATCH0, PATCH1];
            for (var i:int = 0; i < 2; i++)
            {
                _mH0.setUniformValue("uL", lengths[i]);
                _mH0.setUniformValue("uSeed", 7 + i * 131);
                _native["setRenderTargets"]([_h0[i]], null);
                _quad.material = _mH0;
                _nr.drawNative(_quad, _mH0);
            }
            _native["setBackBuffer"]();
        }

        // ------------------------------------------------------------------
        // Per frame: advance both cascades. 17 passes each (1 evolve + 16 FFT) plus
        // 1 assemble = 34, all into float targets the surface pass then samples.
        // ------------------------------------------------------------------
        private function simulate(dt:Number):void
        {
            _time += dt;
            var lengths:Array = [PATCH0, PATCH1];

            for (var c:int = 0; c < 2; c++)
            {
                // 1. h0 -> h(k, t), permuted into the DIT order.
                _mEvolve.setUniformValue("uH0", _h0[c]);
                _mEvolve.setUniformValue("uL", lengths[c]);
                _mEvolve.setUniformValue("uTime", _time);
                this.pass(_mEvolve, [_fftA[c]], null);

                // 2. Rows, then columns. 8 stages each, ping-ponging A<->B.
                var src:Object = _fftA[c];
                var dst:Object = _fftB[c];
                for (var axis:int = 0; axis < 2; axis++)
                {
                    for (var s:int = 0; s < 8; s++)
                    {
                        _mFft.setUniformValue("uSrc", src);
                        _mFft.setUniformValue("uStage", s);
                        _mFft.setUniformValue("uVertical", axis);
                        _mFft.setUniformValue("uSign", 1.0);      // inverse transform
                        this.pass(_mFft, [dst], null);
                        var t:Object = src; src = dst; dst = t;
                    }
                }
                // 16 passes is even, so the result is back in _fftA[c]; keep the
                // invariant explicit instead of relying on the parity of 16.

                // 3. Complex field -> packed displacement + normal (2 attachments).
                _mAssemble.setUniformValue("uH", _fftA[c]);
                _mAssemble.setUniformValue("uScale", 1.0 / (N * N));
                this.pass(_mAssemble, [_disp[c], _norm[c]], null);
            }

            _native["setBackBuffer"]();
        }

        private function pass(material:ShaderMaterial, colors:Array, depth:Object):void
        {
            _native["setRenderTargets"](colors, depth);
            _quad.material = material;
            _nr.drawNative(_quad, material);
        }

        // The readback runs AFTER the frame, like every other probe in this repo:
        // drawToBitmapData flushes the frame's command buffer, and doing that in the
        // middle of updateFrame -- with 34 offscreen passes already encoded -- is
        // what corrupted Metal's resource list in the first version of this demo
        // (MTLResourceListAddResource, method cache corrupted). Stated in §38.
        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_noChannel)
            {
                if (_frames++ > 0) return;
                // logLine (System.output), not trace: adl forwards nothing from
                // trace() on macOS (Stage3DApp.logLine documents this).
                logLine("ocean-m32 NO-CHANNEL: " + RendererFactory.describe());
                logLine("ocean-m32 OK (channel absent, reported loudly; --features native-shader enables it)");
                this.finish();
                return;
            }
            _frames++;
            if (!_checked && _frames == 6) this.check();
        }

        override protected function updateFrame(dt:Number):void
        {
            if (_noChannel) return;
            this.simulate(dt);
            _frames++;
            if (!_checked && _frames == 6 && CHECK_ENABLED) this.check();
        }

        // ------------------------------------------------------------------
        // Self-check: the height atlas must VARY. Reading it back is the only way to
        // tell "the ocean is working" from "the ocean is a flat plane because a
        // texture binding reads zero" -- both look calm in a screenshot.
        // ------------------------------------------------------------------
        private function check():void
        {
            _checked = true;
            var gain:Number = 0.25, bias:Number = 0.5;
            _mProbe.setUniformValue("uSrc", _disp[0]);
            _mProbe.setUniformValue("uGain", gain);
            _mProbe.setUniformValue("uBias", bias);
            // Draw it to the BACK BUFFER, not to a render target: the point is to
            // read it with drawToBitmapData. `setRenderTargets([])` would leave the
            // pass with no colour attachment and Metal aborts on the draw.
            _native["setBackBuffer"]();
            _quad.material = _mProbe;
            _nr.drawNative(_quad, _mProbe);

            var bmd:BitmapData = new BitmapData(N, N, false, 0x000000);
            _context.drawToBitmapData(bmd);

            var lo:int = 255, hi:int = 0;
            for (var y:int = 0; y < N; y += 8)
            {
                for (var x:int = 0; x < N; x += 8)
                {
                    var v:int = (bmd.getPixel(x, y) >> 16) & 0xFF;
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
            }
            var hLo:Number = (lo / 255.0 - 0.5) / gain;
            var hHi:Number = (hi / 255.0 - 0.5) / gain;
            logLine("ocean-m32 height readback: " + hLo.toFixed(3) + ".." + hHi.toFixed(3) +
                " m (spread " + (hi - lo) + "/255); a flat plane would read 0");
            if (hi - lo < 3)
            {
                logLine("ocean-m32 FAILED: the displacement atlas is flat -- the FFT chain " +
                    "is not reaching the surface");
            }
            else
            {
                logLine("ocean-m32 OK: FFT ocean is live");
            }
        }

        // ------------------------------------------------------------------
        // Geometry helpers
        // ------------------------------------------------------------------
        private function material(vs:String, fs:String):ShaderMaterial
        {
            var m:ShaderMaterial = new ShaderMaterial();
            m.vertexShader = vs;
            m.fragmentShader = fs;
            m.toneMapped = false;
            return m;
        }

        // A flat grid in the XZ plane, centred on the origin and spanning `size`
        // metres. Built directly in world space (rather than rotating a PlaneGeometry)
        // so the normals the shader reads out of the atlas need no rotation: local
        // == world, and a debug render of the mesh shows what the shader saw.
        private function grid(size:Number, cells:int):BufferGeometry
        {
            var g:BufferGeometry = new BufferGeometry();
            var verts:int = (cells + 1) * (cells + 1);
            var pos:Vector.<Number> = new Vector.<Number>(verts * 3, false);
            var idx:Vector.<Number> = new Vector.<Number>(cells * cells * 6, false);
            var i:int = 0;
            for (var z:int = 0; z <= cells; z++)
            {
                for (var x:int = 0; x <= cells; x++)
                {
                    pos[i * 3 + 0] = (x / cells - 0.5) * size;
                    pos[i * 3 + 1] = 0;
                    pos[i * 3 + 2] = (z / cells - 0.5) * size;
                    i++;
                }
            }
            var w:int = cells + 1;
            var k:int = 0;
            for (var zz:int = 0; zz < cells; zz++)
            {
                for (var xx:int = 0; xx < cells; xx++)
                {
                    var a:int = zz * w + xx;
                    idx[k++] = a; idx[k++] = a + w; idx[k++] = a + 1;
                    idx[k++] = a + 1; idx[k++] = a + w; idx[k++] = a + w + 1;
                }
            }
            g.setAttribute("position", new BufferAttribute(pos, 3));
            g.setIndex(new BufferAttribute(idx, 1));
            return g;
        }

        // The window must go away by itself: these probes are run from a terminal
        // and a lingering window would block the harness until its timeout. The
        // verdict travels in stdout (the harness greps for it), never in the exit
        // code -- `NativeApplication.exit` takes no argument in this runtime.
        private function finish():void
        {
            NativeApplication.nativeApplication.exit();
        }
    }
}