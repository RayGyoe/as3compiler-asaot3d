// M26Parity.as -- DETERMINISTIC pixel-parity harness for apps/walk-m26.
//
// Why this app exists (three-api-design.md §29.8 / §32):
//
//   Every earlier AOT-vs-reference comparison read numbers off a SCREENSHOT, and
//   three things sat between the renderer and the number:
//     1. window chrome -- an AOT capture carries ~32 CSS px of titlebar, so the
//        same fractional box lands on a different part of the surface;
//     2. capture scaling -- `screencapture` may resample;
//     3. animation phase -- walk-m26 animates, so "the mean brightness of the
//        body" is a function of wall-clock time.
//   Point 3 is what produced the phantom "AOT is brighter than AIR" residual: at
//   1000x800 vs 1000x768 the same box covered different normals, and GGX's tail
//   amplified that into a 0.669-vs-0.593 dotNH reading.
//
//   This app removes all three. It renders ONE frozen frame at a FIXED stage size
//   and reads the pixels back through Context3D.drawToBitmapData -- no window
//   capture, no titlebar, no scaling, no animation time. `tools/refscene/walk-m26.html`
//   grows a matching ?w/?h pair so the reference can be rendered at the same size,
//   and `__stats()` there uses the identical fractional-box/luma convention.
//
//   What it prints is the ONLY thing worth comparing: mean/p50/p90 luma of two
//   fractional boxes (body + floor), for fog ON and fog OFF. p50 separates "the
//   whole region is lifted" (fog/ambient-like) from "the specular tail is wrong"
//   (BRDF-like): both move the mean, only the second moves p90 much more than p50.
//
// Scene parameters are copied verbatim from apps/walk-m26 (which copied them from
// the reference): 45-degree camera at (0,2,-5) looking at (0,1,0), one
// DirectionalLight intensity 5 with a 1024 shadow map over a 4x4 frustum, ACES
// tone mapping at exposure 0.5, grey 0x5e5d5d background + Fog(2,20), checker
// floor with the reference's own diffuse/normal pair, body = metalness 1 /
// roughness 0.2 / white / metalnessMap = map, visor = transparent mirror.
//
// Build/run from asaot3d/:
//   ./apps/m26-parity/build.sh aot --run     (prints PARITY lines, then exits)
package
{
    import asaot.three.animation.AnimationAction;
    import asaot.three.animation.AnimationMixer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.AGALRenderer;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.controls.OrbitControls;
    import asaot.three.core.Object3D;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.lights.DirectionalLightShadow;
    import asaot.three.loaders.GLTFLoader;
    import asaot.three.loaders.TextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Fog;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    import flash.desktop.NativeApplication;
    import flash.display.BitmapData;

    public class M26Parity extends Stage3DApp
    {
        // Fractional boxes on the STAGE (identical convention to refscene's
        // __stats and tools/refscene/boxstats.mjs).
        // Set true to mirror the reference page's `?mat=diffuse` knob: a plain
        // rough dielectric body instead of the metal one.
        // The four knobs below default to the config the §32 truth table was
        // measured with. Flipping any of them changes the meaning of the four
        // PARITY lines that get compared against tools/refscene/walk-m26.html,
        // so flip them together with the matching `?` knob on the reference page
        // and record a new table -- never leave a flipped default behind.
        private static const DIFFUSE:Boolean = false;
        private static const NO_SHADOW:Boolean = false;
        // Mirrors the reference page's `?nonormal=1`: drop the body's normal map.
        private static const NO_NORMAL:Boolean = false;
        // Mirrors the reference page's `?floor=plain`: untextured grey floor.
        private static const FLOOR_PLAIN:Boolean = false;
        // Mirrors `?floor=solid`: a 1x1 sRGB 0x808080 texture. Same decode path
        // as the checkerboard but no mips / no wrap / no spatial averaging, so
        // "solid matches but checker does not" points at the sampling setup and
        // "both are off by the same amount" points at the sRGB decode.
        private static const FLOOR_SOLID:Boolean = false;
        // Level of the ?floor=solid 1x1 texel (0x80 by default). Sweeping it splits
        // "the sRGB decode of a texel is wrong" (the ratio moves with the level)
        // from "the lighting of a mapped floor is wrong" (the ratio does not).
        private static const FLOOR_SOLID_LEVEL:int = 0x808080;
        // Mirrors `?floorcolor=`: the (sRGB) material.color of the floor, tinting
        // the checkerboard. -1 means "mode default" (0x808080 plain / 0x404040
        // mapped), which is what the §32 truth table was measured with.
        private static const FLOOR_COLOR:int = -1;
        // Mirrors `?repeat=`: checkerboard tiling. 16 is the reference value; 1
        // magnifies the texture so nothing minifies and the mip path drops out.
        private static const FLOOR_REPEAT:int = 16;
        // Mirrors `?floornormal=0`: drop the floor's normalMap so the albedo path
        // can be judged without a perturbed normal in the way.
        private static const FLOOR_NO_NORMAL:Boolean = false;

        // Rec.709 luma of the 0x5e5d5d clear colour as it reaches the back buffer
        // (0.2126*0x5e + 0.7152*0x5d + 0.0722*0x5d). It is NOT tone mapped.
        private static const BACKGROUND_LUMA:Number = 93.2126;

        private static const BODY_BOX:Array = [0.44, 0.44, 0.56, 0.62];
        private static const FLOOR_BOX:Array = [0.30, 0.80, 0.70, 0.95];

        private var _controls:OrbitControls;
        private var _group:Group;
        private var _follow:Group;
        private var _model:Object3D;
        private var _loader:GLTFLoader;
        private var _mixer:AnimationMixer;
        private var _idle:AnimationAction;

        private var _modelReady:Boolean;
        private var _frames:int;
        private var _done:Boolean;

        // Readback scratch, allocated once.
        private var _grab:BitmapData;
        private var _scratch:BitmapData;   // warm-up readback target (discarded)
        private var _prevBody:Number = -1;
        private var _prevFloor:Number = -1;
        private var _still:int;
        private var _best:Object = {};
        // "<tag> <box>" -> brightest {mean,p50,p90,n}
        // Frames rejected because a box showed the clear colour (surface absent).
        private var _dropped:int;
        // Frame-driven measurement phases: render, read, render, read (see afterFrame).
        private var _phase:int;

        override protected function createScene():void
        {
            _scene = new Scene();
            _scene.background = new Color(0x5e5d5d);
            _scene.fog = new Fog(0x5e5d5d, 2, 20);

            renderer.toneMapping = AGALRenderer.ACESFilmicToneMapping;
            renderer.toneMappingExposure = 0.5;

            _camera = new PerspectiveCamera(45, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 2, -5);

            _group = new Group();
            _scene.add(_group);

            _follow = new Group();
            _scene.add(_follow);

            var key:DirectionalLight = new DirectionalLight(0xffffff, 5);
            key.position.set(-2, 5, -3);
            key.castShadow = !NO_SHADOW;
            key.shadow.mapSize.set(1024, 1024);
            var sc:DirectionalLightShadow = key.shadow;
            sc.camera.top = 2;
            sc.camera.right = 2;
            sc.camera.bottom = -2;
            sc.camera.left = -2;
            sc.camera.near = 3;
            sc.camera.far = 8;
            sc.camera.updateProjectionMatrix();
            _follow.add(key);
            _follow.add(key.target);

            buildFloor();

            _controls = new OrbitControls(_camera, stage);
            _controls.target.set(0, 1, 0);
            _controls.enableDamping = false;
            _controls.enablePan = false;
            _controls.maxPolarAngle = Math.PI * 0.5 - 0.05;
            _controls.setSize(stage.stageWidth, stage.stageHeight);
            _controls.update();

            _loader = new GLTFLoader();
            _loader.load("app:/assets/models/gltf/Soldier.glb", onModelLoaded, null, onAssetError);

            logLine("parity config diffuse=" + DIFFUSE + " shadow=" + (!NO_SHADOW)
                    + " normalmap=" + (!NO_NORMAL)
                    + " floor=" + (FLOOR_PLAIN ? "plain" : (FLOOR_SOLID ? "solid" : "checker"))
                    + " floornormal=" + (!FLOOR_NO_NORMAL) + " repeat=" + FLOOR_REPEAT
                    + " tone=aces exposure=0.5");
            logLine("parity stage " + stage.stageWidth + "x" + stage.stageHeight
                    + " boxes body=" + BODY_BOX.join(",") + " floor=" + FLOOR_BOX.join(","));
        }

        private function onAssetError(e:Object):void
        {
            logLine("parity asset error: " + e);
        }

        private function buildFloor():void
        {
            var geometry:PlaneGeometry = new PlaneGeometry(50, 50, 50, 50);

            var material:MeshStandardMaterial = new MeshStandardMaterial();
            material.color.setHex(FLOOR_COLOR < 0
                    ? (FLOOR_PLAIN ? 0x808080 : 0x404040) : FLOOR_COLOR);
            material.roughness = 0.85;
            material.depthWrite = false;
            material.normalScale.set(0.5, 0.5);
            if (FLOOR_PLAIN)
            {
                var plainFloor:Mesh = new Mesh(geometry, material);
                plainFloor.rotation.x = -Math.PI * 0.5;
                plainFloor.receiveShadow = true;
                _scene.add(plainFloor);
                return;
            }

            var map:Texture;
            if (FLOOR_SOLID)
            {
                map = new Texture(new BitmapData(1, 1, false, FLOOR_SOLID_LEVEL));
            }
            else
            {
                map = new TextureLoader().load(
                    "app:/assets/textures/floors/FloorsCheckerboard_S_Diffuse.jpg", null, null, onAssetError);
            }
            map.colorSpace = Texture.SRGBColorSpace;
            map.wrapS = Texture.RepeatWrapping;
            map.wrapT = Texture.RepeatWrapping;
            map.repeat.set(FLOOR_REPEAT, FLOOR_REPEAT);
            material.map = map;

            if (!FLOOR_NO_NORMAL)
            {
                var normal:Texture = new TextureLoader().load(
                    "app:/assets/textures/floors/FloorsCheckerboard_S_Normal.jpg", null, null, onAssetError);
                normal.wrapS = Texture.RepeatWrapping;
                normal.wrapT = Texture.RepeatWrapping;
                normal.repeat.set(FLOOR_REPEAT, FLOOR_REPEAT);
                material.normalMap = normal;
            }

            var floor:Mesh = new Mesh(geometry, material);
            floor.rotation.x = -Math.PI * 0.5;
            floor.receiveShadow = true;
            _scene.add(floor);
        }

        private function onModelLoaded(root:Object3D):void
        {
            _model = root;
            _group.add(_model);
            _model.rotation.y = Math.PI;
            _group.rotation.y = Math.PI;
            _model.traverse(applyReferenceMaterials);

            _mixer = new AnimationMixer(_model);
            // Soldier.glb clip order is [Idle, Run, TPose, Walk]; the reference
            // picks index 0 by the same reasoning walk-m26 documents.
            _idle = _mixer.clipAction(_loader.animations[0]);
            _idle.play();
            // FROZEN AT t=0: the reference does `mixer.update(FREEZE)` once with
            // FREEZE=0 and never advances, so the pose is the clip's first frame.
            // Advancing it (even by one frame) would reintroduce the animation
            // confound this app exists to remove, hence the no-update branch in
            // updateFrame.
            _mixer.update(0);

            _modelReady = true;
            logLine("parity model: " + _idle.getClip().name + " len=" + _idle.getClip().duration);
        }

        private function applyReferenceMaterials(object:Object3D):void
        {
            if (!(object is Mesh)) return;
            var mesh:Mesh = Mesh(object);
            if (!(mesh.material is MeshStandardMaterial)) return;
            var material:MeshStandardMaterial = MeshStandardMaterial(mesh.material);

            if (object.name == "vanguard_Mesh")
            {
                mesh.castShadow = true;
                mesh.receiveShadow = true;
                if (NO_NORMAL) material.normalMap = null;
                if (DIFFUSE)
                {
                    material.metalness = 0.0;
                    material.roughness = 0.9;
                    // setHex, not setRGB: setRGB stores working-space values
                    // as-is, so `setRGB(0.5,0.5,0.5)` is linear 0.5 while the
                    // reference's `color.set(0x808080)` is linear 0.216 -- a
                    // 2.3x albedo mismatch that read as "our diffuse is +53%".
                    material.color.setHex(0x808080);
                    material.metalnessMap = null;
                    material.roughnessMap = null;
                }
                else
                {
                    material.metalness = 1.0;
                    material.roughness = 0.2;
                    material.color.setRGB(1, 1, 1);
                    material.metalnessMap = material.map;
                }
            }
            else
            {
                material.metalness = 1.0;
                material.roughness = 0.0;
                material.transparent = true;
                material.opacity = 0.8;
                material.color.setRGB(1, 1, 1);
            }
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            // Deliberately NO mixer.update: the pose is pinned (see onModelLoaded).
            _controls.update();
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_done || !_modelReady) return;
            _frames++;
            // Wait a few frames so the async image decodes (floor + body maps)
            // have landed and the renderer has uploaded them; 20 frames is far
            // more than the decode needs and costs ~0.3 s.
            if (_frames < 60) return;

            // Stage3DApp renders + presents EVERY frame before afterFrame(), so
            // there is nothing to render here. Two quirks decide the shape of
            // this state machine:
            //
            //   1. drawToBitmapData() reads the target as of the PREVIOUS
            //      present, so a read describes the frame before it.
            //   2. The floor's base-colour map stays pending until the FIRST
            //      readback flushes the context -- until then the floor draws
            //      black, however long the app has been spinning. So the first
            //      readback is a discard ("warm") and only the reads after it are
            //      measurements.
            //
            //   f60 warm read (discard)   f60 afterFrame: discard read
            //   f61 render(fog on)        f61 afterFrame: read -> frame 60
            //   f62 render(fog on)        f62 afterFrame: set scene.fog = null
            //   f63 render(fog off)       f63 afterFrame: (wait)
            //   f64 render(fog off)       f64 afterFrame: read -> frame 63
            // The floor's base-colour map finishes its async decode at an
            // unpredictable frame (measured anywhere from frame 20 to frame 65)
            // and the floor draws BLACK until then, so the harness waits for the
            // floor to actually appear instead of guessing a frame count.
            // Everything after that is three reads per state (reads also trail
            // the render by one present, and a late frame can only ever darken a
            // region, so the brightest of three wins).
            if (_phase == 0)
            {
                // Readiness gate: BOTH boxes must hold still for 5 consecutive
                // frames. A fixed frame count is not enough -- the floor's map
                // lands anywhere in 20..65, and a scene without a textured floor
                // finishes its own uploads at a different frame again. Texture
                // uploads only ever make a surface BRIGHTER, so a still picture
                // for 5 frames means everything has landed.
                readFrame();
                var b:Number = Number(boxStats(BODY_BOX).mean);
                var f:Number = Number(boxStats(FLOOR_BOX).mean);
                var still:Boolean = Math.abs(b - _prevBody) < 0.05 && Math.abs(f - _prevFloor) < 0.05;
                _prevBody = b;
                _prevFloor = f;
                _still = still ? _still + 1 : 0;
                if (_frames < 600 && _still < 5) return;
                keepCurrent("fog=1");
                _phase = 1;
            }
            else if (_phase == 1) { readFrame(); keepCurrent("fog=1"); _phase = 2; }
            else if (_phase == 2) { readFrame(); keepCurrent("fog=1"); _phase = 3; }
            else if (_phase == 3) { _scene.fog = null; _phase = 4; }
            else if (_phase == 4) { _phase = 5; }
            else if (_phase == 5) { readFrame(); keepCurrent("fog=0"); _phase = 6; }
            else if (_phase == 6) { readFrame(); keepCurrent("fog=0"); _phase = 7; }
            else if (_phase == 7) { readFrame(); keepCurrent("fog=0"); _phase = 8; }
            else if (_phase == 8)
            {
                emit("fog=1");
                emit("fog=0");
                _scene.fog = new Fog(0x5e5d5d, 2, 20);
                _done = true;
                NativeApplication.nativeApplication.exit();
            }
        }

        // Discarded readback: flushes the context so the pending floor texture
        // lands before anything is measured.
        private function warmGrab():void
        {
            if (_scratch == null) _scratch = new BitmapData(stage.stageWidth, stage.stageHeight, false, 0x000000);
            _context.drawToBitmapData(_scratch);
        }

        // Region statistics over the back buffer of the last committed frame.
        // drawToBitmapData converts that frame's BGRA into BitmapData ARGB, so
        // what we measure is exactly the stage surface -- not the window, not a
        // screenshot, no titlebar and no capture scaling in the way.
        private function readFrame():void
        {
            if (_grab == null) _grab = new BitmapData(stage.stageWidth, stage.stageHeight, false, 0x000000);
            // drawToBitmapData reads presented drawables, and Metal keeps a ring
            // of them, so the first N-1 calls of a frame still return frames from
            // BEFORE the one that was just presented (measured: 0 vs 28.43 for
            // the same pixel box on the same frame). Read through the whole ring
            // and keep the newest.
            _context.drawToBitmapData(_grab);
            _context.drawToBitmapData(_grab);
            _context.drawToBitmapData(_grab);
            _context.drawToBitmapData(_grab);
        }

        // Luma mean of the floor box on the frame just read -- the harness's
        // "has the scene actually drawn yet" probe.
        private function floorMean():Number
        {
            return Number(boxStats(FLOOR_BOX).mean);
        }

        private function rowMean(y:int):Number
        {
            var w:int = _grab.width;
            var sum:Number = 0;
            var n:int = 0;
            var x:int;
            for (x = 0; x < w; x++)
            {
                var argb:uint = _grab.getPixel32(x, y);
                sum += 0.2126 * ((argb >> 16) & 0xff) + 0.7152 * ((argb >> 8) & 0xff) + 0.0722 * (argb & 0xff);
                n++;
            }
            return sum / n;
        }

        private function keepCurrent(tag:String):void
        {
            keepBest(tag + " body", BODY_BOX);
            keepBest(tag + " floor", FLOOR_BOX);
        }

        private function keepBest(key:String, box:Array):void
        {
            var s:Object = boxStats(box);
            // Guard against a DROPPED DRAW being mistaken for a bright surface.
            // The scene clears to 0x5e5d5d, which reaches the back buffer
            // verbatim (measured luma 93.21), and the plain floor's draw is
            // intermittently dropped -- so a frame with no floor in it is
            // indistinguishable from "a very bright floor" as long as the
            // brightest-sample rule is the only judge. That is exactly how
            // §32.8's phantom "2x bimodal dark floor" was produced: every
            // reading of 93.21 was the CLEAR COLOUR, not a floor.
            if (Math.abs(Number(s.mean) - BACKGROUND_LUMA) < 0.5)
            {
                _dropped++;
                return;
            }
            var prev:Object = _best[key];
            if (prev == null || Number(s.mean) > Number(prev.mean)) _best[key] = s;
        }

        private function emit(tag:String):void
        {
            logLine("PARITY " + tag + " body " + describe(_best[tag + " body"]));
            logLine("PARITY " + tag + " floor " + describe(_best[tag + " floor"]));
            if (_dropped > 0) logLine("PARITY " + tag + " dropped=" + _dropped);
        }

        private function describe(s:Object):String
        {
            return "mean=" + round2(Number(s.mean))
                 + " p50=" + round2(Number(s.p50))
                 + " p90=" + round2(Number(s.p90))
                 + " n=" + int(s.n);
        }

        // mean/p50/p90 luma over a fractional box, identical to refscene __stats
        // (Rec.709 luma, samples sorted so the quantiles are exact).
        private function boxStats(box:Array):Object
        {
            var w:int = _grab.width;
            var h:int = _grab.height;
            var x0:int = Math.round(Number(box[0]) * w);
            var x1:int = Math.round(Number(box[2]) * w);
            var y0:int = Math.round(Number(box[1]) * h);
            var y1:int = Math.round(Number(box[3]) * h);
            if (x1 <= x0) x1 = x0 + 1;
            if (y1 <= y0) y1 = y0 + 1;

            var xs:Array = [];
            var sum:Number = 0;
            var x:int;
            var y:int;
            for (y = y0; y < y1; y++)
            {
                for (x = x0; x < x1; x++)
                {
                    var argb:uint = _grab.getPixel32(x, y);
                    var r:Number = (argb >> 16) & 0xff;
                    var g:Number = (argb >> 8) & 0xff;
                    var b:Number = argb & 0xff;
                    var l:Number = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    xs.push(l);
                    sum += l;
                }
            }
            xs.sort(Array.NUMERIC);
            var n:int = xs.length;
            return { mean: sum / n, p50: Number(xs[int(n * 0.5)]), p90: Number(xs[int(n * 0.9)]), n: n };
        }

        private function round2(v:Number):Number
        {
            return Math.round(v * 100) / 100;
        }
    }
}