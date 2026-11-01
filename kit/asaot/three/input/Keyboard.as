// asaot.three.input.Keyboard -- key state table bridged from Stage keyboard events.
//
// WHY THIS EXISTS: three.js reads the keyboard through DOM listeners
// (`document.addEventListener('keydown', ...)` in webgl_animation_walk), which a
// Stage3D app does not have. The port needs the same three answers -- "is it
// held", "did it go down this frame", "is anything held" -- from flash.events
// .KeyboardEvent instead.
//
// The event SOURCE is an EventDispatcher, not a Stage: Stage3DApp attaches it to
// the stage, and probes attach it to a plain EventDispatcher and dispatch
// synthesised KeyboardEvents. Same class, same code path, no GPU and no window.
//
// DIVERGENCES (three-api-design.md §29):
//   D143 three.js keys are DOM `event.code` strings; ours are flash.ui.Keyboard
//        integer keyCodes, which is what AIR actually delivers.
//   D144 A key held while the window loses focus never produces a keyUp, so the
//        table would latch it down forever (press W, Cmd-Tab away, come back and
//        the character keeps walking). AIR dispatches Event.DEACTIVATE in exactly
//        that case, and that event resets the table. DOM listeners have the same
//        defect; three.js simply never hits it in a browser tab that keeps focus.
package asaot.three.input
{
    import flash.events.Event;
    import flash.events.EventDispatcher;
    import flash.events.KeyboardEvent;

    public class Keyboard
    {
        // AIR keyCodes for every key this table cares about sit in 0..255. Codes
        // outside the table are counted, not dropped silently: `droppedKeys` is
        // there so "my key does nothing" is diagnosable instead of invisible.
        public static const MAX_CODE:int = 256;

        private var _target:EventDispatcher = null;

        // Indexed by keyCode. Two arrays, not one bitfield: a 256-entry Boolean
        // Vector is a single allocation at construction, and this table is read
        // every frame -- a Dictionary lookup per query would be the hot path.
        private var _down:Vector.<Boolean>;
        private var _pressed:Vector.<Boolean>;

        private var _downCount:int = 0;
        private var _droppedKeys:int = 0;

        public function Keyboard(target:EventDispatcher = null)
        {
            var i:int;
            this._down = new Vector.<Boolean>(MAX_CODE, true);
            this._pressed = new Vector.<Boolean>(MAX_CODE, true);
            for (i = 0; i < MAX_CODE; i++)
            {
                this._down[i] = false;
                this._pressed[i] = false;
            }
            if (target != null) this.attach(target);
        }

        // ------------------------------------------------------------------
        // wiring
        // ------------------------------------------------------------------

        // `target` is usually the stage (it is the one object that always exists
        // and the one AIR dispatches to when nothing has focus).
        public function attach(target:EventDispatcher):void
        {
            if (this._target == target) return;
            this.detach();
            this._target = target;
            target.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
            target.addEventListener(KeyboardEvent.KEY_UP, onKeyUp);
            // D144: focus loss is the only signal that a held key will never get
            // its keyUp.
            target.addEventListener(Event.DEACTIVATE, onDeactivate);
        }

        public function detach():void
        {
            var target:EventDispatcher = this._target;
            if (target == null) return;
            this._target = null;
            target.removeEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
            target.removeEventListener(KeyboardEvent.KEY_UP, onKeyUp);
            target.removeEventListener(Event.DEACTIVATE, onDeactivate);
            this.reset();
        }

        // ------------------------------------------------------------------
        // queries
        // ------------------------------------------------------------------

        public function isDown(keyCode:int):Boolean
        {
            if (keyCode < 0 || keyCode >= MAX_CODE) return false;
            return this._down[keyCode];
        }

        // True for the frame the key went down in, even if it also went up inside
        // that same frame -- a tap must still count once (three.js gets this for
        // free because DOM keydown is a discrete event).
        public function justPressed(keyCode:int):Boolean
        {
            if (keyCode < 0 || keyCode >= MAX_CODE) return false;
            return this._pressed[keyCode];
        }

        public function anyDown():Boolean
        {
            return this._downCount > 0;
        }

        // Number of held keys whose keyCode fell outside MAX_CODE (0 in practice;
        // non-zero means a key the table cannot represent, not a bug).
        public function get droppedKeys():int
        {
            return this._droppedKeys;
        }

        // ------------------------------------------------------------------
        // frame + focus lifecycle
        // ------------------------------------------------------------------

        // Clears the one-frame "went down" edges. The host calls this at the END
        // of every frame, so both updateFrame() and afterFrame() can read them.
        public function endFrame():void
        {
            var pressed:Vector.<Boolean> = this._pressed;
            var i:int;
            for (i = 0; i < MAX_CODE; i++) pressed[i] = false;
        }

        // Forgets every held key. Called on focus loss and exposed for demos that
        // switch scenes (a stopped scene must not inherit held keys).
        public function reset():void
        {
            var down:Vector.<Boolean> = this._down;
            var pressed:Vector.<Boolean> = this._pressed;
            var i:int;
            for (i = 0; i < MAX_CODE; i++)
            {
                down[i] = false;
                pressed[i] = false;
            }
            this._downCount = 0;
        }

        // ------------------------------------------------------------------
        // events
        // ------------------------------------------------------------------

        private function onKeyDown(e:KeyboardEvent):void
        {
            var code:int = e.keyCode;
            if (code < 0 || code >= MAX_CODE)
            {
                this._droppedKeys++;
                return;
            }
            if (!this._down[code])
            {
                this._down[code] = true;
                this._downCount++;
            }
            // Auto-repeat arrives as repeated keyDowns; the edge stays a single
            // frame because endFrame clears it, and the count above never
            // double-counts.
            this._pressed[code] = true;
        }

        private function onKeyUp(e:KeyboardEvent):void
        {
            var code:int = e.keyCode;
            if (code < 0 || code >= MAX_CODE) return;
            if (!this._down[code]) return;
            this._down[code] = false;
            this._downCount--;
        }

        private function onDeactivate(e:Event):void
        {
            this.reset();
        }
    }
}