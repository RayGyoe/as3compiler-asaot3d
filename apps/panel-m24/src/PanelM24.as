// PanelM24.as -- M24 acceptance demo: a real control panel (asaotui) driving the
// scene, with the Stats HUD in the opposite corner.
//
// The window is split the way a three.js example splits it:
//
//   * TOP-LEFT  -- Stats (FPS / MS / MB / CALLS / TRIS). It is the HUD's default
//                  corner since M24; before that it sat top-right and a control
//                  panel had nowhere to live.
//   * TOP-RIGHT -- an asaotui panel: fog near/far/on-off, sun intensity/angle,
//                  shadow on/off, tone mapping, exposure, wireframe, reset.
//   * the middle is the 3D view and stays uncovered.
//
// WHY THIS IS A DEMO AND NOT A LIBRARY FEATURE: the panel is not part of asaot3d.
// `asaotui` is a separate repository checkout that is LINKED, not vendored --
// apps/panel-m24/class-paths lists `../asaotui/kit` and `../asaotui/seam`, and
// tools/build-demo.sh turns that into `--as-class-path` (as-aot) or
// `-source-path+=` (mxmlc). A copy would be a fork: it would drift, and every
// widget fix would have to be made twice. The demo is the proof that the seam
// works on BOTH backends with the library consumed in place.
//
// THE DATA FLOW IS THE POINT (and the M20 fog bug's lesson): a widget reports to
// PanelState, the panel re-describes, and the FRAME LOOP is the only code that
// writes Scene / Light / Material / AGALRenderer. Nothing applies a value in two
// places, so the panel and the shader cannot disagree.
//
// Scene content is deliberately the M20 acceptance shape (fog bar + shadowed
// cubes on a ground plane): the same pixels the AIR-vs-AOT comparisons already
// use, so a control panel that breaks something shows up against a known image.
package
{
    import asaot.three.AGALRenderer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.controls.OrbitControls;
    import asaot.three.extras.hud.Stats;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Fog;
    import asaot.three.scenes.Scene;

    import asaot.ui.Dirty;
    import asaot.ui.Theme;
    import asaot.ui.ThemeTokens;
    import asaot.ui.UiApp;

    import panel.PanelState;
    import panel.PanelView;

    public class PanelM24 extends Stage3DApp
    {
        private var _state:PanelState;
        private var _view:PanelView;
        private var _ui:UiApp;

        private var _fog:Fog;
        private var _sun:DirectionalLight;
        private var _controls:OrbitControls;

        // Every material the wireframe switch flips. Kept as a plain array of the
        // exact type the renderer reads, not of Object: a `*` here would box on
        // every write and hide a wrong cast until the draw.
        private var _materials:Vector.<MeshStandardMaterial>;

        private var _frames:int = 0;
        private var _lastTone:int = -1;

        private static const CALLS_MAX:Number = 40;
        private static const TRIS_MAX:Number = 8000;

        override protected function createScene():void
        {
            this._state = new PanelState();
            this._materials = new Vector.<MeshStandardMaterial>();

            // The Stats HUD (FPS/MS/MB/CALLS/TRIS) is the HOST's since M35: this demo
            // used to build the same 5-panel HUD by hand. Only its bar normalisers are
            // scene-specific, and they are read after createScene().
            hudCallsMax = CALLS_MAX;
            hudTrisMax = TRIS_MAX;

            this.buildScene();
            this.buildPanel();

            logLine("M24 ready: control panel on the right (" + PanelView.PANEL_W +
                "px, asaotui linked in place), Stats HUD top-left; state " +
                this._state.describe());
        }

        // ------------------------------------------------------------------
        // scene
        // ------------------------------------------------------------------
        private function buildScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(55, stage.stageWidth / stage.stageHeight, 0.1, 200);
            _camera.position.set(0, 3.2, 9.5);
            _camera.lookAt(0, 0.4, 0);
            _camera.updateMatrixWorld(true);

            // Dark clear colour, the same family as the panel slab: a black sky
            // next to a lit ground reads as "the renderer gave up", and the fog
            // colour would be indistinguishable from a background of its own hue.
            var bg:Color = new Color(0x0e1016);
            _scene.background = bg;

            var fog:Fog = new Fog(this._state.fogColor, this._state.fogNear, this._state.fogFar);
            this._fog = fog;
            _scene.fog = fog;

            // ---- ground -----------------------------------------------------
            var groundMat:MeshStandardMaterial = new MeshStandardMaterial();
            groundMat.color.setHex(0x8a8f9c);
            groundMat.roughness = 0.95;
            groundMat.metalness = 0.0;
            var ground:Mesh = new Mesh(new PlaneGeometry(30, 30), groundMat);
            ground.rotation.x = -1.5707963267948966;   // -PI/2
            ground.position.y = -2.0;
            ground.receiveShadow = true;
            _scene.add(ground);
            this._materials.push(groundMat);

            // ---- three cubes: the wireframe / shadow test subjects -----------
            var i:int = 0;
            while (i < 3)
            {
                var mat:MeshStandardMaterial = new MeshStandardMaterial();
                mat.color.setHex(i == 0 ? 0xd9584a : (i == 1 ? 0x4a8fd9 : 0x59b06a));
                mat.roughness = 0.42;
                mat.metalness = 0.08;
                var box:Mesh = new Mesh(new BoxGeometry(1.4, 1.4, 1.4), mat);
                box.position.set((i - 1) * 2.6, -0.6, 0);
                box.rotation.y = 0.35 * i;
                box.castShadow = true;
                box.receiveShadow = true;
                _scene.add(box);
                this._materials.push(mat);
                i++;
            }

            // ---- the fog bar: the M20 acceptance object ---------------------
            var barMat:MeshStandardMaterial = new MeshStandardMaterial();
            barMat.color.setHex(0x60c8ff);
            barMat.roughness = 0.9;
            barMat.metalness = 0.0;
            var bar:Mesh = new Mesh(new BoxGeometry(0.5, 0.5, 26), barMat);
            bar.position.set(5.0, 0.2, -12.0);
            _scene.add(bar);
            this._materials.push(barMat);

            // ---- lights -----------------------------------------------------
            _scene.add(new AmbientLight(0xffffff, 0.35));

            var sun:DirectionalLight = new DirectionalLight(0xfff2e0, this._state.sunIntensity);
            sun.castShadow = true;
            sun.shadow.mapSize.set(1024, 1024);
            sun.shadow.radius = 2;
            sun.shadow.normalBias = 0.02;
            sun.shadow.bias = -0.002;
            sun.shadow.camera.left = -10;
            sun.shadow.camera.right = 10;
            sun.shadow.camera.top = 10;
            sun.shadow.camera.bottom = -10;
            _scene.add(sun);
            this._sun = sun;
            this.applySun();

            // ---- camera control: proves the panel does not eat the stage ----
            this._controls = new OrbitControls(_camera, stage);
            this._controls.target.set(0, 0.0, 0);
            this._controls.enableDamping = true;
            this._controls.dampingFactor = 0.12;
            this._controls.minDistance = 5;
            this._controls.maxDistance = 26;
            this._controls.update();

            _renderer.toneMapping = this._state.toneMapping;
            _renderer.toneMappingExposure = this._state.exposure;
            this._lastTone = this._state.toneMapping;
        }

        // ------------------------------------------------------------------
        // control panel (right)
        // ------------------------------------------------------------------
        private function buildPanel():void
        {
            // The panel sits on a dark slab over a dark 3D view, so it asks for the
            // toolkit's DARK palette instead of inheriting the light default. This
            // is the library's own runtime theme switch (Theme.setTheme swaps the
            // palette and bumps an epoch; UiApp re-describes on the next frame), not
            // a per-node colour hack -- one call, and every widget in the panel
            // (checkbox labels, the select, the button) follows.
            Theme.setTheme(ThemeTokens.dark());

            var self:PanelM24 = this;
            this._view = new PanelView(this._state, function (d:int):void {
                self._ui.invalidate(d);
                self.onPanelEdited();
            });

            this._ui = new UiApp(this._view);
            this._ui.mount(stage);
            this._ui.attachRoot();
            // Describe once up front: the window's first frame is painted after
            // this returns, and a UI that waits for a user event would show an
            // empty right-hand strip in every screenshot.
            this._ui.invalidate(Dirty.ALL);
            this._ui.reflow();
        }

        private function onPanelEdited():void
        {
            // Applied by the frame loop (see applyState), never here -- one writer.
            logLine("M24 panel: " + this._state.describe());
        }

        // ------------------------------------------------------------------
        // frame loop
        // ------------------------------------------------------------------
        override protected function updateFrame(elapsedMs:Number):void
        {
            this.applyState();
            this._controls.update();
        }

        // The ONLY writer of Scene / Light / Material / AGALRenderer state.
        // Called every frame on purpose: it is a handful of assignments, and a
        // "changed?" flag would be a second source of truth about what was last
        // applied -- exactly the shape of the M20 fog bug.
        private function applyState():void
        {
            var s:PanelState = this._state;

            this._fog.near = s.fogNear;
            this._fog.far = s.fogFar;
            _scene.fog = s.fogOn ? this._fog : null;

            this.applySun();

            if (_renderer.toneMapping != s.toneMapping)
            {
                _renderer.toneMapping = s.toneMapping;
                logLine("M24 toneMapping -> " + PanelState.TONE_LABELS[s.toneMapping]);
            }
            _renderer.toneMappingExposure = s.exposure;

            var i:int = 0;
            while (i < this._materials.length)
            {
                this._materials[i].wireframe = s.wireframe;
                i++;
            }
        }

        private function applySun():void
        {
            var s:PanelState = this._state;
            var rad:Number = s.sunAngle * 0.017453292519943295;   // PI / 180
            this._sun.intensity = s.sunIntensity;
            this._sun.castShadow = s.shadows;
            this._sun.position.set(Math.cos(rad) * 6.0, s.sunHeight, Math.sin(rad) * 6.0);
            this._sun.target.position.set(0, -1, 0);
            this._sun.target.updateMatrixWorld();
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            this._frames++;

            if (this._frames == 1)
            {
                logLine("M24 frame 1: drawCalls=" + _renderer.drawCalls +
                    " triangles=" + _renderer.triangles +
                    " stats x=" + stats.panels[0].x +
                    " panelW=" + PanelView.PANEL_W);
            }
            // Once a second: enough to see the scene is alive and that the panel's
            // numbers reached the GPU, sparse enough to read in a log.
            if (this._frames % 60 == 0)
            {
                logLine("M24 frame " + this._frames +
                    " fps=" + round3(stats.panels[Stats.FPS].value) +
                    " ms=" + round3(stats.panels[Stats.MS].value) +
                    " calls=" + _renderer.drawCalls +
                    " tris=" + _renderer.triangles +
                    " fogNear=" + round3(this._state.fogNear) +
                    " tone=" + this._state.toneMapping);
            }
        }

        override protected function onViewportResize(w:int, h:int):void
        {
            this._controls.setSize(w, h);
            logLine("M24 resize -> " + w + "x" + h +
                " (panel keeps " + PanelView.PANEL_W + "px on the right)");
        }

        private function round3(v:Number):Number
        {
            return Math.round(v * 1000) / 1000;
        }
    }
}