// asaot.three.extras.hud.StatsPanel -- one 80x48 tile of the Stats HUD.
//
// Borrowed from three.js r187 `examples/jsm/libs/stats.module.js` (the `Stats`
// addon bundled with the examples; its own header says `REVISION: 16`). That
// file is an addon,
// and our `three-src/` checkout is sparse (`src/` only), so -- like
// OrbitControls in D99 -- there are no line numbers to cite; the numbers below
// are the addon's own and every one of them is pinned by
// `probes/stats-smoke-m15/`.
//
// What the addon does, and what we keep:
//
//   * a panel is 80x48 with the label at (3,2) and the graph at (3,15) 74x30;
//   * the label reads "<rounded value> <NAME> (<rounded min>-<rounded max>)",
//     where min/max are monotonic over the panel's whole life (never reset);
//   * the graph scrolls one column per update(): the newest sample is drawn at
//     the right edge, a column is barHeight(value) tall, and the rest of the
//     column is the panel background;
//   * the graph area itself is the fg colour at 10% over bg -- stats.js paints
//     the area solid fg and then covers it with bg at alpha 0.9, which is the
//     same composite.
//
// Divergences (registered in three-api-design.md §20):
//
//   * stats.js rasterizes into a <canvas> and scrolls it with drawImage(self);
//     we keep a 74-slot column buffer and redraw the bars through Graphics. The
//     visible result is the same; the retained sound of 74 one-pixel rects is
//     what a display list can express.
//   * stats.js multiplies every metric by devicePixelRatio. Our window canvas is
//     already scaled by the device factor (ASC_window_render's device scale), so
//     a 9px label lands on 18 real pixels on Retina without a second factor --
//     applying PR here would double-scale the panel.
//   * the label string is only re-assigned to the TextField when it actually
//     changes: the min/max round to integers, so most frames do not change it,
//     and re-laying out text at 60 Hz for an identical string is pure cost.
package asaot.three.extras.hud
{
    import flash.display.Graphics;
    import flash.display.Shape;
    import flash.display.Sprite;
    import flash.text.TextField;
    import flash.text.TextFormat;

    public class StatsPanel extends Sprite
    {
        // stats.module.js: WIDTH/HEIGHT, TEXT_X/TEXT_Y, GRAPH_* (the PR-scaled
        // base values, i.e. PR == 1).
        public static const WIDTH:int = 80;
        public static const HEIGHT:int = 48;
        public static const TEXT_X:int = 3;
        public static const TEXT_Y:int = 2;
        public static const GRAPH_X:int = 3;
        public static const GRAPH_Y:int = 15;
        public static const GRAPH_WIDTH:int = 74;
        public static const GRAPH_HEIGHT:int = 30;
        public static const FONT_SIZE:int = 9;

        // No `name` field here: StatsPanel extends Sprite, and DisplayObject
        // already owns `name`. Redeclaring it shadowed the display property --
        // as-aot accepted it, mxmlc rejects it as a conflicting definition.
        // The panel name is therefore the sprite's own name, which is also what
        // stats.js exposes (panel.dom.className aside).
        public var fg:uint;
        public var bg:uint;

        // stats.js: `var min = Infinity, max = 0` -- the first update therefore
        // sets both from the first sample.
        public var min:Number = Number.POSITIVE_INFINITY;
        public var max:Number = 0;

        // Last sample and the normalizer handed to update(). Kept public so a
        // headless probe can read back exactly what was drawn.
        public var value:Number = 0;
        public var maxValue:Number = 0;

        private var _bgShape:Shape;
        private var _graphShape:Shape;
        private var _label:TextField;
        private var _labelText:String = "";

        // One slot per graph column, oldest first. Shifting the window left is
        // stats.js' 1px self-drawImage; the newest sample always sits at
        // GRAPH_WIDTH-1 so drawing is a plain left-to-right loop.
        private var _columns:Vector.<Number>;
        private var _filled:int = 0;

        public function StatsPanel(name:String, fg:uint, bg:uint)
        {
            this.name = name;
            this.fg = fg;
            this.bg = bg;

            this.mouseChildren = false;
            this.tabEnabled = false;

            this._columns = new Vector.<Number>(GRAPH_WIDTH, true);

            this._bgShape = new Shape();
            this._bgShape.graphics.beginFill(bg, 1);
            this._bgShape.graphics.drawRect(0, 0, WIDTH, HEIGHT);
            this._bgShape.graphics.endFill();
            this.addChild(this._bgShape);

            this._graphShape = new Shape();
            this.addChild(this._graphShape);

            this._label = new TextField();
            this._label.x = TEXT_X;
            this._label.y = TEXT_Y;
            this._label.width = GRAPH_WIDTH;
            this._label.height = FONT_SIZE + 3;
            this._label.selectable = false;
            this._label.mouseEnabled = false;
            this._label.multiline = false;
            this._label.wordWrap = false;
            this._label.defaultTextFormat = new TextFormat("_sans", FONT_SIZE, fg, true);
            this._label.text = name;
            this.addChild(this._label);

            this._drawGraph();
        }

        // ------------------------------------------------------------------
        // update -- stats.js Panel.update(value, maxValue)
        // ------------------------------------------------------------------

        public function update(value:Number, maxValue:Number):void
        {
            this.value = value;
            this.maxValue = maxValue;

            if (value < this.min) this.min = value;
            if (value > this.max) this.max = value;

            var i:int = 0;
            var last:int = GRAPH_WIDTH - 1;
            while (i < last)
            {
                this._columns[i] = this._columns[i + 1];
                i++;
            }
            this._columns[last] = value;
            if (this._filled < GRAPH_WIDTH) this._filled++;

            var label:String = labelFor(value, this.name, this.min, this.max);
            if (label != this._labelText)
            {
                this._labelText = label;
                this._label.text = label;
            }

            this._drawGraph();
        }

        // "<value> <NAME> (<min>-<max>)", all three rounded -- stats.js' fillText
        // argument verbatim.
        public static function labelFor(value:Number, name:String, min:Number, max:Number):String
        {
            return Math.round(value) + " " + name + " (" + Math.round(min) + "-" + Math.round(max) + ")";
        }

        // Height of a graph column, in stage units. stats.js derives it from
        // `(1 - value/maxValue) * GRAPH_HEIGHT` covering the fg column with bg,
        // i.e. the visible bar is value/maxValue of the graph height. A
        // non-positive or NaN normalizer draws nothing instead of NaN-ing the
        // rect, and a sample above the normalizer saturates at full height
        // (stats.js draws a full-height column there too).
        public static function barHeight(value:Number, maxValue:Number):Number
        {
            if (!(maxValue > 0)) return 0;
            var t:Number = value / maxValue;
            if (!(t > 0)) return 0;
            if (t > 1) t = 1;
            return t * GRAPH_HEIGHT;
        }

        // ------------------------------------------------------------------
        // read-back for headless probes
        // ------------------------------------------------------------------

        public function get labelText():String
        {
            return this._labelText;
        }

        public function get filledColumns():int
        {
            return this._filled;
        }

        // Graph column `index` (0 = leftmost): the sample drawn there. Slots the
        // window has not reached yet read as 0 -- columnFilled() is the guard.
        public function columnValue(index:int):Number
        {
            return this._columns[index];
        }

        public function columnFilled(index:int):Boolean
        {
            return index >= (GRAPH_WIDTH - this._filled);
        }

        public function columnHeight(index:int):Number
        {
            return barHeight(this._columns[index], this.maxValue);
        }

        // ------------------------------------------------------------------
        // painting
        // ------------------------------------------------------------------

        private function _drawGraph():void
        {
            var g:Graphics = this._graphShape.graphics;
            g.clear();

            // stats.js: solid fg over the graph rect, then bg at 0.9 on top.
            // 0.1 fg over bg is the identical composite, one fill instead of two.
            g.beginFill(this.fg, 0.1);
            g.drawRect(GRAPH_X, GRAPH_Y, GRAPH_WIDTH, GRAPH_HEIGHT);
            g.endFill();

            var first:int = GRAPH_WIDTH - this._filled;
            g.beginFill(this.fg, 1);
            var i:int = first;
            while (i < GRAPH_WIDTH)
            {
                var h:Number = barHeight(this._columns[i], this.maxValue);
                if (h > 0)
                {
                    g.drawRect(GRAPH_X + i, GRAPH_Y + GRAPH_HEIGHT - h, 1, h);
                }
                i++;
            }
            g.endFill();
        }
    }
}