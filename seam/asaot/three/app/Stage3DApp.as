// asaot.three.app.Stage3DApp -- the shared application host for asaot3d demos.
//
// Why a base class: the Stage3D bootstrap (stage config -> requestContext3D ->
// CONTEXT3D_CREATE -> build scene -> ENTER_FRAME -> render + present) was
// copy-pasted into every demo, together with the two behaviors a real AIR app
// needs but a browser page gets from the DOM:
//
//   1. DISPLAY-RATE SYNC ("vsync at the panel's maximum refresh rate"). AIR has
//      no refresh-rate query of its own; the backend dispatches an enhanced
//      `VsyncStateChangeAvailabilityEvent` carrying `refreshRate` once the panel
//      rate is known, and again whenever the window lands on a display with a
//      different rate (e.g. dragged from a 60 Hz panel to a 120 Hz one). Writing
//      that value into `stage.frameRate` is the AIR-correct way to run the
//      application clock at the display rate: frameRate is application-wide,
//      and with vsyncEnabled true the pacer caps anything above the panel, so
//      raising it is what actually buys the extra frames.
//   2. WINDOW RESIZE. With scaleMode = NO_SCALE the stage size IS the back buffer
//      size, so a resize must reconfigure the back buffer AND rebuild the
//      projection matrix for the new aspect. Doing only the first stretches the
//      image; doing only the second renders into a stale buffer.
//
// Subclass contract:
//
//   override protected function createScene():void        -- build _scene and
//                                                            _camera (required)
//   override protected function updateFrame(ms:Number):void -- animation/controls
//   override protected function afterFrame(ms:Number):void  -- work AFTER present
//                                                            (e.g. HUD update)
//   override protected function onViewportResize(w:int, h:int):void
//                                                          -- extra resize work
//                                                            (controls.setSize,
//                                                             ortho frustum refit)
//
// render() and present() are the host's job -- every demo did exactly that pair
// in its own ENTER_FRAME handler, and forgetting present() is the classic
// white-screen bug this host removes by construction.
package asaot.three.app
{
    import flash.display.Sprite;
    import flash.display.StageAlign;
    import flash.display.StageScaleMode;
    import flash.display3D.Context3D;
    import flash.display3D.Context3DRenderMode;
    import flash.events.ErrorEvent;
    import flash.events.Event;
    import flash.events.VsyncStateChangeAvailabilityEvent;
    import flash.system.System;
    import flash.utils.getTimer;

    import asaot.three.AGALRenderer;
    import asaot.three.cameras.Camera;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.input.Keyboard;
    import asaot.three.scenes.Scene;

    public class Stage3DApp extends Sprite
    {
        protected var _context:Context3D;
        protected var _renderer:AGALRenderer;
        protected var _scene:Scene;
        protected var _camera:Camera;

        // 0 until the backend reports a panel rate (web/offscreen backends never
        // do). Kept for logs and for subclasses that want to show it.
        private var _refreshRate:Number = 0;
        private var _lastTick:int = 0;

        // M26: key state table, attached to the stage in init(). The host owns it
        // because the host owns the stage; a demo only reads `keys`.
        private var _keys:Keyboard = null;

        // Last render failure (reportFrameError), for demos and probes that want
        // to assert a clean frame without watching the window title.
        private var _frameError:Error = null;

        public function Stage3DApp()
        {
            if (stage != null) init();
            else addEventListener(Event.ADDED_TO_STAGE, init);
        }

        // ------------------------------------------------------------------
        // bootstrap
        // ------------------------------------------------------------------

        private function init(e:Event = null):void
        {
            removeEventListener(Event.ADDED_TO_STAGE, init);
            // NO_SCALE + TOP_LEFT is the only sane combination for a Stage3D app:
            // the back buffer is configured at the window's pixel size, so the
            // stage must not rescale the content on top of that.
            stage.align = StageAlign.TOP_LEFT;
            stage.scaleMode = StageScaleMode.NO_SCALE;

            stage.frameRate = 60;
            // Explicit, even though it is AIR's default: the display-rate sync
            // below only holds if the pacer is allowed to cap at the panel.
            stage.vsyncEnabled = true;

            // Fires once the panel rate is known (before the first frame) and on
            // every display-rate change; never fires on a backend that cannot
            // query the panel, so a demo without the event keeps AIR's 24 fps.
            stage.addEventListener(
                VsyncStateChangeAvailabilityEvent.VSYNC_STATE_CHANGE_AVAILABILITY,
                onVsyncRefreshRate);
            stage.addEventListener(Event.RESIZE, onStageResizeEvent);

            // M26: the stage is the one object that always exists and the one AIR
            // dispatches to when nothing has focus (measured: as-aot's keyboard
            // bridge targets the focused object, else the stage). Attaching here,
            // before the Stage3D context exists, means a demo can read keys from
            // its very first frame instead of after the context handshake.
            _keys = new Keyboard(stage);

            stage.stage3Ds[0].addEventListener(Event.CONTEXT3D_CREATE, onContext3DCreate);
            stage.stage3Ds[0].addEventListener(ErrorEvent.ERROR, onStage3DError);
            // Profile, not just render mode. This pairs with AGALRenderer.AGAL_VERSION.
            //
            // Measured on adl 51.4.1 (temp/airprobe: one program upload per version x
            // profile). AIR validates the AGAL version against the Context3D profile
            // and refuses the program -- #3725, nothing drawn -- otherwise:
            //   profile          v1  v2  v3  v4
            //   baseline         -   -   -   -
            //   baselineExtended -   -   -   -
            //   standard         -   OK  -   -
            //   standardExtended -   OK  OK  -
            //   enhanced         -   OK  OK  OK
            // "enhanced" is the only profile that accepts AGAL4, i.e. the highest
            // version the runtime supports, and everything from M4 on needs registers
            // above the AGAL1 file (vc40+, fc36+). A baseline context -- ADOBE's
            // default -- renders a black window and reports nothing.
            stage.stage3Ds[0].requestContext3D("auto", "enhanced");
        }

        private function onStage3DError(e:ErrorEvent):void
        {
            logLine("Stage3D error: " + e.text);
        }

        // ------------------------------------------------------------------
        // 1. display-rate sync
        // ------------------------------------------------------------------

        private function onVsyncRefreshRate(e:VsyncStateChangeAvailabilityEvent):void
        {
            // `refreshRate` is an as-aot enhancement, not an AIR field: AIR's
            // VsyncStateChangeAvailabilityEvent only declares `available`. Read it
            // as a dynamic key inside a try so the same source still compiles and
            // runs on AIR (where the read simply yields undefined) and so a strict
            // compiler never has to be told to ignore a typed member access.
            var refresh:Number = 0;
            try
            {
                if (e["refreshRate"])
                    refresh = e["refreshRate"];
            }
            catch (err:Error)
            {
            }

            var hz:Number = Stage3DApp.frameRateForRefresh(refresh);
            // 0 means "the backend cannot query the panel" -- keep the current
            // application rate rather than writing a fabricated value.
            if (hz <= 0) return;

            _refreshRate = hz;
            stage.frameRate = hz;
            logLine("Stage3DApp: display " + round3(hz) + " Hz -> stage.frameRate=" +
                    round3(stage.frameRate) + " (vsync " + stage.vsyncEnabled + ")");
        }

        // ------------------------------------------------------------------
        // 2. window resize
        // ------------------------------------------------------------------

        private function onStageResizeEvent(e:Event):void
        {
            // A resize can arrive before the Stage3D context exists (the window
            // is already on screen while requestContext3D is still in flight);
            // there is no back buffer to reconfigure yet, so ignore it.
            if (_renderer == null) return;
            applyViewportSize(stage.stageWidth, stage.stageHeight);
        }

        // Reconfigure the back buffer and refit the projection to the new aspect.
        protected function applyViewportSize(w:int, h:int):void
        {
            var aspect:Number = Stage3DApp.aspectFor(w, h);
            if (aspect <= 0) return;

            _renderer.setSize(w, h);
            if (_camera != null && _camera.isPerspectiveCamera)
            {
                // three.js leaves this to the app (camera.aspect = w/h +
                // updateProjectionMatrix); a Stage3D host can do it because the
                // back buffer and the camera live in the same object.
                var cam:PerspectiveCamera = _camera as PerspectiveCamera;
                cam.aspect = aspect;
                cam.updateProjectionMatrix();
            }
            // Orthographic cameras are deliberately NOT refit here: their
            // left/right/top/bottom encode the app's own framing, so the subclass
            // decides how the frustum follows the aspect.
            onViewportResize(w, h);
            logLine("Stage3DApp: resize " + w + "x" + h + " aspect=" + round3(aspect));
        }

        protected function onViewportResize(w:int, h:int):void
        {
            // optional hook
        }

        // ------------------------------------------------------------------
        // context + frame loop
        // ------------------------------------------------------------------

        private function onContext3DCreate(e:Event):void
        {
            // Setup is guarded like a frame: a throw here (a program that AIR
            // rejects, a missing asset, a demo's own maths) used to leave a window
            // that never reaches the frame loop and prints NOTHING anywhere -- the
            // worst possible failure shape, because "no log" and "no error" look
            // identical. Measured with texture-maps: AIR died in createScene and
            // the run produced an empty stdout while the window was still up.
            try
            {
                _context = stage.stage3Ds[0].context3D;
                _renderer = new AGALRenderer(_context);
                _renderer.setSize(stage.stageWidth, stage.stageHeight);

                createScene();
                if (_scene == null || _camera == null)
                {
                    throw new Error("Stage3DApp.createScene() must set _scene and _camera");
                }
            }
            catch (err:Error)
            {
                this.reportFrameError(err);
                return;
            }

            _lastTick = 0;
            logLine("Stage3DApp ready: " + stage.stageWidth + "x" + stage.stageHeight +
                    " frameRate=" + round3(stage.frameRate) +
                    " refresh=" + round3(_refreshRate));
            stage.addEventListener(Event.ENTER_FRAME, onEnterFrame);
        }

        // One line of runtime diagnosis, on the channel both backends share.
        //
        // Why System.output and not trace: measured here (AIR 51.4.1, adl on macOS
        // arm64) System.output() reaches stdout while trace() reaches NOTHING --
        // neither stdout, stderr, nor the console. A headless AIR run can therefore
        // only be judged from stdout. as-aot's as_system_output is fputs+fflush on
        // the same stream, so one call covers both backends with one log format
        // (no newline is added by System.output itself, hence the explicit one).
        // trace() is deliberately NOT called alongside it: under as-aot trace()
        // writes to that same stdout, which printed every line twice.
        protected function logLine(s:String):void
        {
            System.output(s + "\n");
        }

        // A frame that throws must not leave a black window with no diagnosis.
        private function reportFrameError(err:Error):void
        {
            _frameError = err;
            // Message first, stack second: the message is the part every runtime
            // can produce, and it must not be lost behind a diagnostic that may not
            // exist (as-aot's Error.getStackTrace() is a shell stub that returns ""
            // and prints its own "not implemented" line).
            logLine("Stage3DApp frame error: " + err.message);
            var stack:String = "";
            try { stack = err.getStackTrace(); } catch (e:Error) { }
            if (stack != "") logLine(stack);
            // The title stays as a second channel: it survives stdout being piped
            // away or swallowed by a launcher, and the AIR smoke runs read it.
            try { stage.nativeWindow.title = "render error: " + err.message; } catch (e2:Error) { }
        }

        private function onEnterFrame(e:Event):void
        {
            var now:int = getTimer();
            // Frame 1 reports 0: there is no previous frame to difference against,
            // and a bogus first delta is what makes delta-driven demos jump.
            var elapsedMs:Number = (_lastTick == 0) ? 0 : Number(now - _lastTick);
            _lastTick = now;

            try
            {
                updateFrame(elapsedMs);
                _renderer.render(_scene, _camera);
            }
            catch (err2:Error)
            {
                // A throw here used to leave a black window with no diagnosis
                // (adl forwards nothing from trace() on macOS), so the message goes
                // to stdout through the app's error reporter.
                this.reportFrameError(err2);
            }
            // Stage3D only encodes into the render target; present() blits it to
            // the window. Every asaot3d demo needs this (M5 white-screen root
            // cause) -- and it is the host's job here so no demo can forget it.
            _context.present();
            afterFrame(elapsedMs);
            // One-frame key edges are cleared last, so updateFrame() AND
            // afterFrame() both see this frame's key presses exactly once.
            if (_keys != null) _keys.endFrame();
        }

        // ------------------------------------------------------------------
        // subclass hooks
        // ------------------------------------------------------------------

        protected function createScene():void
        {
            // AS3 has no abstract methods; Camera.updateProjectionMatrix uses the
            // same "throw in the base" convention.
            throw new Error("Stage3DApp.createScene() is abstract -- override it");
        }

        protected function updateFrame(elapsedMs:Number):void
        {
            // optional hook
        }

        protected function afterFrame(elapsedMs:Number):void
        {
            // optional hook
        }

        // ------------------------------------------------------------------
        // read-only state
        // ------------------------------------------------------------------

        public function get renderer():AGALRenderer
        {
            return _renderer;
        }

        // Panel rate in Hz as last reported by the backend, or 0 when unknown.
        public function get refreshRate():Number
        {
            return _refreshRate;
        }

        // M26: keyboard state for subclass demos (isDown / justPressed).
        public function get keys():Keyboard
        {
            return _keys;
        }

        // ------------------------------------------------------------------
        // pure helpers (stage-free, so headless probes can pin them)
        // ------------------------------------------------------------------

        // The application frame rate to use for a reported panel rate. Energy
        // saving/fake panels report 0 or NaN, and those must NOT be written
        // through: 0 is not "leave it alone" (AIR clamps an assigned 0 to its
        // 0.01 fps floor, and this runtime treats a 0 frame rate as "follow the
        // display"), so the caller keeps the current application rate instead of
        // installing a fabricated one.
        public static function frameRateForRefresh(refreshRate:Number):Number
        {
            if (!(refreshRate > 0)) return 0;
            return refreshRate;
        }

        // w/h for the projection aspect, with zero-size windows rejected instead
        // of producing NaN/Infinity in the projection matrix.
        public static function aspectFor(width:int, height:int):Number
        {
            if (width <= 0 || height <= 0) return 0;
            return Number(width) / Number(height);
        }

        private static function round3(v:Number):Number
        {
            return Math.round(v * 1000) / 1000;
        }
    }
}