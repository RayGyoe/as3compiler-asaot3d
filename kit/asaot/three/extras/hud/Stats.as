// asaot.three.extras.hud.Stats -- the performance HUD (FPS / MS / MB + extras).
//
// Borrowed from three.js r187 `examples/jsm/libs/stats.module.js` -- the addon's
// own header says `REVISION: 16`, i.e. it is stats.js r16. As with OrbitControls
// (D99) that file is an addon and our `three-src/` checkout is sparse (`src/`
// only), so there are no line numbers to cite here; every borrowed constant and
// window is instead pinned by `probes/stats-smoke-m15/`.
//
// The addon's shape, kept verbatim:
//
//   * one panel is visible at a time and a click on the HUD advances to the
//     next one (`showPanel(++mode % panels.length)`) -- the HUD is 80x48, not a
//     row of three;
//   * `begin()` stamps the frame start, `end()` feeds `MS` with the elapsed
//     time (normalizer 200) on EVERY frame and feeds `FPS` with
//     `frames*1000/(now-prev)` (normalizer 100) once per 1000 ms window;
//     `update()` is `begin()` folded into `end()` (`beginTime = this.end()`);
//   * `MB` uses the heap panel: stats.js reads `performance.memory`
//     (`usedJSHeapSize`/`jsHeapSizeLimit`); AIR's equivalent is
//     `System.totalMemory` (bytes), and there is no heap limit, so the
//     normalizer is a nominal `memoryScaleMB` (see D101).
//
// Divergences (three-api-design.md §20):
//
//   * D102 -- the DOM container's `position:fixed;top:0;left:0` becomes a
//     display-list overlay with an explicit corner (`align`), and it re-anchors
//     on stage RESIZE. The DEFAULT is TOP-LEFT, exactly like stats.js' DOM div:
//     the right-hand side is reserved for a control panel (asaotui), which is
//     where every three.js example puts its lil-gui folder. `align = RIGHT` is
//     still available for a scene that needs the opposite corner.
//   * the HUD is not an opaque Sprite with painted art: hit testing climbs to
//     the nearest InteractiveObject whose content region contains the point, so
//     the panel tiles themselves are what the pointer lands on. Clicks are
//     consumed (`stopPropagation`) and so are presses: with Stage3D + AIR the
//     stage is also OrbitControls' event source, and a drag that starts on the
//     HUD must not also spin the camera (in three.js the DOM div sits above the
//     canvas and swallows the pointer for the same reason).
//   * `Stats.Panel` is a class (StatsPanel) instead of a constructor property,
//     because AS3 has no function-object-with-fields and no `new Stats.Panel()`.
package asaot.three.extras.hud
{
    import flash.display.Sprite;
    import flash.events.Event;
    import flash.events.MouseEvent;
    import flash.system.System;
    import flash.utils.getTimer;

    public class Stats extends Sprite
    {
        // stats.module.js `REVISION: 16`.
        public static const REVISION:int = 16;

        // Panel identifiers. FPS/MS/MB are the addon's three built-ins; CALLS
        // and TRIS are asaot3d additions (three.js keeps those in
        // `renderer.info.render`, not in the HUD).
        public static const FPS:int = 0;
        public static const MS:int = 1;
        public static const MB:int = 2;

        // Default gap from the window edge, in stage units.
        public static const MARGIN:int = 8;

        // stats.js normalizers (second argument of Panel.update).
        public static const MS_MAX:Number = 200;
        public static const FPS_MAX:Number = 100;

        // Nominal heap scale for the MB panel, in MiB. AIR has no
        // `jsHeapSizeLimit`; 1 GiB gives the same "how full is the heap" shape
        // the DOM panel shows without pretending to know a real limit.
        public static const MEMORY_SCALE_MB:Number = 1024;

        // Which corner the tile hugs. TOP-LEFT is the default because that is
        // where stats.js puts its DOM div, and because the right-hand side of a
        // demo window is where a control panel goes (three.js examples put
        // lil-gui there too, and the two must not overlap).
        public static const LEFT:String = "left";
        public static const RIGHT:String = "right";

        public var align:String = LEFT;
        public var marginX:int = MARGIN;
        public var marginY:int = MARGIN;

        private var _panels:Vector.<StatsPanel>;
        private var _mode:int = 0;

        private var _fpsPanel:StatsPanel;
        private var _msPanel:StatsPanel;
        private var _mbPanel:StatsPanel;

        private var _frames:int = 0;
        private var _beginTime:Number = 0;
        private var _prevTime:Number = 0;

        // withMemory: add the MB panel (stats.js only adds it when
        // `performance.memory` exists, i.e. Chromium). alignAt: the corner, see
        // LEFT / RIGHT above; anything else is a programming error, not a
        // silent fallback to the default.
        //
        // The default is the string literal `"left"`, not `LEFT`: as-aot does not
        // resolve a class constant inside a parameter default (mxmlc does), and a
        // literal keeps one source valid on both backends.
        public function Stats(withMemory:Boolean = true, alignAt:String = "left")
        {
            if (alignAt != LEFT && alignAt != RIGHT)
            {
                throw new Error("Stats: align must be Stats.LEFT or Stats.RIGHT, got '" +
                    alignAt + "'");
            }
            this.align = alignAt;
            this.mouseChildren = false;
            this.tabEnabled = false;

            this._panels = new Vector.<StatsPanel>();

            this._fpsPanel = this.addPanel(new StatsPanel("FPS", 0x00ffff, 0x000022));
            this._msPanel = this.addPanel(new StatsPanel("MS", 0x00ff00, 0x002200));
            if (withMemory)
            {
                this._mbPanel = this.addPanel(new StatsPanel("MB", 0xff0088, 0x220011));
            }

            this.showPanel(FPS);

            this._beginTime = this._now();
            this._prevTime = this._beginTime;

            this.addEventListener(Event.ADDED_TO_STAGE, this._onAdded);
            this.addEventListener(Event.REMOVED_FROM_STAGE, this._onRemoved);
            this.addEventListener(MouseEvent.MOUSE_DOWN, this._onPressDown);
            this.addEventListener(MouseEvent.CLICK, this._onClick);
        }

        // ------------------------------------------------------------------
        // clock -- overridable so a probe can drive the 1 s FPS window exactly
        // ------------------------------------------------------------------

        // Clock seam. Stays null in normal use (getTimer); a headless probe -- or
        // an app driving the HUD from its own frame timer -- installs a Function
        // returning milliseconds. setTimeSource() re-seeds the 1 s FPS window at
        // the new clock, so a probe does not inherit the wall clock picked up by
        // the constructor.
        public var timeSource:Function = null;

        public function setTimeSource(source:Function):void
        {
            this.timeSource = source;
            this._beginTime = this._now();
            this._prevTime = this._beginTime;
            this._frames = 0;
        }

        protected function _now():Number
        {
            if (this.timeSource != null) return this.timeSource();
            return getTimer();
        }

        // ------------------------------------------------------------------
        // panels
        // ------------------------------------------------------------------

        public function addPanel(panel:StatsPanel):StatsPanel
        {
            panel.visible = false;
            panel.x = this.marginX;
            panel.y = this.marginY;
            this.addChild(panel);
            this._panels.push(panel);
            this.layout();
            return panel;
        }

        // Where the tile's left edge lands for a given stage width, for the
        // RIGHT alignment. The LEFT alignment is just `margin`, so only this side
        // needs arithmetic -- and both are split out as pure functions so the
        // anchoring is pinnable without a stage.
        public static function anchorX(stageWidth:Number, margin:int):Number
        {
            return stageWidth - StatsPanel.WIDTH - margin;
        }

        // The single decision point for "which x does the corner imply", so
        // layout() cannot drift from what the probes pin.
        public static function anchorFor(alignAt:String, stageWidth:Number, margin:int):Number
        {
            return (alignAt == RIGHT) ? anchorX(stageWidth, margin) : margin;
        }

        public function get panels():Vector.<StatsPanel>
        {
            return this._panels;
        }

        public function get panelCount():int
        {
            return this._panels.length;
        }

        public function get mode():int
        {
            return this._mode;
        }

        public function get currentPanel():StatsPanel
        {
            if (this._mode < 0 || this._mode >= this._panels.length) return null;
            return this._panels[this._mode];
        }

        public function showPanel(id:int):void
        {
            var n:int = this._panels.length;
            if (n == 0) return;
            var i:int = id % n;
            if (i < 0) i += n;
            var k:int = 0;
            while (k < n)
            {
                this._panels[k].visible = (k == i);
                k++;
            }
            this._mode = i;
        }

        // stats.js' click handler: `showPanel(++mode % children.length)`.
        public function cycle():void
        {
            if (this._panels.length == 0) return;
            this.showPanel(this._mode + 1);
        }

        // Re-anchor. Called from the stage RESIZE handler, from ADDED_TO_STAGE,
        // and after addPanel(); safe to call at any time (a detached HUD keeps
        // the left margin, which is also the default corner).
        public function layout():void
        {
            var x0:Number = this.marginX;
            if (this.align == RIGHT && this.stage != null)
            {
                x0 = anchorFor(this.align, this.stage.stageWidth, this.marginX);
            }
            var i:int = 0;
            var n:int = this._panels.length;
            while (i < n)
            {
                this._panels[i].x = x0;
                this._panels[i].y = this.marginY;
                i++;
            }
        }

        // ------------------------------------------------------------------
        // timing -- stats.js begin/end/update
        // ------------------------------------------------------------------

        public function begin():void
        {
            this._beginTime = this._now();
        }

        public function end():Number
        {
            this._frames++;
            var time:Number = this._now();

            // Every frame: stats.js feeds MS with the whole frame period.
            this._msPanel.update(time - this._beginTime, MS_MAX);

            if (time >= this._prevTime + 1000)
            {
                this._fpsPanel.update((this._frames * 1000) / (time - this._prevTime), FPS_MAX);
                this._prevTime = time;
                this._frames = 0;

                if (this._mbPanel != null)
                {
                    this._mbPanel.update(System.totalMemory / 1048576, MEMORY_SCALE_MB);
                }
            }

            return time;
        }

        public function update():void
        {
            this._beginTime = this.end();
        }

        // ------------------------------------------------------------------
        // events
        // ------------------------------------------------------------------

        private function _onAdded(e:Event):void
        {
            if (this.stage != null)
            {
                this.stage.addEventListener(Event.RESIZE, this._onResize);
            }
            this.layout();
        }

        private function _onRemoved(e:Event):void
        {
            if (this.stage != null)
            {
                this.stage.removeEventListener(Event.RESIZE, this._onResize);
            }
        }

        private function _onResize(e:Event):void
        {
            this.layout();
        }

        private function _onPressDown(e:MouseEvent):void
        {
            // A press on the HUD belongs to the HUD: the stage below is also
            // OrbitControls' event source, and a drag starting here must not
            // orbit the camera (the DOM panel above a canvas behaves the same).
            e.stopPropagation();
        }

        private function _onClick(e:MouseEvent):void
        {
            e.stopPropagation();
            this.cycle();
        }
    }
}