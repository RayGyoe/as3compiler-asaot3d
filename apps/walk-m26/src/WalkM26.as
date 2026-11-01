// WalkM26.as -- M26 acceptance demo: the three.js `webgl_animation_walk` example,
// ported onto the asaot3d kit.
//
// What this demo is FOR (M26 = the "walk" half of the three.js parity audit,
// three-api-design.md §28.1):
//
//   1. KEYBOARD. The reference reads DOM `keydown`/`keyup`; a Stage3D app reads
//      flash.events.KeyboardEvent. Stage3DApp now owns that bridge and exposes
//      `keys` (isDown / justPressed), so this demo contains no event plumbing at
//      all -- only key queries.
//
//   2. CROSSFADE WITH WARP. Idle -> Walk -> Run switches fade over 0.5 s. Walk and
//      Run are different LENGTHS (the run cycle is shorter), so a plain fade
//      would drift the feet out of phase mid-transition; `crossFadeTo(a, d, true)`
//      ramps the two time scales by the duration ratio for exactly the fade window
//      (three.js's WarpSpeed, D80 lifted in M26).
//
//   3. SKELETON VISUALISATION. `SkeletonHelper` (toggled with H) draws the bone
//      hierarchy as per-vertex-coloured line segments, which needed a real
//      addition to the line program (va3 -> v1, D149): Stage3D has no LINES
//      primitive, every segment is a screen-space quad here.
//
// Controls: arrows or WASD to move, Shift to run, H to toggle the skeleton,
// E to toggle the castle environment map, left-drag to orbit the camera.
//
// ENVIRONMENT IS OFF BY DEFAULT, because the reference has none: r187's
// webgl_animation_walk lights the scene with ONE directional light (intensity 5)
// plus ACES tone mapping at exposure 0.5, and the model is varnished metal with
// `metalnessMap = map`. A metal without an environment map has nothing to
// reflect, so the reference reads as a dark, glossy silhouette -- which is what
// the screenshot shows. Hanging the castle cube on it (the first M26 cut) lit the
// armour from every direction and made the demo look nothing like the reference.
// The cube is still loaded at start-up and one key press puts it back, so the
// IBL path stays exercisable on demand.
//
// Asset: Soldier.glb is three.js's own (r187 `examples/models/gltf/Soldier.glb`),
// copied into assets/ so the port runs on exactly the bytes the reference does.
//
// Every asset path below is "app:/assets/...", not "assets/...". A bare relative
// path is resolved against the CWD by as-aot and against the SWF directory by
// AIR, so it only ever worked when launched from the repo root -- double-clicking
// the built binary (cwd "/") failed all nine loads and then threw #1009 every
// frame. "app:/" is resolved against the application directory by BOTH runtimes
// (as_app_dir() / File.applicationDirectory), and build-demo.sh symlinks assets/
// next to each artifact, so the path no longer depends on where it is started.
//
// Build/run from asaot3d/:
//   ./apps/walk-m26/build.sh aot --run
//   ./apps/walk-m26/build.sh air --run
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
    import asaot.three.helpers.SkeletonHelper;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.lights.DirectionalLightShadow;
    import asaot.three.lights.DirectionalLightShadow;
    import asaot.three.loaders.CubeTextureLoader;
    import asaot.three.loaders.GLTFLoader;
    import asaot.three.loaders.TextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Fog;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.Texture;

    import flash.ui.Keyboard;

    public class WalkM26 extends Stage3DApp
    {
        // Reference constants (webgl_animation_walk.html `controls`).
        private static const FADE_DURATION:Number = 0.5;
        private static const WALK_VELOCITY:Number = 1.8;
        private static const RUN_VELOCITY:Number = 5;
        private static const TURN_STEP:Number = 0.05;

        private var _controls:OrbitControls;
        private var _group:Group;                 // the moving character rig
        private var _follow:Group;                // the light rig that follows it
        private var _model:Object3D;              // gltf.scene
        private var _skeleton:SkeletonHelper;
        private var _loader:GLTFLoader;

        private var _mixer:AnimationMixer;
        private var _idle:AnimationAction;
        private var _walk:AnimationAction;
        private var _run:AnimationAction;
        private var _current:String = "Idle";

        private var _floor:Mesh;

        // Castle environment (see the header: loaded always, applied on demand).
        private var _cube:CubeTexture;
        private var _envOn:Boolean = false;
        private var _floorDecale:Number = 12.5;

        // Scratch (per-frame allocation is forbidden; see AGENTS.md memory rules).
        private var _position:Vector3 = new Vector3();
        private var _ease:Vector3 = new Vector3();
        private var _up:Vector3 = new Vector3(0, 1, 0);
        private var _turn:Quaternion = new Quaternion();
        private var _targetOffset:Vector3 = new Vector3(0, 1, 0);

        private var _frame:int = 0;

        override protected function createScene():void
        {
            _scene = new Scene();
            // The reference's grey backdrop + depth cue. Note it uses NO
            // environment map: `E` attaches the castle cube on demand (see
            // onEnvironment), so the default frame matches webgl_animation_walk.
            _scene.background = new Color(0x5e5d5d);
            _scene.fog = new Fog(0x5e5d5d, 2, 20);

            // webgl_animation_walk sets two renderer knobs that the kit does NOT
            // default to: ACES filmic tone mapping at exposure 0.5. AGALRenderer
            // starts at NoToneMapping / 1.0 (three.js r187's own default), so
            // omitting these renders raw LINEAR colour -- darker and more
            // saturated than the reference, which is exactly how the first M26 cut
            // looked next to the screenshot. These are renderer settings, not
            // material ones, so they belong here and not in createScene's siblings.
            renderer.toneMapping = AGALRenderer.ACESFilmicToneMapping;
            renderer.toneMappingExposure = 0.5;

            _camera = new PerspectiveCamera(45, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 2, -5);

            _group = new Group();
            _scene.add(_group);

            _follow = new Group();
            _scene.add(_follow);

            // Key light with a tight shadow box around the character: the reference
            // moves the light rig WITH the character (`followGroup.position`), so a
            // 4x4-unit shadow frustum stays valid no matter how far it walks.
            var key:DirectionalLight = new DirectionalLight(0xffffff, 5);
            key.position.set(-2, 5, -3);
            key.castShadow = true;
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
            _controls.enableDamping = true;
            _controls.enablePan = false;
            _controls.maxPolarAngle = Math.PI * 0.5 - 0.05;
            _controls.setSize(stage.stageWidth, stage.stageHeight);
            _controls.update();

            // Loaded up front but NOT attached: see the header. This is the LDR
            // six-face castle cube, not the HDR panorama the run/IDLE-only
            // references use -- HDR loading is M25's job (§28.5).
            var urls:Vector.<String> = new Vector.<String>();
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/px.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/nx.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/py.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/ny.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/pz.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/nz.jpg");
            var cubeLoader:CubeTextureLoader = new CubeTextureLoader();
            cubeLoader.load(urls, onEnvironment, null, onAssetError);

            _loader = new GLTFLoader();
            _loader.load("app:/assets/models/gltf/Soldier.glb", onModelLoaded, null, onAssetError);
        }

        private function onAssetError(e:Object):void
        {
            logLine("WalkM26 asset error: " + e);
        }

        private function onEnvironment(cube:CubeTexture):void
        {
            // Deliberately not assigned: `scene.environment` stays null (the
            // renderer then forces envMapIntensity 0 and the neutral white cube
            // contributes nothing), which is the reference's lighting model.
            _cube = cube;
            logLine("WalkM26 environment: " + cube.faceSize() + "px cube loaded, off (E toggles)");
        }

        private function setEnvironment(on:Boolean):void
        {
            if (_cube == null) return;
            _envOn = on;
            _scene.environment = on ? _cube : null;
            logLine("WalkM26 environment: " + (on ? "on" : "off"));
        }

        private function buildFloor():void
        {
            var geometry:PlaneGeometry = new PlaneGeometry(50, 50, 50, 50);
            // three.js rotates the GEOMETRY (geometry.rotateX); this kit's
            // BufferGeometry has no applyMatrix4 yet, so the mesh carries the
            // rotation instead -- identical result for a single-use plane.

            var material:MeshStandardMaterial = new MeshStandardMaterial();
            material.color.setHex(0x404040);
            material.roughness = 0.85;
            // The floor is decorative and receives shadows; writing depth would
            // z-fight with the character's shadow pass for no gain (the reference
            // sets depthWrite: false for the same reason).
            material.depthWrite = false;
            material.normalScale.set(0.5, 0.5);

            // The reference's ACTUAL floor pair (webgl_animation_walk addFloor):
            // FloorsCheckerboard_S_Diffuse/Normal, NOT the generic checker.png +
            // bead-normal.png. Those two are different photos -- a strong black and
            // white board with bead rings, versus a photographed dark studio floor
            // -- so the first M26 cut rendered a visibly louder, higher-contrast
            // ground under the same material numbers.
            var map:Texture = new TextureLoader().load("app:/assets/textures/floors/FloorsCheckerboard_S_Diffuse.jpg", null, null, onAssetError);
            map.colorSpace = Texture.SRGBColorSpace;
            map.wrapS = Texture.RepeatWrapping;
            map.wrapT = Texture.RepeatWrapping;
            map.repeat.set(16, 16);
            material.map = map;

            var normal:Texture = new TextureLoader().load("app:/assets/textures/floors/FloorsCheckerboard_S_Normal.jpg", null, null, onAssetError);
            normal.wrapS = Texture.RepeatWrapping;
            normal.wrapT = Texture.RepeatWrapping;
            normal.repeat.set(16, 16);
            material.normalMap = normal;

            _floor = new Mesh(geometry, material);
            _floor.rotation.x = -Math.PI * 0.5;
            _floor.receiveShadow = true;
            _scene.add(_floor);
        }

        private function onModelLoaded(root:Object3D):void
        {
            _model = root;
            _group.add(_model);
            // The asset is authored facing +Z; the reference turns both the model
            // and the rig by PI so "forward" is the camera's forward.
            _model.rotation.y = Math.PI;
            _group.rotation.y = Math.PI;

            _model.traverse(applyReferenceMaterials);

            _skeleton = new SkeletonHelper(_model);
            _skeleton.setColors(new Color(0xe000ff), new Color(0x00e0ff));
            _skeleton.visible = false;
            _scene.add(_skeleton);

            _mixer = new AnimationMixer(_model);
            // Soldier.glb clip order is [Idle, Run, TPose, Walk]; the reference
            // picks by INDEX, so a re-authored asset would silently pick different
            // clips -- the log line below makes that visible.
            _idle = _mixer.clipAction(_loader.animations[0]);
            _run = _mixer.clipAction(_loader.animations[1]);
            _walk = _mixer.clipAction(_loader.animations[3]);

            _idle.play();
            _current = "Idle";

            logLine("WalkM26 model: clips=" + _loader.animations.length +
                    " idle=" + _idle.getClip().name +
                    " run=" + _run.getClip().name +
                    " walk=" + _walk.getClip().name +
                    " idleLen=" + round3(_idle.getClip().duration) +
                    " walkLen=" + round3(_walk.getClip().duration) +
                    " runLen=" + round3(_run.getClip().duration));
        }

        // The reference's per-node material tweaks (webgl_animation_walk loadModel):
        // the body becomes varnished metal driven by its own base-colour map, the
        // visor becomes a transparent mirror.
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
                material.metalness = 1.0;
                material.roughness = 0.2;
                material.color.setRGB(1, 1, 1);
                material.metalnessMap = material.map;
            }
            else
            {
                // The visor: a transparent, mirror-smooth metal, exactly as the
                // reference sets it.
                material.metalness = 1.0;
                material.roughness = 0.0;
                material.transparent = true;
                material.opacity = 0.8;
                material.color.setRGB(1, 1, 1);
            }
        }

        // ------------------------------------------------------------------
        // per-frame
        // ------------------------------------------------------------------

        override protected function updateFrame(elapsedMs:Number):void
        {
            var delta:Number = elapsedMs / 1000;

            var forward:int = 0;
            var strafe:int = 0;
            if (keys.isDown(Keyboard.UP) || keys.isDown(Keyboard.W)) forward = -1;
            if (keys.isDown(Keyboard.DOWN) || keys.isDown(Keyboard.S)) forward = 1;
            if (keys.isDown(Keyboard.LEFT) || keys.isDown(Keyboard.A)) strafe = -1;
            if (keys.isDown(Keyboard.RIGHT) || keys.isDown(Keyboard.D)) strafe = 1;
            var running:Boolean = keys.isDown(Keyboard.SHIFT);

            // Skeleton toggle is an EDGE, not a level: justPressed is true for
            // exactly one frame, which is what a toggle needs.
            if (keys.justPressed(Keyboard.H) && _skeleton != null)
            {
                _skeleton.visible = !_skeleton.visible;
                logLine("WalkM26 skeleton: " + _skeleton.visible);
            }

            if (keys.justPressed(Keyboard.E)) setEnvironment(!_envOn);

            var active:Boolean = !(forward == 0 && strafe == 0);
            var next:String = active ? (running ? "Run" : "Walk") : "Idle";
            if (next != _current) switchAction(next);

            if (_mixer != null) updateCharacter(forward, strafe, delta);
            if (_mixer != null) _mixer.update(delta);
            if (_controls != null) _controls.update();

            _frame++;

            if (_frame % 60 == 0) logState();
        }

        // Idle -> Walk/Run -> Idle transitions.
        //
        // This is three.js's `crossFadeTo` path with two M26 capabilities the M12
        // port did not have:
        //   * `warp` ramps both time scales by the clip-duration ratio, so the walk
        //     and run cycles stay phase-locked through the fade;
        //   * `syncWith`-style phase matching is done by hand here because Walk and
        //     Run are DIFFERENT clips: the same FRACTION of each cycle (not the same
        //     number of seconds) is what keeps the feet in step.
        private function switchAction(next:String):void
        {
            var incoming:AnimationAction = (next == "Run") ? _run : ((next == "Walk") ? _walk : _idle);
            var outgoing:AnimationAction = (_current == "Run") ? _run
                : ((_current == "Walk") ? _walk : _idle);

            var wasLocomotion:Boolean = (_current != "Idle");
            var isLocomotion:Boolean = (next != "Idle");

            incoming.reset();
            incoming.weight = 1.0;
            incoming.stopFading();

            // Phase match only between two locomotion clips: matching an idle pose
            // to a walk cycle would put the feet at a random point of the stride.
            if (wasLocomotion && isLocomotion)
            {
                incoming.time = outgoing.time * (incoming.getClip().duration / outgoing.getClip().duration);
            }

            incoming.play();
            // warp only makes sense when both clips are cycles of the same gait.
            outgoing.crossFadeTo(incoming, FADE_DURATION, wasLocomotion && isLocomotion);

            _current = next;
            logLine("WalkM26 action: " + next +
                    " warp=" + (wasLocomotion && isLocomotion) +
                    " time=" + round3(incoming.time));
        }

        private function updateCharacter(forward:int, strafe:int, delta:Number):void
        {
            if (_current == "Idle") return;

            var velocity:Number = (_current == "Run") ? RUN_VELOCITY : WALK_VELOCITY;
            var azimuth:Number = _controls.getAzimuthalAngle();

            // Movement is in CAMERA space: pressing "up" walks away from the
            // camera wherever the orbit has been left.
            _ease.set(strafe, 0, forward).multiplyScalar(velocity * delta);

            var angle:Number = unwrapRad(Math.atan2(_ease.x, _ease.z) + azimuth);
            _turn.setFromAxisAngle(_up, angle);
            _ease.applyAxisAngle(_up, azimuth);

            _position.add(_ease);
            _camera.position.add(_ease);

            _group.position.copy(_position);
            // Turn toward the movement direction at a fixed step instead of
            // snapping: TURN_STEP is rad per frame in the reference too.
            _group.quaternion.rotateTowards(_turn, TURN_STEP);

            _controls.target.copy(_position).add(_targetOffset);
            _follow.position.copy(_position);

            // Slide the floor instead of growing it: the checker pattern is
            // periodic, so shifting by one tile period is invisible and keeps the
            // character on solid ground forever.
            var dx:Number = _position.x - _floor.position.x;
            var dz:Number = _position.z - _floor.position.z;
            if (Math.abs(dx) > _floorDecale) _floor.position.x += dx;
            if (Math.abs(dz) > _floorDecale) _floor.position.z += dz;
        }

        private function unwrapRad(r:Number):Number
        {
            return Math.atan2(Math.sin(r), Math.cos(r));
        }

        private function logState():void
        {
            // `getEffectiveWeight()` is three.js's field verbatim, and three.js
            // leaves it at its constructor value (1) for an action that was never
            // played -- so a raw dump reads "all weights 1" while only Idle is
            // actually contributing. Gate the weight by `isRunning()` (the demo's
            // own presentation choice, not a semantic change).
            logLine("WalkM26 f=" + _frame +
                    " action=" + _current +
                    " idleW=" + liveWeight(_idle) +
                    " walkW=" + liveWeight(_walk) +
                    " runW=" + liveWeight(_run) +
                    " walkTS=" + round3(_walk._effectiveTimeScale) +
                    " runTS=" + round3(_run._effectiveTimeScale) +
                    " pos=" + round3(_position.x) + "," + round3(_position.z) +
                    " skeleton=" + (_skeleton != null && _skeleton.visible) +
                    " env=" + _envOn +
                    " calls=" + _renderer.drawCalls +
                    " tris=" + _renderer.triangles);
        }

        private function liveWeight(a:AnimationAction):Number
        {
            return a.isRunning() ? round3(a.getEffectiveWeight()) : 0;
        }

        override protected function onViewportResize(w:int, h:int):void
        {
            if (_controls != null) _controls.setSize(w, h);
        }

        private static function round3(v:Number):Number
        {
            return Math.round(v * 1000) / 1000;
        }
    }
}