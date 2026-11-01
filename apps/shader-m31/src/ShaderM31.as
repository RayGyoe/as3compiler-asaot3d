// ShaderM31.as -- E6/M3 capability matrix: the four backend features an FFT ocean
// needs and that the M6 acceptance deliberately did not touch.
//
// WHY A SECOND PROBE INSTEAD OF EXTENDING shader-m30. shader-m30 proves the
// CHANNEL (compile, reflect, dispatch, one pixel). This one proves the four STORAGE
// capabilities the M7 ocean is built on, and each of them fails differently:
//
//   A. float32 render targets       -- an H0 spectrum cannot live in 8 bits, and a
//                                      value > 1 must come back unclamped
//   B. half-float precision         -- the same shader must LOSE the bits fp16
//                                      cannot hold, proving A is not just BGRA8
//   C. MRT (2 colour attachments)   -- the IFFT writes two complex fields per stage
//   D. depth texture               -- the underwater pass samples the scene depth
//   E. texelFetch + integer bitops  -- the spectrum generator is a PCG hash; it
//                                      needs exact texels and uint shifts, not
//                                      filtered floats
//
// Every check is a PIXEL, read back through drawToBitmapData from the back buffer.
// A structural check ("the object is non-null") would pass even when the GPU writes
// into a texture nobody can read, which is exactly the failure mode M3 had left
// unverified (native-shader-plan.md §2.3 marks these three "未验收").
//
// Run (from asaot3d/):
//   ./apps/shader-m31/build.sh aot --run      # expects "shader-m31 OK"
//   ./apps/shader-m31/build.sh air --run      # expects NO-CHANNEL, exit 0
package
{
    import flash.desktop.NativeApplication;
    import flash.display.BitmapData;
    import flash.display3D.Context3DTextureFormat;

    import asaot.three.AGALRenderer;
    import asaot.three.NativeShaderRenderer;
    import asaot.three.RendererFactory;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class ShaderM31 extends Stage3DApp
    {
        // One vertex program for every pass: a 2x2 plane is already clip space, so
        // the matrices are ignored. `uZ` puts a pass at a chosen depth.
        private static const VS:String =
            "#version 300 es\n" +
            "layout(location = 0) in vec3 aPos;\n" +
            "uniform float uZ;\n" +
            "out vec2 vUV;\n" +
            "void main() {\n" +
            "  vUV = aPos.xy * 0.5 + 0.5;\n" +
            "  gl_Position = vec4(aPos.xy, uZ, 1.0);\n" +
            "}\n";

        // Writes a value that 8 bits cannot hold (100.0) and a value that only fp32
        // can hold (1 + 1/4096). fp16's ulp at 1.0 is 1/1024, so the second term
        // rounds away -- that difference is what proves the storage width.
        private static const FS_WRITE:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "in vec2 vUV;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  fragColor = vec4(100.0, 100.0, 1.0 + 1.0 / 4096.0, 1.0);\n" +
            "}\n";

        // Two independent attachments. Attachment 1 is green so a pass that only
        // ever wrote attachment 0 reads back black there.
        private static const FS_MRT:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) out vec4 out0;\n" +
            "layout(location = 1) out vec4 out1;\n" +
            "void main() {\n" +
            "  out0 = vec4(1.0, 0.0, 0.0, 1.0);\n" +
            "  out1 = vec4(0.0, 1.0, 0.0, 1.0);\n" +
            "}\n";

        // Exact texel read + affine encode, so one program can assert several
        // numeric claims: `out = texel * uMul - uSub`.
        private static const FS_READ:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "precision highp int;\n" +
            "uniform sampler2D uTex;\n" +
            "uniform ivec2 uTexel;\n" +
            "uniform vec3 uMul;\n" +
            "uniform vec3 uSub;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  vec4 v = texelFetch(uTex, uTexel, 0);\n" +
            "  fragColor = vec4(v.xyz * uMul - uSub, 1.0);\n" +
            "}\n";

        // Flat colour, for the depth-occlusion test: which quad survived is only
        // readable as a colour.
        // Same vertex stage as VS, with the depth written as a literal.
        private static const VS_Z:String =
            "#version 300 es\n" +
            "layout(location = 0) in vec3 aPos;\n" +
            "void main() { gl_Position = vec4(aPos.xy, @Z@, 1.0); }\n";

        private static const FS_TINT:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform vec3 uTint;\n" +
            "out vec4 fragColor;\n" +
            "void main() { fragColor = vec4(uTint, 1.0); }\n";

        // PCG2D from OceanSim.js: uint arithmetic and bit casts. If the translator
        // turned uint into float, the hash collapses to 0 or to a repeating pattern.
        private static const FS_HASH:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "precision highp int;\n" +
            "uniform sampler2D uTex;\n" +
            "uniform uvec2 uSeed;\n" +
            "out vec4 fragColor;\n" +
            "uvec2 pcg2d(uvec2 v) {\n" +
            "  v = v * 1664525u + 1013904223u;\n" +
            "  v.x += v.y * 1664525u; v.y += v.x * 1664525u;\n" +
            "  v ^= v >> 16u;\n" +
            "  v.x += v.y * 1664525u; v.y += v.x * 1664525u;\n" +
            "  v ^= v >> 16u;\n" +
            "  return v;\n" +
            "}\n" +
            "void main() {\n" +
            "  uvec2 h = pcg2d(uSeed);\n" +
            "  // the top byte of each word: a real hash spreads it, a collapsed one pins it\n" +
            "  fragColor = vec4(float(h.x >> 24u) / 255.0, float(h.y >> 24u) / 255.0, 0.0, 1.0);\n" +
            "}\n";

        private var _quad:Mesh;
        private var _sceneQuad:Boolean = false;
        private var _failed:int = 0;
        private var _frames:int = 0;
        private var _ran:Boolean = false;

        private var _mWrite:ShaderMaterial;
        private var _mMrt:ShaderMaterial;
        private var _mRead:ShaderMaterial;
        private var _mHash:ShaderMaterial;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 3);

            _mWrite = makeMaterial(VS, FS_WRITE);
            _mMrt = makeMaterial(VS, FS_MRT);
            _mRead = makeMaterial(VS, FS_READ);
            _mHash = makeMaterial(VS, FS_HASH);

            // The quad starts on a program that actually compiles: an empty
            // ShaderMaterial would be compiled by the first frame and report
            // glslang's "missing entry point" as if the channel were broken.
            _quad = new Mesh(new PlaneGeometry(2, 2), _mWrite);
            _quad.frustumCulled = false;

            // Without the channel there is nothing to probe; the scene stays empty so
            // the base renderer never sees a ShaderMaterial (it would refuse it).
            if (RendererFactory.hasNativeChannel()) _scene.add(_quad);
        }

        private function makeMaterial(vs:String, fs:String):ShaderMaterial
        {
            var m:ShaderMaterial = new ShaderMaterial();
            m.vertexShader = vs;
            m.fragmentShader = fs;
            m.toneMapped = false;
            m.setUniformValue("uZ", 0.0);
            return m;
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            _frames++;
            if (_ran) return;
            if (_frames < 2) return;      // frame 1 builds the base programs
            _ran = true;

            if (!RendererFactory.hasNativeChannel() || !(_renderer is NativeShaderRenderer))
            {
                // logLine (System.output), not trace: adl forwards nothing from
                // trace() on macOS, so the loudest possible report would vanish.
                logLine("shader-m31 NO-CHANNEL: " + RendererFactory.describe());
                logLine("shader-m31 OK (channel absent, reported loudly)");
                this.finish();
                return;
            }

            var native:Object = NativeShaderRenderer(_renderer).context3DNative;
            var W:int = 64, H:int = 64;

            // ---- A/B: float32 vs float16 storage ------------------------------
            var f32:Object = native["createTexture"](W, H, "rgba32f", true);
            var f16:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            this.check("RGBA_FLOAT and RGBA_HALF_FLOAT are renderable", f32 != null && f16 != null);
            if (f32 == null || f16 == null) { this.finish(); return; }

            drawTo([f32], null, _mWrite, 0.0);
            drawTo([f16], null, _mWrite, 0.0);

            // texel (0,0) of the fp32 target: 100.0 must survive (8 bits clamp to 1)
            _mRead.setUniformValue("uTex", f32);
            _mRead.setUniformValue("uTexel", [0, 0]);
            _mRead.setUniformValue("uMul", [1.0 / 256.0, 1.0 / 256.0, 1.0]);
            _mRead.setUniformValue("uSub", [0.0, 0.0, 0.0]);
            var p:uint = blitAndRead(_mRead, 0.0);
            var red:int = (p >> 16) & 0xFF;
            this.check("float32 holds a value above 1.0 (got " + red + "/100)", Math.abs(red - 100) <= 1);

            // texel (0,0) of the fp16 target: the same 100.0
            _mRead.setUniformValue("uTex", f16);
            var p16:uint = blitAndRead(_mRead, 0.0);
            var red16:int = (p16 >> 16) & 0xFF;
            this.check("half float holds 100.0 too (got " + red16 + "/100)", Math.abs(red16 - 100) <= 1);

            // Precision: (z - 1) * 4096 is 1.0 on fp32 and 0.0 on fp16.
            _mRead.setUniformValue("uTex", f32);
            _mRead.setUniformValue("uMul", [0.0, 0.0, 4096.0]);
            _mRead.setUniformValue("uSub", [0.0, 0.0, 4096.0]);
            var pf:uint = blitAndRead(_mRead, 0.0);
            var bf:int = pf & 0xFF;
            this.check("float32 keeps 1 + 1/4096 (blue=" + bf + ")", bf >= 250);

            _mRead.setUniformValue("uTex", f16);
            var ph:uint = blitAndRead(_mRead, 0.0);
            var bh:int = ph & 0xFF;
            this.check("half float rounds 1 + 1/4096 away (blue=" + bh + ")", bh <= 2);

            // ---- C: MRT -------------------------------------------------------
            var m0:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            var m1:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            drawTo([m0, m1], null, _mMrt, 0.0);

            _mRead.setUniformValue("uTex", m0);
            _mRead.setUniformValue("uTexel", [0, 0]);
            _mRead.setUniformValue("uMul", [1.0, 1.0, 1.0]);
            _mRead.setUniformValue("uSub", [0.0, 0.0, 0.0]);
            var a0:uint = blitAndRead(_mRead, 0.0);
            this.check("MRT attachment 0 is red", ((a0 >> 16) & 0xFF) > 250 && ((a0 >> 8) & 0xFF) < 5);

            _mRead.setUniformValue("uTex", m1);
            var a1:uint = blitAndRead(_mRead, 0.0);
            this.check("MRT attachment 1 is green", ((a1 >> 8) & 0xFF) > 250 && ((a1 >> 16) & 0xFF) < 5);

            // ---- D: texelFetch exactness --------------------------------------
            // (48, 16) is an off-centre texel of a 64x64 target whose every texel
            // holds 100.0, so the encode is the same 1/256 the first check used:
            // writing the raw 100 would simply clamp to white and prove nothing.
            _mRead.setUniformValue("uTex", f16);
            _mRead.setUniformValue("uTexel", [48, 16]);
            _mRead.setUniformValue("uMul", [1.0 / 256.0, 1.0 / 256.0, 1.0]);
            _mRead.setUniformValue("uSub", [0.0, 0.0, 0.0]);
            var pt:uint = blitAndRead(_mRead, 0.0);
            this.check("texelFetch reads an off-centre texel (red=" + (((pt >> 16) & 0xFF)) + ")",
                Math.abs(((pt >> 16) & 0xFF) - 100) <= 1);

            // ---- E: uint bit operations (PCG hash) ----------------------------
            _mHash.setUniformValue("uSeed", [1337, 7919]);
            var h1:uint = blitAndRead(_mHash, 0.0);
            _mHash.setUniformValue("uSeed", [1338, 7919]);
            var h2:uint = blitAndRead(_mHash, 0.0);
            var hr1:int = (h1 >> 16) & 0xFF, hr2:int = (h2 >> 16) & 0xFF;
            // A working hash changes almost every input bit; a collapsed one returns
            // the same byte for both seeds (0 and 0 being the usual failure).
            this.check("pcg2d spreads the input (seed1337=" + hr1 + ", seed1338=" + hr2 + ")",
                hr1 != hr2 && (hr1 > 3 || hr2 > 3));

            // ---- F: depth TEXTURE as an attachment ----------------------------
            //
            // What is asserted here is OCCLUSION, not sampling. Sampling a depth
            // texture through `sampler2D` is not portable to Metal: SPIRV-Cross has
            // no way to learn that a GLSL `sampler2D` names a depth resource (GLSL
            // spells depth comparisons `sampler2DShadow`), so it emits
            // `texture2d<float>` and Metal reads 0 -- measured here, which is why
            // this section was rewritten. The channel therefore promises a depth
            // texture as an ATTACHMENT; a pass that needs linear depth renders it
            // into a colour target, which is what the ocean's underwater pass does.
            var dc:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            var dd:Object = native["createDepthTexture"](W, H, "depth32f");
            this.check("a depth texture is creatable", dc != null && dd != null);
            if (dc != null && dd != null)
            {
                var mRed:ShaderMaterial = tintMaterial(1, 0, 0, -0.5);
                var mGreen:ShaderMaterial = tintMaterial(0, 1, 0, 0.9);
                var mBlue:ShaderMaterial = tintMaterial(0, 0, 1, -0.9);

                _context.setDepthTest(true, "lessEqual");
                drawTo([dc], dd, mRed, -0.5, true);
                trace("  after red@-0.5: #" + readTarget(dc).toString(16));
                drawTo([dc], dd, mGreen, 0.9, false);
                var afterFar:uint = readTarget(dc);
                trace("  after green@0.9: #" + afterFar.toString(16));
                _context.setDepthTest(false, "always");
                this.check("the depth attachment rejects a farther quad",
                    ((afterFar >> 16) & 0xFF) > 200 && ((afterFar >> 8) & 0xFF) < 40);

                // Positive control: nearer geometry must still pass.
                _context.setDepthTest(true, "lessEqual");
                drawTo([dc], dd, mBlue, -0.9, false);
                _context.setDepthTest(false, "always");
                var afterNear:uint = readTarget(dc);
                trace("  after blue@-0.9: #" + afterNear.toString(16));
                this.check("the depth attachment admits nearer geometry",
                    (afterNear & 0xFF) > 200 && ((afterNear >> 16) & 0xFF) < 40);
            }

            if (_failed == 0) trace("shader-m31 OK: float32, half, MRT, depth, texelFetch, uint");
            this.finish();
        }

        // Bind `colors` (and optionally `depth`), optionally clear, draw the quad
        // once, and leave the targets bound -- the caller decides when to come back.
        //
        // `clear` is a parameter because Stage3D folds the clear into the NEXT draw:
        // clearing again before the depth test's second draw would reset depth to 1
        // and make the "farther quad is rejected" check pass for the wrong reason.
        private function drawTo(colors:Array, depth:Object, material:ShaderMaterial, z:Number,
                                clearIt:Boolean = true):void
        {
            var native:Object = NativeShaderRenderer(_renderer).context3DNative;
            native["setRenderTargets"](colors, depth);
            if (clearIt) _context.clear(0, 0, 0, 1);
            material.setUniformValue("uZ", z);
            _quad.material = material;
            NativeShaderRenderer(_renderer).drawNative(_quad, material);
        }

        // Read one texel of a render target through the back buffer. Used by the
        // depth checks, where "which colour survived" is the only observable.
        private function readTarget(tex:Object):uint
        {
            _mRead.setUniformValue("uTex", tex);
            _mRead.setUniformValue("uTexel", [0, 0]);
            _mRead.setUniformValue("uMul", [1.0, 1.0, 1.0]);
            _mRead.setUniformValue("uSub", [0.0, 0.0, 0.0]);
            return blitAndRead(_mRead, 0.0);
        }

        // z is BAKED into the vertex source instead of riding a uniform: the depth
        // checks must fail for depth reasons only, and a uniform that silently does
        // not upload would collapse all three quads onto the same depth.
        private function tintMaterial(r:Number, g:Number, b:Number, z:Number):ShaderMaterial
        {
            var m:ShaderMaterial = new ShaderMaterial();
            m.vertexShader = VS_Z.replace("@Z@", z.toFixed(6));
            m.fragmentShader = FS_TINT;
            m.toneMapped = false;
            m.setUniformValue("uTint", [r, g, b]);
            return m;
        }

        // Draw `material` over the back buffer and read one pixel out of it.
        private function blitAndRead(material:ShaderMaterial, z:Number):uint
        {
            var native:Object = NativeShaderRenderer(_renderer).context3DNative;
            native["setBackBuffer"]();
            _context.clear(0, 0, 0, 1);
            material.setUniformValue("uZ", z);
            _quad.material = material;
            NativeShaderRenderer(_renderer).drawNative(_quad, material);

            var shot:BitmapData = new BitmapData(stage.stageWidth, stage.stageHeight, false, 0);
            _context.drawToBitmapData(shot);
            var px:uint = shot.getPixel(shot.width >> 1, shot.height >> 1);
            shot.dispose();
            return px;
        }

        private function check(name:String, cond:Boolean):void
        {
            if (cond) { trace("PASS " + name); return; }
            trace("FAIL " + name);
            _failed++;
        }

        private function finish():void
        {
            if (_failed > 0) trace("shader-m31 FAILED (" + _failed + " check(s))");
            try { NativeApplication.nativeApplication.exit(); } catch (e:Error) { }
        }
    }
}