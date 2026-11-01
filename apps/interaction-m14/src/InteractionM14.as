// InteractionM14.as -- M14 interaction demo: pick + orbit.
//
// The two halves of M14 that a user can actually feel:
//
//   1. OrbitControls: left-drag orbits around the target, the wheel dollies,
//      right-drag pans (three.js r187 defaults). Everything is driven by the
//      AIR stage events, so no extra glue is needed in the app -- the control
//      listens to the InteractiveObject it is handed (here, the stage).
//   2. Raycaster picking: a CLICK (press and release within a few pixels) runs
//      a ray through the cursor and reports the nearest front-facing triangle,
//      with its world point, distance, face index and interpolated uv/normal.
//      A drag never picks -- the threshold is what separates the two gestures
//      on the same button.
//
// Hover is deliberately NOT raycast per mouse-move: at 60 Hz over a scene of
// indexed boxes that is thousands of triangle tests per second for a purely
// cosmetic effect. Click picking is the M14 contract; hover is left out and
// registered as a divergence.
package
{
    import flash.events.MouseEvent;

    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.controls.OrbitControls;
    import asaot.three.core.Intersection;
    import asaot.three.core.Raycaster;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.TorusGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class InteractionM14 extends Stage3DApp
    {
        private var _controls:OrbitControls;
        private var _raycaster:Raycaster;

        // The pickable objects live under one group so a single recursive
        // intersectObjects() walks exactly them and never the ground.
        private var _pickables:Group;
        private var _materials:Vector.<MeshStandardMaterial>;
        private var _names:Vector.<String>;

        private var _hovered:int = -1;
        private var _selected:int = -1;

        // A press that moves more than this many stage pixels is a DRAG (orbit),
        // not a CLICK. 5 px is the usual "unintentional tremor" allowance.
        private static const CLICK_SLOP:int = 5;

        private var _pressed:Boolean = false;
        private var _pressX:Number = 0;
        private var _pressY:Number = 0;

        private var _frames:int = 0;
        private var _picks:int = 0;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(50, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 5.5, 13);
            _camera.lookAt(0, 1.2, 0);
            _camera.updateMatrixWorld(true);

            _raycaster = new Raycaster();

            // ---- ground: not pickable, only a shadow receiver --------------
            var groundMat:MeshStandardMaterial = new MeshStandardMaterial();
            groundMat.color.setHex(0x7c808c);
            groundMat.roughness = 0.95;
            groundMat.metalness = 0.0;
            var ground:Mesh = new Mesh(new PlaneGeometry(30, 30), groundMat);
            ground.rotation.x = -1.5707963267948966; // -PI/2
            ground.receiveShadow = true;
            _scene.add(ground);

            // ---- pickables -------------------------------------------------
            _pickables = new Group();
            _materials = new Vector.<MeshStandardMaterial>();
            _names = new Vector.<String>();
            _scene.add(_pickables);

            var ring:int = 6;
            var i:int = 0;
            while (i < ring)
            {
                var angle:Number = i * (2 * Math.PI / ring);
                var radius:Number = 4.2;
                var mat:MeshStandardMaterial = new MeshStandardMaterial();
                mat.color.setHex(ringColor(i));
                mat.roughness = 0.42;
                mat.metalness = 0.15;
                var box:Mesh = new Mesh(new BoxGeometry(1.5, 1.5, 1.5), mat);
                box.position.set(Math.cos(angle) * radius, 0.75, Math.sin(angle) * radius);
                box.rotation.y = -angle;
                box.castShadow = true;
                box.receiveShadow = true;
                box.name = "box" + i;
                _pickables.add(box);
                _materials.push(mat);
                _names.push("box" + i);
                i++;
            }

            // A torus in the middle: many more triangles per object, and a
            // silhouette with holes, so a click through the ring must MISS
            // unless the ray actually crosses the tube.
            var torusMat:MeshStandardMaterial = new MeshStandardMaterial();
            torusMat.color.setHex(0xe0b070);
            torusMat.roughness = 0.35;
            torusMat.metalness = 0.5;
            var torus:Mesh = new Mesh(new TorusGeometry(1.35, 0.42, 20, 48), torusMat);
            torus.position.set(0, 1.6, 0);
            torus.rotation.x = 1.5707963267948966; // stand it up, facing the camera
            torus.castShadow = true;
            torus.receiveShadow = true;
            torus.name = "torus";
            _pickables.add(torus);
            _materials.push(torusMat);
            _names.push("torus");

            // ---- lights ----------------------------------------------------
            _scene.add(new AmbientLight(0x5c6274, 0.35));

            var key:DirectionalLight = new DirectionalLight(0xfff1de, 1.1);
            key.position.set(6, 10, 5);
            key.castShadow = true;
            key.shadow.bias = -0.002;
            key.shadow.normalBias = 0.02;
            key.shadow.camera.near = 0.5;
            key.shadow.camera.far = 45;
            key.shadow.camera.left = -11;
            key.shadow.camera.right = 11;
            key.shadow.camera.top = 11;
            key.shadow.camera.bottom = -11;
            key.shadow.camera.updateProjectionMatrix();
            _scene.add(key);
            _scene.add(key.target);

            var fill:DirectionalLight = new DirectionalLight(0x8aa4ff, 0.4);
            fill.position.set(-8, 5, -7);
            fill.castShadow = false;
            _scene.add(fill);
            _scene.add(fill.target);

            // ---- controls + picking gestures --------------------------------
            // The stage is the InteractiveObject: AIR delivers mouse events to
            // the display lists that contain the cursor, and the stage receives
            // everything, so the control sees drags that start anywhere.
            _controls = new OrbitControls(_camera, stage);
            // r187 leaves `target` at the origin; the orbit centre is an app
            // decision, exactly as in the three.js examples (controls.target.set).
            // Aim it at the middle of the ring, not at the floor under the camera.
            _controls.target.set(0, 1.2, 0);
            _controls.setSize(stage.stageWidth, stage.stageHeight);
            _controls.enableDamping = true;
            _controls.dampingFactor = 0.12;
            _controls.minDistance = 4;
            _controls.maxDistance = 30;
            // Stop just short of the pole: at exactly 0 the camera's up vector
            // becomes parallel to the view direction and the orbit flips.
            _controls.maxPolarAngle = 1.52;

            _controls.update();

            stage.addEventListener(MouseEvent.MOUSE_DOWN, onPress);
            stage.addEventListener(MouseEvent.MOUSE_UP, onRelease);

            logLine("M14 demo: " + _pickables.children.length + " pickable objects; " +
                  "left-drag orbit, wheel dolly, right-drag pan, click to select");
            logLine("M14 demo: pick hit-test = Mesh.raycast (bounds + per-triangle), side=" +
                  "FrontSide, click slop=" + CLICK_SLOP + "px");
        }

        private function ringColor(i:int):int
        {
            if (i == 0) return 0xd9584a;
            if (i == 1) return 0x4a8fd9;
            if (i == 2) return 0x59b06a;
            if (i == 3) return 0xc9a13a;
            if (i == 4) return 0x9a6ad0;
            return 0x4fbdc4;
        }

        private function onPress(e:MouseEvent):void
        {
            _pressed = true;
            _pressX = e.stageX;
            _pressY = e.stageY;
        }

        private function onRelease(e:MouseEvent):void
        {
            if (!_pressed) return;
            _pressed = false;
            var dx:Number = e.stageX - _pressX;
            var dy:Number = e.stageY - _pressY;
            if (dx * dx + dy * dy > CLICK_SLOP * CLICK_SLOP)
            {
                logLine("M14 drag released after " + Math.round(Math.sqrt(dx * dx + dy * dy)) +
                      "px -- no pick (drag, not click)");
                return;
            }
            pick(e.stageX, e.stageY);
        }

        private function pick(x:Number, y:Number):void
        {
            // The camera matrix may be one frame stale between render calls
            // (OrbitControls moved it on this very event), and the ray is built
            // from matrixWorld -- refresh it or the click lands where the camera
            // USED to be.
            _camera.updateMatrixWorld(true);
            _raycaster.setFromPointer(x, y, stage.stageWidth, stage.stageHeight, _camera);

            var hits:Vector.<Intersection> = _raycaster.intersectObject(_pickables, true);
            _picks++;
            select(-1);

            if (hits.length == 0)
            {
                logLine("PICK #" + _picks + " at (" + Math.round(x) + "," + Math.round(y) +
                      ") -> nothing");
                return;
            }

            var hit:Intersection = hits[0];
            var index:int = indexOfName(hit.object.name);
            select(index);
            logLine("PICK #" + _picks + " at (" + Math.round(x) + "," + Math.round(y) + ") -> " +
                  _names[index] +
                  " distance=" + fmt(hit.distance) +
                  " point=(" + fmt(hit.point.x) + "," + fmt(hit.point.y) + "," + fmt(hit.point.z) + ")" +
                  " face=" + hit.faceIndex +
                  " normal=(" + fmt(hit.face.normal.x) + "," + fmt(hit.face.normal.y) + "," + fmt(hit.face.normal.z) + ")" +
                  (hits.length > 1 ? (" [+" + (hits.length - 1) + " behind]") : ""));
        }

        // Name lookup instead of Vector.indexOf(material): Mesh.material is typed
        // as the Material base, so comparing it with MeshStandardMaterial would be
        // an implicit coercion the compiler rejects. Object names are unique here.
        private function indexOfName(name:String):int
        {
            var i:int = 0;
            while (i < _names.length)
            {
                if (_names[i] == name) return i;
                i++;
            }
            return -1;
        }

        private function select(index:int):void
        {
            if (index == _selected) return;
            if (_selected >= 0) _materials[_selected].emissive.setHex(0x000000);
            _selected = index;
            if (index >= 0) _materials[index].emissive.setHex(0x2c4a86);
        }

        // The window is resizable: the controls' pixel-to-angle scale depends on
        // the viewport size. The back buffer and the projection aspect are the
        // host's job now (Stage3DApp.applyViewportSize), so leaving either of
        // them stale -- which silently distorts the picking ray relative to what
        // is drawn -- is no longer possible.
        override protected function onViewportResize(w:int, h:int):void
        {
            _controls.setSize(w, h);
            logLine("M14 resize -> " + w + "x" + h + " aspect=" + fmt(Stage3DApp.aspectFor(w, h)));
        }

        private function fmt(v:Number):String
        {
            var r:Number = Math.round(v * 1000) / 1000;
            return r.toString();
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frames++;
            _controls.update();
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_frames == 1)
            {
                logLine("M14 demo frame 1 rendered; controls distance=" + fmt(_controls.getDistance()));
            }
        }
    }
}