// panel.PanelView -- the control panel's description (M24).
//
// The tree is DESCRIBED, not built: `render()` returns a fresh Node tree, and
// asaot.ui reconciles it against the retained one, so the widget instances (and
// their drag state) survive a re-description. That is why every control carries a
// stable `key` -- without one the reconciler matches positionally, and a click
// that inserts a row would re-create the slider under the pointer.
//
// WIDGET LIBRARY: `asaotui` (a separate checkout, linked through
// `--as-class-path ../asaotui/kit --as-class-path ../asaotui/seam`; see
// apps/panel-m24/class-paths). Nothing here is a copy: the point of this demo is
// that a asaot3d app can use the real UI toolkit in place.
//
// WHERE THE PANEL SITS: the root is the full stage and the panel is pushed to the
// right edge by `justifyContent: "flex-end"`, which leaves the 3D view (and the
// top-left Stats HUD) uncovered. A control panel on the LEFT would cover the HUD;
// this split -- HUD left, panel right -- is the same one a three.js example makes
// between stats.js and lil-gui.
package panel
{
    import asaot.ui.ButtonNode;
    import asaot.ui.CheckboxNode;
    import asaot.ui.Dirty;
    import asaot.ui.Node;
    import asaot.ui.SelectNode;
    import asaot.ui.SliderNode;
    import asaot.ui.View;
    import asaot.ui.button;
    import asaot.ui.card;
    import asaot.ui.checkbox;
    import asaot.ui.column;
    import asaot.ui.divider;
    import asaot.ui.row;
    import asaot.ui.select;
    import asaot.ui.slider;
    import asaot.ui.text;
    import asaot.ui.style.Length;

    public class PanelView extends View
    {
        // Panel geometry. Kept here (not in the style literals below) because the
        // demo logs the width it reserved on the right, and a number that is
        // logged separately from the layout is a number that can drift.
        public static const PANEL_W:Number = 300;
        public static const PANEL_PAD:Number = 16;
        public static const PANEL_GAP:Number = 10;

        private var state:PanelState;
        private var changed:Function;

        public function PanelView(state:PanelState, changed:Function):void
        {
            super();
            this.state = state;
            this.changed = changed;
        }

        public override function render():Node
        {
            var s:PanelState = this.state;
            var cb:Function = this.changed;

            return row({ flexDirection: "row", justifyContent: "flex-end",
                         size: [Length.pct(1), Length.pct(1)] }, [
                column({ key: "panel", width: Length.px(PANEL_W), height: Length.pct(1),
                         background: 0x14171E, padding: PANEL_PAD, gap: PANEL_GAP,
                         borderWidths: [0, 0, 0, 1], borderColor: 0x2A3040,
                         // Inheritable default for everything below (checkbox and
                         // radio labels are painted by their widget, so they take
                         // the colour from here rather than from a label node).
                         text: { color: 0xD8DEEA } }, [
                    text("Scene controls", { text: { fontSize: 15, fontWeight: "bold",
                                                    color: 0xE8ECF4 } }),
                    text("asaotui linked in place", { text: { fontSize: 11, color: 0x8A93A6 } }),
                    // NOTE: `style: {...}` is NOT a shorthand -- OptionSupport.applyOpts
                    // does `StyleRefinement(opts.style)`, i.e. it demands a real
                    // StyleRefinement instance. The shorthand keys (size/background/...)
                    // go directly in `opts`, which is what StyleRefinement.from reads.
                    divider({ size: [Length.pct(1), Length.px(1)], background: 0x2A3040 }),

                    // ---- fog ------------------------------------------------
                    text("FOG", { text: { fontSize: 10, fontWeight: "bold", color: 0x6E7A90 } }),
                    checkbox({ key: "fogOn", label: "Enabled", checked: s.fogOn,
                               onChange: function (v:Boolean):void {
                                   s.fogOn = v; cb(Dirty.ALL);
                               } }),
                    slider("Near " + int(s.fogNear), { key: "fogNear", value: s.fogNear01(),
                        onChange: function (v:Number):void { s.setFogNear01(v); cb(Dirty.ALL); } }),
                    slider("Far " + int(s.fogFar), { key: "fogFar", value: s.fogFar01(),
                        onChange: function (v:Number):void { s.setFogFar01(v); cb(Dirty.ALL); } }),

                    // ---- sun ------------------------------------------------
                    text("SUN", { text: { fontSize: 10, fontWeight: "bold", color: 0x6E7A90 } }),
                    slider("Intensity " + round1(s.sunIntensity), { key: "sunI",
                        value: s.sunIntensity01(),
                        onChange: function (v:Number):void { s.setSunIntensity01(v); cb(Dirty.ALL); } }),
                    slider("Angle " + int(s.sunAngle) + " deg", { key: "sunA",
                        value: s.sunAngle01(),
                        onChange: function (v:Number):void { s.setSunAngle01(v); cb(Dirty.ALL); } }),
                    checkbox({ key: "shadows", label: "Cast shadows", checked: s.shadows,
                               onChange: function (v:Boolean):void {
                                   s.shadows = v; cb(Dirty.ALL);
                               } }),

                    // ---- render ---------------------------------------------
                    text("RENDER", { text: { fontSize: 10, fontWeight: "bold", color: 0x6E7A90 } }),
                    select({ key: "tone", value: PanelState.TONE_LABELS[s.toneMapping],
                             options: PanelState.TONE_LABELS, width: PANEL_W - 2 * PANEL_PAD,
                             onSelect: function (i:int):void {
                                 s.toneMapping = i; cb(Dirty.ALL);
                             } }),
                    slider("Exposure " + round1(s.exposure), { key: "expo",
                        value: s.exposure01(),
                        onChange: function (v:Number):void { s.setExposure01(v); cb(Dirty.ALL); } }),
                    checkbox({ key: "wire", label: "Wireframe", checked: s.wireframe,
                               onChange: function (v:Boolean):void {
                                   s.wireframe = v; cb(Dirty.ALL);
                               } }),

                    button({ key: "reset", label: "Reset",
                             onClick: function ():void { s.reset(); cb(Dirty.ALL); } })
                ])
            ]);
        }

        private static function round1(v:Number):String
        {
            return String(Math.round(v * 10) / 10);
        }
    }
}