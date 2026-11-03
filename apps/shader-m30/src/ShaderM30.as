// ShaderM30.as -- M6 acceptance: the engine-side native shader path, end to end.
//
// What this proves, and why each step has to be here rather than in a C probe:
//
//   1. RendererFactory picks the backend AT RUN TIME. The same binary shape must
//      serve `--features native-shader` and a default build (and `adl`), so the
//      choice cannot be a compile-time constant. A probe on the factory is the
//      only place that claim is observable.
//   2. NativeShaderRenderer really carries a Context3DNative, and a GLSL ES 3.00
//      pair really survives the backend's own path: Metal runs glslang -> SPIR-V
//      -> SPIRV-Cross and the evidence is a translated source containing
//      `[[buffer(N)]]`; WebGL2 compiles the same text as written and the evidence
//      is the author's ES 3.00 coming back unchanged. Asserting MSL on web would
//      demand a cross-compiler that backend does not need (docs/zh-cn/native-
//      shader.md §5), and asserting nothing there would hide a passthrough that
//      never happened -- so the checks are chosen by driverInfo.
//   3. A ShaderMaterial passes through the SCENE WALK (Mesh -> material dispatch)
//      without throwing. That is the part the C-level probe cannot see: the draw
//      only reaches the native path because AGALRenderer recognises the material
//      and delegates.
//   4. When the channel is absent (adl, or a default AOT build) the answer is a
//      LOUD "no channel", never a silently wrong picture. That is the §8 red line,
//      and this demo is the one place it is checked on the AIR side too.
//
// Everything here reaches Context3DNative through `Object` + bracket calls: this
// source must compile under mxmlc, where the class does not exist (naming it in
// type position is #1046). See NativeShaderRenderer's header.
//
// Run (from as3ot3d/):
//   ./apps/shader-m30/build.sh aot --run     # expects "shader-m30 OK"
//   ./apps/shader-m30/build.sh air --run     # expects NO-CHANNEL, exit 0
package
{
    import flash.desktop.NativeApplication;
    import flash.display.BitmapData;
    import flash.events.Event;

    import asaot.three.AGALRenderer;
    import asaot.three.NativeShaderRenderer;
    import asaot.three.RendererFactory;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class ShaderM30 extends Stage3DApp
    {
        // A minimal pair: one attribute in, one uniform out, a 2-attachment-free
        // single target. `uColor` is the uniform whose reflection is asserted.
        private static const VS:String =
            "#version 300 es\n" +
            "layout(location = 0) in vec3 aPos;\n" +
            "uniform mat4 modelViewMatrix;\n" +
            "uniform mat4 projectionMatrix;\n" +
            "out vec2 vUV;\n" +
            "void main() {\n" +
            "  vUV = aPos.xy * 0.5 + 0.5;\n" +
            "  gl_Position = projectionMatrix * modelViewMatrix * vec4(aPos, 1.0);\n" +
            "}\n";

        private static const FS:String =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "in vec2 vUV;\n" +
            "uniform vec4 uColor;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  fragColor = vec4(uColor.rgb * vUV.x, 1.0);\n" +
            "}\n";

        private var _mesh:Mesh;
        private var _material:ShaderMaterial;
        private var _frames:int = 0;
        private var _failed:int = 0;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 3);

            _material = new ShaderMaterial();
            _material.name = "probe-quad";
            _material.vertexShader = VS;
            _material.fragmentShader = FS;
            _material.setUniformValue("uColor", [1.0, 0.5, 0.25, 1.0]);
            // Anonymous: the quad must not be lit or tone mapped by the engine --
            // the whole point is that the author's source is what runs.
            _material.toneMapped = false;

            // The quad is added ONLY when the channel exists. Without it the base
            // renderer refuses the material on every frame (by design: an AGAL
            // approximation of a GLSL ES 3.00 shader would be a plausible-looking
            // wrong picture), and a demo must not turn that refusal into an
            // error flood -- it should state the absence once and stop.
            if (!RendererFactory.hasNativeChannel())
            {
                return;
            }
            _mesh = new Mesh(new PlaneGeometry(2, 2), _material);
            _scene.add(_mesh);
        }

        // One frame is enough: the draw already happened by the time afterFrame
        // runs (Stage3DApp renders, then presents, then calls this).
        override protected function afterFrame(elapsedMs:Number):void
        {
            _frames++;
            if (_frames < 2) return;          // frame 1 builds the programs

            this.check("the renderer is an AGALRenderer either way (one seam)",
                _renderer is AGALRenderer);

            if (!RendererFactory.hasNativeChannel())
            {
                // This is the AIR / default-build answer and it is NOT a failure:
                // the enhancement is opt-in and the red line says the absence must
                // be stated, not approximated (native-shader.md §8).
                // logLine (System.output), not trace: adl forwards nothing from
                // trace() on macOS, so the loudest possible report would vanish.
                logLine("shader-m30 NO-CHANNEL: " + RendererFactory.describe());
                logLine("shader-m30 OK (channel absent, reported loudly; --features native-shader enables it)");
                this.finish();
                return;
            }

            this.check("the factory upgraded to NativeShaderRenderer", _renderer is NativeShaderRenderer);
            if (!(_renderer is NativeShaderRenderer))
            {
                this.finish();
                return;
            }

            var native:Object = NativeShaderRenderer(_renderer).context3DNative;
            this.check("the renderer holds a Context3DNative", native != null);
            if (native == null) { this.finish(); return; }

            // A directly uploaded program: this isolates the compiler chain from
            // anything the scene walk could have done wrong.
            var program:Object = native["uploadProgram"](VS, FS);
            this.check("GLSL ES 3.00 compiled", program != null && program["ok"]);
            if (program == null || !program["ok"])
            {
                trace("  infoLog: " + (program == null ? "(null program)" : program["infoLog"]));
                this.finish();
                return;
            }
            this.check("one colour attachment reflected", program["colorAttachments"] == 1);

            var names:String = this.joinNames(program["bindingNames"]);
            this.check("uColor is reflected", names.indexOf("uColor") >= 0);
            this.check("aPos is reflected", names.indexOf("aPos") >= 0);
            this.check("modelViewMatrix is reflected", names.indexOf("modelViewMatrix") >= 0);

            // Which language the linked backend consumes is a property of the BUILD,
            // and `driverInfo` is the AIR API that answers it. Metal CROSS-COMPILES
            // (glslang -> SPIR-V -> SPIRV-Cross writes [[buffer(N)]] and renames the
            // entry point); WebGL2 takes the author's GLSL ES 3.00 AS WRITTEN, so its
            // "translation" is the source itself. Demanding MSL on the web backend would
            // be demanding a cross-compiler WebGL2 neither needs nor has -- and asserting
            // nothing there would be the silent fake this demo exists to prevent.
            var msl:String = native["getTranslatedSource"](program, true);
            var metal:Boolean = String(_context.driverInfo).indexOf("Metal") >= 0;
            if (metal)
            {
                this.check("the vertex translation is Metal", msl != null && msl.indexOf("metal") >= 0);
                this.check("...with a reflected buffer binding", msl != null && msl.indexOf("[[buffer(") >= 0);
                this.check("...and the renamed entry point the backend compiles",
                    msl != null && msl.indexOf("vs_main") >= 0);
            }
            else
            {
                this.check("the vertex program is the author's GLSL ES 3.00",
                    msl != null && msl.indexOf("#version 300 es") >= 0);
                this.check("...passed through verbatim (declarations intact)",
                    msl != null && msl.indexOf("layout(location = 0) in vec3 aPos;") >= 0);
                this.check("...with no Metal binding syntax in it", msl != null && msl.indexOf("[[buffer(") < 0);
            }

            // The negative half of the contract: a source the channel refuses must
            // come back as ok=false with glslang's own text, not an exception and
            // not a silent success.
            var bad:Object = native["uploadProgram"]("#version 100\nattribute vec3 aPos;\nvoid main(){}\n",
                "#version 100\nvoid main(){}\n");
            this.check("ES 1.00 is refused rather than translated", bad != null && !bad["ok"]);
            this.check("...and the refusal names the version", bad != null &&
                String(bad["infoLog"]).indexOf("#version") >= 0);

            // Pixels: the checks above prove the CHAIN, not that anything reached
            // the surface. A 2x2 quad filling the camera view writes
            // vec4(uColor.rgb * uUV.x, 1) -- red 255 on the left edge, red 128 in
            // the middle -- so the centre pixel must be clearly red and clearly
            // not the black clear colour. drawToBitmapData reads the back buffer,
            // which is exactly what was just presented.
            var shot:BitmapData = new BitmapData(stage.stageWidth, stage.stageHeight, false, 0);
            _context.drawToBitmapData(shot);
            var mid:uint = shot.getPixel(shot.width >> 1, shot.height >> 1);
            // 3/8 across, still inside the quad. At 60 degrees vertical FOV, distance 3
            // and 4:3, the 2x2 plane spans only x = 142..498 of 640, so the window's
            // own left quarter is the clear colour and says nothing about vUV.
            var quarter:uint = shot.getPixel((shot.width * 3) >> 3, shot.height >> 1);
            trace("  pixel at 1/4 #" + quarter.toString(16) + ", centre #" + mid.toString(16));
            // vUV.x = 0.5 at the centre of a 2x2 plane facing the camera, so
            // uColor.rgb * 0.5 = (0.5, 0.25, 0.125) = #804020, exactly.
            this.check("the centre pixel is the author's colour", mid == 0x804020);
            this.check("the gradient follows vUV (right is brighter)", ((quarter >> 16) & 0xFF) > 0x10 &&
                ((quarter >> 16) & 0xFF) < ((mid >> 16) & 0xFF));
            shot.dispose();

            if (_failed == 0)
            {
                trace("shader-m30 OK: " + RendererFactory.describe());
                trace("  reflection: " + names);
            }
            this.finish();
        }

        private function joinNames(list:Array):String
        {
            if (list == null) return "";
            var out:String = "";
            for (var i:int = 0; i < list.length; i++)
            {
                if (i > 0) out += ",";
                out += String(list[i]);
            }
            return out;
        }

        private function check(name:String, cond:Boolean):void
        {
            if (cond) { trace("PASS " + name); return; }
            trace("FAIL " + name);
            _failed++;
        }

        // The window must go away by itself: this probe is run from a terminal and
        // a lingering window would block the harness until its timeout.
        private function finish():void
        {
            if (_failed > 0) trace("shader-m30 FAILED (" + _failed + " check(s))");
            // `NativeApplication.exit` takes no argument in this runtime (AIR's
            // errorCode parameter is not part of the seam), so the verdict travels
            // in stdout: the harness greps for "FAILED", and a silent window close
            // is never mistaken for success.
            NativeApplication.nativeApplication.exit();
        }
    }
}