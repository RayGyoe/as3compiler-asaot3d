// StatsM15.as -- M15 performance HUD demo.
//
// What a user sees:
//
//   1. The Stats HUD in the TOP-LEFT corner, 80x48, exactly as stats.js paints
//      it: a dark tile, a 9px bold label "<value> <NAME> (<min>-<max>)", and a
//      74-column graph that scrolls one column per frame. The right-hand side is
//      deliberately EMPTY: that is where a control panel goes (apps/panel-m24),
//      the same division of labour as a three.js example with a lil-gui folder.
//   2. Five panels: FPS / MS / MB (the addon's three built-ins) plus CALLS and
//      TRIS, which three.js keeps in `renderer.info.render` rather than in the
//      HUD. A click on the tile advances to the next panel, which is stats.js'
//      `showPanel(++mode % panels.length)`.
//   3. A press that starts on the HUD does NOT orbit the camera: the HUD stops
//      the press before it reaches the stage, the same way the DOM overlay in
//      three.js examples swallows the pointer above the canvas.
//
// The scene is deliberately the M13 hero shape (shadowed ring of boxes + a
// cutout-free torus) so that MS and CALLS have something real to measure: a
// HUD over an empty back buffer measures the HUD.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.controls.OrbitControls;
    import asaot.three.extras.hud.Stats;
    import asaot.three.extras.hud.StatsPanel;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.TorusGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class StatsM15 extends Stage3DApp
    {
        private var _controls:OrbitControls;

        private var _torus:Mesh;
        private var _ring:Group;

        private var _stats:Stats;
        private var _callsPanel:StatsPanel;
        private var _trisPanel:StatsPanel;
        private var _lastMode:int = -1;

        private var _frames:int = 0;
        // Frame period as the host measured it (elapsedMs of the frame that was
        // just drawn). The HUD's MS panel is the other view of the same number;
        // logging both is how "the HUD costs frames" is answered with numbers
        // instead of an opinion (M15 A/B below).
        private var _frameMs:Number = 0;

        // Graph normalizers for the two asaot3d panels. Both are round numbers a
        // scene of this size stays under, so the column heights are readable
        // instead of pinned at full height.
        private static const CALLS_MAX:Number = 40;
        private static const TRIS_MAX:Number = 8000;

        // The host shows a HUD on every demo since M35; this demo is the one whose
        // SUBJECT is the HUD (click to cycle, a press on the tile is consumed), so it
        // keeps building its own and tells the host not to add a second one.
        override protected function showStats():Boolean
        {
            return false;
        }

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(55, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 5.6, 12.5);
            _camera.lookAt(0, 1.6, 0);
            _camera.updateMatrixWorld(true);

            // ---- ground -----------------------------------------------------
            var groundMat:MeshStandardMaterial = new MeshStandardMaterial();
            groundMat.color.setHex(0x878b96);
            groundMat.roughness = 0.95;
            groundMat.metalness = 0.0;
            var ground:Mesh = new Mesh(new PlaneGeometry(26, 26), groundMat);
            ground.rotation.x = -1.5707963267948966; // -PI/2
            ground.receiveShadow = true;
            _scene.add(ground);

            // ---- ring of boxes: the bulk of the draw calls -------------------
            _ring = new Group();
            _scene.add(_ring);
            var i:int = 0;
            while (i < 6)
            {
                var angle:Number = i * (2 * Math.PI / 6);
                var mat:MeshStandardMaterial = new MeshStandardMaterial();
                mat.color.setHex(ringColor(i));
                mat.roughness = 0.42;
                mat.metalness = 0.12;
                var box:Mesh = new Mesh(new BoxGeometry(1.2, 1.2, 1.2), mat);
                box.position.set(Math.cos(angle) * 4.0, 0.6, Math.sin(angle) * 4.0);
                box.rotation.y = -angle;
                box.castShadow = true;
                box.receiveShadow = true;
                _ring.add(box);
                i++;
            }

            // ---- torus: triangle-heavy caster in the middle ------------------
            var torusMat:MeshStandardMaterial = new MeshStandardMaterial();
            torusMat.color.setHex(0xd98d4a);
            torusMat.roughness = 0.5;
            torusMat.metalness = 0.1;
            _torus = new Mesh(new TorusGeometry(1.3, 0.45, 20, 44), torusMat);
            _torus.position.set(0, 2.9, 0);
            _torus.castShadow = true;
            _torus.receiveShadow = true;
            _scene.add(_torus);

            // ---- lights ------------------------------------------------------
            var amb:AmbientLight = new AmbientLight(0x404a5a, 1.0);
            _scene.add(amb);

            var key:DirectionalLight = new DirectionalLight(0xfff0dd, 2.4);
            key.position.set(5.5, 8.5, 5.0);
            key.castShadow = true;
            key.shadow.mapSize.set(1024, 1024);
            key.shadow.radius = 2;
            key.shadow.normalBias = 0.02;
            key.shadow.bias = -0.002;
            _scene.add(key);

            var fill:DirectionalLight = new DirectionalLight(0x9fc3ff, 0.7);
            fill.position.set(-6.0, 4.0, -5.0);
            _scene.add(fill);

            // ---- camera control: proves the HUD does not eat the stage -------
            _controls = new OrbitControls(_camera, stage);
            _controls.target.set(0, 1.6, 0);
            _controls.enableDamping = true;
            _controls.dampingFactor = 0.12;
            _controls.minDistance = 5;
            _controls.maxDistance = 28;
            _controls.maxPolarAngle = 1.52;
            _controls.update();

            // ---- the HUD -----------------------------------------------------
            // FPS/MS/MB built in; CALLS/TRIS are ours (three.js keeps them in
            // renderer.info.render). addPanel() appends, so the click cycle is
            // FPS -> MS -> MB -> CALLS -> TRIS -> FPS.
            _stats = new Stats();
            _callsPanel = _stats.addPanel(new StatsPanel("CALLS", 0xffff00, 0x222200));
            _trisPanel = _stats.addPanel(new StatsPanel("TRIS", 0xffaa00, 0x201400));
            addChild(_stats);
            _lastMode = _stats.mode;

            logLine("M15 demo: Stats HUD in the top-left, " + _stats.panelCount +
                  " panels (click the tile to cycle); anchor x=" + Stats.MARGIN +
                  " y=" + Stats.MARGIN + " (right side reserved for a control panel)");
            logLine("M15 demo: left-drag still orbits (a press on the HUD is consumed by the HUD)");
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

        // The HUD re-anchors itself on Event.RESIZE; the back buffer and the
        // projection aspect are the host's job, so only the controls'
        // pixel-to-angle scale is left here.
        override protected function onViewportResize(w:int, h:int):void
        {
            _controls.setSize(w, h);
            logLine("M15 resize -> " + w + "x" + h + " HUD x=" + Stats.MARGIN);
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frames++;
            this._frameMs = elapsedMs;

            _torus.rotation.y += 0.012;
            _torus.rotation.x += 0.007;

            var i:int = 0;
            while (i < _ring.children.length)
            {
                var box:Mesh = _ring.children[i] as Mesh;
                box.position.y = 0.6 + 0.35 * Math.sin(_frames * 0.03 + i * 1.05);
                box.rotation.y += 0.01;
                i++;
            }

            _controls.update();
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            // HUD after present: the frame it measures is the one just shown.
            _stats.update();
            _callsPanel.update(_renderer.drawCalls, CALLS_MAX);
            _trisPanel.update(_renderer.triangles, TRIS_MAX);

            if (_stats.mode != _lastMode)
            {
                _lastMode = _stats.mode;
                logLine("M15 HUD -> " + _stats.currentPanel.name +
                      " (mode " + _stats.mode + "/" + _stats.panelCount + ")");
            }

            if (_frames == 1)
            {
                logLine("M15 demo frame 1: drawCalls=" + _renderer.drawCalls +
                      " triangles=" + _renderer.triangles);
            }
            // Once a second: often enough that the azimuth printed around a HUD
            // press shows the camera did not move, sparse enough to read.
            if (_frames % 30 == 0)
            {
                logLine("M15 frame " + _frames +
                      " rawMs=" + round3(this._frameMs) +
                      " ms=" + round3(_stats.panels[Stats.MS].value) +
                      " fps=" + round3(_stats.panels[Stats.FPS].value) +
                      " calls=" + _renderer.drawCalls +
                      " tris=" + _renderer.triangles +
                      " az=" + round3(_controls.getAzimuthalAngle()));
            }
        }

        private function round3(v:Number):Number
        {
            return Math.round(v * 1000) / 1000;
        }
    }
}