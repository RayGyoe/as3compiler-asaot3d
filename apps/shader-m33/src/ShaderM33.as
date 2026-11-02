// ShaderM33.as -- E6/M3.5 capability audit: the five channel features the sky,
// caustics, reflection and underwater stages of the Ultra-Water reproduction need,
// none of which M31 proved.
//
// WHY EACH ONE IS A SEPARATE CHECK. They fail differently and the failure is silent
// in a different way:
//
//   A. GLSL helper functions   -- the atmosphere is written as helpers
//      (`medium(h)`, `transmittance(h, mu)`, `integrate(...)`) that read uniforms;
//      the known SPIRV-Cross/Metal limitation is that such a helper can fail to
//      translate at all, or translate into a function whose `constant` address-space
//      parameter cannot be bound to a thread-local argument. A pipeline written as
//      one giant main() is unmaintainable, so this has to work -- or the compiler
//      has to be fixed until it does.
//   B. dFdx/dFdy             -- the caustics splat pass builds its area ratio from
//      screen-space derivatives. Without them the caustic lines are simply absent.
//   C. additive blending     -- the same splat pass ACCUMULATES: every landed
//      triangle adds (undisturbed area / landed area) into the same texel.
//   D. render(scene, camera) into an offscreen target -- planar reflection renders
//      the whole scene from a mirrored camera. If the scene walk can only ever draw
//      to the back buffer, there is no reflection at any price.
//   E. a large non-square target -- four cascades stacked in one 256x1024 atlas is
//      one draw per IFFT stage instead of four; M31 only ever used square 64x64.
//
// Every check is a PIXEL. A structural "the object is non-null" check passes while
// the GPU writes into a texture nobody can read.
//
// Run (from asaot3d/):
//   ./apps/shader-m33/build.sh aot --run
//   ./apps/shader-m33/build.sh air --run     # expects NO-CHANNEL, exit 0
package
{
    import flash.desktop.NativeApplication;
    import flash.display.BitmapData;
    import flash.display3D.Context3DTextureFormat;

    import asaot.three.NativeShaderRenderer;
    import asaot.three.RendererFactory;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class ShaderM33 extends Stage3DApp
    {
        private static const VS:String =
            "#version 300 es\n" +
            "layout(location = 0) in vec3 aPos;\n" +
            "out vec2 vUV;\n" +
            "void main() { vUV = aPos.xy * 0.5 + 0.5; gl_Position = vec4(aPos.xy, 0.0, 1.0); }\n";

        // ---- A: helpers that read uniforms, return structs, and take samplers ----
        //
        // Shaped like the atmosphere's `medium()`/`transmittance()` pair, which is the
        // reason this check exists: if only a flat `float f(float)` worked, the sky
        // would have to be inlined by hand and would stop being reviewable.
        private static const FS_HELPERS:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform float uGain;\n" +
            "uniform sampler2D uTex;\n" +
            "uniform vec2 uUV;\n" +
            "out vec4 fragColor;\n" +
            "struct Med { vec3 scat; float ext; };\n" +
            // reads a uniform, returns a struct
            "Med medium(float h) {\n" +
            "  Med m;\n" +
            "  m.scat = vec3(1.0, 2.0, 3.0) * exp(-h);\n" +
            "  m.ext = uGain * h;\n" +
            "  return m;\n" +
            "}\n" +
            // takes a struct by value, reads a uniform
            "float total(Med m) { return m.scat.y + m.ext; }\n" +
            // takes a SAMPLER as a parameter and reads it -- the atmosphere's
            // `transmittance()` does exactly this with its LUT
            "vec3 texOf(sampler2D t, vec2 uv) { return textureLod(t, uv, 0.0).rgb; }\n" +
            "void main() {\n" +
            "  Med m = medium(0.5);\n" +
            "  fragColor = vec4(texOf(uTex, uUV).rgb + vec3(total(m) / 64.0), 1.0);\n" +
            "}\n";

        // ---- B: derivatives. fwidth of a fullscreen quad's uv is the texel size. ----
        private static const FS_DERIV:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "in vec2 vUV;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  fragColor = vec4(vUV.x, vUV.y, abs(dFdx(vUV.x)) * 64.0, abs(dFdy(vUV.y)) * 64.0);\n" +
            "}\n";

        // ---- C: additive blending. Two draws of 0.5 must read 1.0. ----
        private static const FS_HALF:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "out vec4 fragColor;\n" +
            "void main() { fragColor = vec4(0.5, 0.25, 0.0, 1.0); }\n";

        // ---- D: a camera-projected mesh, to prove the offscreen walk. ----
        private static const VS_WORLD:String =
            "#version 300 es\n" +
            "layout(location = 0) in vec3 position;\n" +
            "uniform mat4 projectionMatrix;\n" +
            "uniform mat4 modelViewMatrix;\n" +
            "void main() { gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }\n";

        private static const FS_RED:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "out vec4 fragColor;\n" +
            "void main() { fragColor = vec4(1.0, 0.0, 0.0, 1.0); }\n";

        // ---- E: an index ramp, so one readback pins BOTH axes of a non-square target.
        private static const FS_RAMP:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  fragColor = vec4(gl_FragCoord.x * (1.0 / 256.0), gl_FragCoord.y * (1.0 / 1024.0), 0.0, 1.0);\n" +
            "}\n";

        private static const FS_READ:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "precision highp int;\n" +
            "uniform sampler2D uSrc;\n" +
            "uniform ivec2 uTexel;\n" +
            "uniform int uUseLod;\n" +
            "uniform vec2 uUV;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  if (uUseLod == 1) fragColor = vec4(textureLod(uSrc, uUV, 0.0).rgb, 1.0);\n" +
            "  else fragColor = vec4(texelFetch(uSrc, uTexel, 0).rgb, 1.0);\n" +
            "}\n";

        private var _quad:Mesh;
        private var _mHelpers:ShaderMaterial;
        private var _mDeriv:ShaderMaterial;
        private var _mHalf:ShaderMaterial;
        private var _mRamp:ShaderMaterial;
        private var _mRead:ShaderMaterial;

        private var _failed:int = 0;
        private var _frames:int = 0;
        private var _ran:Boolean = false;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 5);

            _mHelpers = makeMaterial(VS, FS_HELPERS);
            _mDeriv = makeMaterial(VS, FS_DERIV);
            _mHalf = makeMaterial(VS, FS_HALF);
            _mRamp = makeMaterial(VS, FS_RAMP);
            _mRead = makeMaterial(VS, FS_READ);

            _quad = new Mesh(new PlaneGeometry(2, 2), _mHelpers);
            _quad.frustumCulled = false;
            if (RendererFactory.hasNativeChannel()) _scene.add(_quad);
        }

        private function makeMaterial(vs:String, fs:String):ShaderMaterial
        {
            var m:ShaderMaterial = new ShaderMaterial();
            m.vertexShader = vs;
            m.fragmentShader = fs;
            m.toneMapped = false;
            return m;
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            _frames++;
            if (_ran) return;
            if (_frames < 2) return;
            _ran = true;

            if (!RendererFactory.hasNativeChannel() || !(_renderer is NativeShaderRenderer))
            {
                logLine("shader-m33 NO-CHANNEL: " + RendererFactory.describe());
                logLine("shader-m33 OK (channel absent, reported loudly)");
                this.finish();
                return;
            }

            var native:Object = NativeShaderRenderer(_renderer).context3DNative;
            var W:int = 64, H:int = 64;

            // ------------------------------------------------------------
            // A. helper functions
            // ------------------------------------------------------------
            var tex:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            // fill it with (0.0, 0.5, 0.0) so a helper that failed to read the
            // sampler shows up as a missing green channel, not as a plausible colour
            drawTo(native, [tex], null, makeMaterial(VS, "#version 300 es\nprecision highp float;\nout vec4 fragColor;\nvoid main(){ fragColor = vec4(0.0, 0.5, 0.0, 1.0); }\n"), true);

            _mHelpers.setUniformValue("uGain", 64.0);
            _mHelpers.setUniformValue("uTex", tex);
            _mHelpers.setUniformValue("uUV", [0.5, 0.5]);
            // expected: green 0.5 (127) + (2*exp(-0.5) + 64*0.5)/64 = 0.5189 + 0.5 = 1.0189 -> clamps
            // So scale down: total/64 = (1.213 + 32)/64 = 0.5189. green = 0.5 + 0.5189 = 1.0189.
            // To keep it in range the shader's divisor is 64 and uGain is 8 ->
            // (1.213 + 4)/64 = 0.0814; green = 0.5814 (148), red = 0.0814 (20).
            _mHelpers.setUniformValue("uGain", 8.0);
            var ph:uint = blitAndRead(native, _mHelpers);
            var hr:int = (ph >> 16) & 0xFF, hg:int = (ph >> 8) & 0xFF;
            this.check("helpers read uniforms, structs and sampler params (r=" + hr + " g=" + hg + ")",
                Math.abs(hg - 148) <= 3 && Math.abs(hr - 21) <= 4);

            // ------------------------------------------------------------
            // B. derivatives
            // ------------------------------------------------------------
            var deriv:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            drawTo(native, [deriv], null, _mDeriv, true);
            var pd:uint = readTarget(native, deriv);
            var dx:int = (pd >> 16) & 0xFF, dy:int = (pd >> 8) & 0xFF, dw:int = pd & 0xFF;
            // uv spans 0..1 over W pixels, so |d/dx| = 1/W = 1/64; scaling by 64
            // makes the expectation exactly 1.0 -- and an implementation that
            // returns 0 (no derivatives) or garbage lands nowhere near it.
            this.check("dFdx/dFdy are live (|ddx|*64=" + dy + " |ddy|*64=" + dw + ")",
                Math.abs(dy - 255) <= 3 && Math.abs(dw - 255) <= 3);

            // ------------------------------------------------------------
            // C. additive blending
            // ------------------------------------------------------------
            var addt:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            native["setRenderTargets"]([addt], null);
            _context.clear(0, 0, 0, 1);
            _context.setBlendFactors("one", "zero");
            _quad.material = _mHalf;
            NativeShaderRenderer(_renderer).drawNative(_quad, _mHalf);
            _context.setBlendFactors("one", "one");
            NativeShaderRenderer(_renderer).drawNative(_quad, _mHalf);
            _context.setBlendFactors("one", "zero");
            // 0.5 + 0.5 = 1.0 and 0.25 + 0.25 = 0.5
            var pa:uint = readTarget(native, addt);
            var ar:int = (pa >> 16) & 0xFF, ag:int = (pa >> 8) & 0xFF;
            this.check("additive blending accumulates (r=" + ar + "/255 g=" + ag + "/128)",
                Math.abs(ar - 255) <= 2 && Math.abs(ag - 128) <= 2);

            // ------------------------------------------------------------
            // D. render(scene, camera) into an offscreen target
            // ------------------------------------------------------------
            var scene:Scene = new Scene();
            scene.background = new Color(0x000000);
            var box:Mesh = new Mesh(new PlaneGeometry(1, 1), makeMaterial(VS_WORLD, FS_RED));
            box.frustumCulled = false;
            scene.add(box);
            var cam:PerspectiveCamera = new PerspectiveCamera(60, 1.0, 0.1, 100);
            cam.position.set(0, 0, 5);
            // lookAt takes (x, y, z): three arguments, not a Vector3 -- the M32 round
            // cost a build to that signature, so the check spells it out.
            cam.lookAt(0, 0, 0);

            var refl:Object = native["createTexture"](W, H, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            native["setRenderTargets"]([refl], null);
            _renderer.render(scene, cam);
            native["setBackBuffer"]();

            // The centre, not (0,0): the box is 11 px wide on a 64 px target, so
            // reading the corner would pass for the wrong reason ("nothing drew").
            var pc:uint = readTargetAt(native, refl, 32, 32);
            var cr:int = (pc >> 16) & 0xFF, cg:int = (pc >> 8) & 0xFF;
            this.check("render(scene, camera) draws into a bound target (centre r=" + cr + " g=" + cg + ")",
                cr > 200 && cg < 40);

            // The corner must stay at the clear colour: a target that received the
            // quad but NOT the projection would be all-red, which this rejects.
            _mRead.setUniformValue("uSrc", refl);
            _mRead.setUniformValue("uTexel", [1, 1]);
            _mRead.setUniformValue("uUseLod", 0);
            _mRead.setUniformValue("uUV", [0.0, 0.0]);
            var pk:uint = blitAndRead(native, _mRead);
            this.check("the offscreen walk honours the camera's frustum (corner r=" +
                (((pk >> 16) & 0xFF)) + ")", ((pk >> 16) & 0xFF) < 40);

            // ------------------------------------------------------------
            // E. a 256x1024 atlas
            // ------------------------------------------------------------
            var atlas:Object = native["createTexture"](256, 1024, Context3DTextureFormat.RGBA_HALF_FLOAT, true);
            drawTo(native, [atlas], null, _mRamp, true);
            _mRead.setUniformValue("uSrc", atlas);
            _mRead.setUniformValue("uTexel", [200, 900]);
            _mRead.setUniformValue("uUseLod", 0);
            var pr:uint = blitAndRead(native, _mRead);
            var rr:int = (pr >> 16) & 0xFF, rg:int = (pr >> 8) & 0xFF;
            // 200.5/256 = 0.7832 (200), 900.5/1024 = 0.8794 (224)
            this.check("a 256x1024 atlas keeps both axes (r=" + rr + "/200 g=" + rg + "/224)",
                Math.abs(rr - 200) <= 3 && Math.abs(rg - 224) <= 3);

            // and the same texel through the SAMPLER path (textureLod at its centre),
            // which is what the surface shader uses
            _mRead.setUniformValue("uUseLod", 1);
            _mRead.setUniformValue("uUV", [(200.5) / 256.0, (900.5) / 1024.0]);
            var ps:uint = blitAndRead(native, _mRead);
            var sr:int = (ps >> 16) & 0xFF, sg:int = (ps >> 8) & 0xFF;
            this.check("sampling the atlas centre matches texelFetch (r=" + sr + " g=" + sg + ")",
                Math.abs(sr - rr) <= 2 && Math.abs(sg - rg) <= 2);

            if (_failed == 0) logLine("shader-m33 OK: helpers, derivatives, blending, offscreen walk, atlas");
            this.finish();
        }

        private function drawTo(native:Object, colors:Array, depth:Object, material:ShaderMaterial,
                                clearIt:Boolean):void
        {
            native["setRenderTargets"](colors, depth);
            if (clearIt) _context.clear(0, 0, 0, 1);
            _quad.material = material;
            NativeShaderRenderer(_renderer).drawNative(_quad, material);
        }

        private function readTarget(native:Object, tex:Object):uint
        {
            return readTargetAt(native, tex, 0, 0);
        }

        private function readTargetAt(native:Object, tex:Object, x:int, y:int):uint
        {
            _mRead.setUniformValue("uSrc", tex);
            _mRead.setUniformValue("uTexel", [x, y]);
            _mRead.setUniformValue("uUseLod", 0);
            _mRead.setUniformValue("uUV", [0.0, 0.0]);
            return blitAndRead(native, _mRead);
        }

        private function hex(v:uint):String
        {
            var s:String = v.toString(16);
            while (s.length < 8) s = "0" + s;
            return "#" + s;
        }

        private function blitAndRead(native:Object, material:ShaderMaterial):uint
        {
            native["setBackBuffer"]();
            _context.clear(0, 0, 0, 1);
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
            if (cond) { logLine("PASS " + name); return; }
            logLine("FAIL " + name);
            _failed++;
        }

        private function finish():void
        {
            if (_failed > 0) logLine("shader-m33 FAILED (" + _failed + " check(s))");
            try { NativeApplication.nativeApplication.exit(); } catch (e:Error) { }
        }
    }
}