// panel.OceanPanelView -- the M34 control panel's description.
//
// The tree is DESCRIBED, not built: `render()` returns a fresh Node tree and
// asaotui reconciles it against the retained one, so a widget's drag state
// survives a re-description. Every control therefore carries a stable `key`
// (the parameter's NAME, which is also what OceanParams.valueOf/setValue take --
// one identifier from the table to the model).
//
// ALIGNMENT WITH THE WEB REFERENCE: the sections, the control order, the labels
// and the ranges are `temp/ultra-water/src/main.js`'s lil-gui tree. lil-gui's
// folders become the section headers here and the whole stack scrolls, because a
// 600 px window cannot show 24 rows at once; lil-gui solves the same problem by
// letting the panel overflow the viewport.
//
// WIDGET SUBSET: asaotui has slider / checkbox / select / button / text, which is
// enough for every numeric row and the two menus. It has no colour picker, so the
// water colour moves through the `preset` select (see OceanParams.PRESETS) and no
// "addColor" row exists -- an approximation is reported, not faked with three
// sliders that would look like a different control.
package panel
{
    import asaot.ui.Dirty;
    import asaot.ui.Node;
    import asaot.ui.View;
    import asaot.ui.button;
    import asaot.ui.checkbox;
    import asaot.ui.column;
    import asaot.ui.divider;
    import asaot.ui.row;
    import asaot.ui.scrollView;
    import asaot.ui.select;
    import asaot.ui.slider;
    import asaot.ui.text;
    import asaot.ui.style.Length;

    public class OceanPanelView extends View
    {
        // Panel geometry. Kept here rather than in style literals because the app
        // logs the width it reserved on the right, and a number that is logged
        // separately from the layout is a number that can drift.
        public static const PANEL_W:Number = 300;
        public static const PANEL_PAD:Number = 12;
        public static const PANEL_GAP:Number = 8;

        // Vertical space the fixed rows need: title + subtitle + divider + the
        // CAMERA label + the camera select + the reset row + the paddings and gaps
        // between them. The scroll viewport takes the rest, which is why it is
        // computed instead of guessed: a resize must not clip the last slider.
        private static const FIXED_H:Number = 196;

        // One slider row: an 11 pt label on top, the widget's track 12 pt above the
        // row's bottom edge, and room between them to read. The widget's own default
        // is 40 (SliderWidget.measure); 34 is the tallest row that still fits the
        // 24-row stack in a 600 pt window, and it is EXPLICIT because an auto row gets
        // squeezed by the scroll view instead of scrolling (see sliderFor()).
        private static const SLIDER_H:Number = 34;

        private var state:OceanParams;
        private var changed:Function;

        // Presentation-only state (it is not scene state, so it does not belong in
        // OceanParams): a hidden panel must leave a way back, or the first click on
        // the collapse button makes the whole control surface unreachable.
        private var _open:Boolean = true;

        private var _stageH:Number = 600;

        // WHICH DROPDOWN IS OPEN, if any (the camera or the water preset).
        //
        // `open` is AUTHOR-OWNED in asaotui's select: the widget reports the intent
        // through onOpenChange and this view re-describes, which is what keeps the
        // dropdown a pure function of the model. Without it the caret is a picture of
        // a menu that cannot open.
        private var _openKey:String = null;

        public function OceanPanelView(state:OceanParams, changed:Function):void
        {
            super();
            this.state = state;
            this.changed = changed;
            // Apply preset 0 once so `absorption`/`scatter` are the derived copies of
            // the base arrays from the very first frame (the shaders read those).
            state.setPreset(state.preset);
        }

        // Called from the app's createScene() and onViewportResize(): the viewport
        // height is the only input the scroll view needs.
        public function setStageSize(w:int, h:int):void
        {
            this._stageH = h;
        }

        public override function render():Node
        {
            var self:OceanPanelView = this;
            if (!this._open)
            {
                // Collapsed: one button, top-right, where the panel's own header was.
                // The same corner keeps it findable (the Stats HUD owns top-left).
                //
                // ALIGNED WITH `alignItems`, NOT `justifyContent`: asaotui's style
                // INHERITS an unset property from the parent (Style.resolve), and
                // OverlayChrome.MENU_ITEM does not set `justifyContent` -- so a root
                // that said `justifyContent:"flex-end"` would right-align every row of
                // a dropdown opened from inside this panel. The cross axis is the one
                // MENU_ITEM does override (`alignItems:"center"`), so anchoring the
                // panel with `alignItems:"flex-end"` leaves the menus alone.
                return column({ alignItems: "flex-end",
                             size: [Length.pct(1), Length.pct(1)] }, [
                    button({ key: "show", label: "panel", width: 76,
                             onClick: function ():void { self.toggleOpen(true); } })
                ]);
            }

            var p:OceanParams = this.state;
            var cb:Function = this.changed;
            var inner:Number = PANEL_W - 2 * PANEL_PAD;
            var viewH:Number = this._stageH - FIXED_H;
            if (viewH < 120) viewH = 120;

            var body:Array = [];
            this.addSection(body, "SUN & SKY", OceanParams.SUN, cb);
            this.addSection(body, "WAVES", OceanParams.WAVES, cb);
            this.addDivider(body);

            // ---- water ------------------------------------------------------
            body.push(this.header("WATER"));
            body.push(select({ key: "preset", value: String(OceanParams.PRESETS[p.preset][0]),
                options: OceanParams.presetLabels(), width: inner,
                open: this._openKey == "preset",
                onOpenChange: function (o:Boolean):void { self.setOpen(o, "preset"); },
                onSelect: function (i:int):void
                {
                    p.setPreset(i);
                    self.setOpen(false, "preset");
                    cb(Dirty.ALL);
                } }));
            this.addRows(body, OceanParams.WATER, cb);
            this.addDivider(body);

            this.addSection(body, "POST", OceanParams.POST, cb);
            this.addDivider(body);

            // ---- quality ----------------------------------------------------
            body.push(this.header("QUALITY"));
            body.push(checkbox({ key: "reflections", label: "Planar reflections",
                checked: p.reflections,
                onChange: function (v:Boolean):void { p.reflections = v; cb(Dirty.ALL); } }));
            // The one row the web GUI has that this port cannot honour at runtime.
            // Said out loud instead of drawn as a dead control.
            body.push(text("resolution / MSAA: fixed at build",
                { text: { fontSize: 10, color: 0x6E7A90 } }));

            return column({ alignItems: "flex-end", size: [Length.pct(1), Length.pct(1)] }, [
                column({ key: "panel", width: Length.px(PANEL_W), height: Length.pct(1),
                         background: 0x14171E, padding: PANEL_PAD, gap: PANEL_GAP,
                         borderWidths: [0, 0, 0, 1], borderColor: 0x2A3040,
                         text: { color: 0xD8DEEA } }, [
                    row({ gap: 6, alignItems: "center" }, [
                        text("Gelatin Water", { text: { fontSize: 15, fontWeight: "bold",
                                                       color: 0xE8ECF4 }, flexGrow: 1 }),
                        button({ key: "hide", label: "-", width: 28,
                                 onClick: function ():void { self.toggleOpen(false); } })
                    ]),
                    text("M34 · native shader · asaotui", { text: { fontSize: 10, color: 0x8A93A6 } }),
                    divider({ size: [Length.pct(1), Length.px(1)], background: 0x2A3040 }),
                    this.header("CAMERA"),
                    select({ key: "view", value: String(OceanParams.VIEWS[p.view]),
                             options: OceanParams.VIEWS, width: inner,
                             open: this._openKey == "view",
                             onOpenChange: function (o:Boolean):void { self.setOpen(o, "view"); },
                             onSelect: function (i:int):void
                             {
                                 p.view = i;
                                 self.setOpen(false, "view");
                                 cb(Dirty.ALL);
                             } }),
                    scrollView({ key: "sv", size: [inner, viewH],
                                 scrollbarY: "auto", overscroll: "none",
                                 background: 0x14171E }, body),
                    button({ key: "reset", label: "Reset",
                             onClick: function ():void { p.reset(); cb(Dirty.ALL); } })
                ])
            ]);
        }

        // Open or close one dropdown. Closing is unconditional (any key closes,
        // including the one being clicked) because two open menus at once is not a
        // state the widget set can express; opening is keyed so the OTHER one closes.
        public function setOpen(open:Boolean, key:String):void
        {
            var next:String = open ? key : null;
            if (this._openKey == next) return;
            this._openKey = next;
            this.changed(Dirty.ALL);
        }

        // The collapse toggle. A method (not a closure body) so the state change is
        // written in one place and the invalidation cannot be forgotten.
        public function toggleOpen(open:Boolean):void
        {
            if (this._open == open) return;
            this._open = open;
            this.changed(Dirty.ALL);
        }

        public function isOpen():Boolean
        {
            return this._open;
        }

        // ------------------------------------------------------------------
        // row builders
        // ------------------------------------------------------------------

        // A section header followed by one slider per table entry.
        private function addSection(out:Array, title:String, spec:Array, cb:Function):void
        {
            out.push(this.header(title));
            this.addRows(out, spec, cb);
        }

        private function addRows(out:Array, spec:Array, cb:Function):void
        {
            var i:int = 0;
            while (i < spec.length)
            {
                out.push(this.sliderFor(spec[i], cb));
                i++;
            }
        }

        private function addDivider(out:Array):void
        {
            out.push(divider({ size: [Length.pct(1), Length.px(1)], background: 0x242A38 }));
        }

        private function header(content:String):Node
        {
            return text(content, { text: { fontSize: 11, fontWeight: "bold", color: 0x7C879C } });
        }

        // A FACTORY, not a closure written in the loop: AS3 hoists `var` per
        // function, so a closure built inside addRows would capture the LAST table
        // entry and every slider would write that one parameter (the same trap
        // OptionSupport.tapIndex documents). The parameter `s` here is a fresh
        // binding per call.
        private function sliderFor(s:Array, cb:Function):Node
        {
            var p:OceanParams = this.state;
            var name:String = s[0];
            var lo:Number = s[2];
            var hi:Number = s[3];
            var dec:int = s[4];
            var v:Number = p.valueOf(name);
            var inner:Number = PANEL_W - 2 * PANEL_PAD;

            return slider(s[1] + " " + v.toFixed(dec) + unitOf(name), {
                key: name,
                value: OceanParams.norm(v, lo, hi),
                // EXPLICIT height, not just an inherited one: the widget draws its label
                // at the top and its track at `absH - 12`, so a row squeezed below ~34pt
                // paints the track THROUGH the label. An explicit size also becomes the
                // scrollView's per-child min (ScrollViewWidget.measure), which is what
                // stops a long section from being compressed to fit the viewport
                // instead of scrolling.
                size: [inner, SLIDER_H],
                // Parameter rows read as SECOND level: the section headers are the
                // primary structure (11pt dimmer), so the widget's default bold 13pt
                // label would invert the hierarchy the reference's lil-gui has.
                text: { fontSize: 11, color: 0xC9D2E2 },
                onChange: function (t:Number):void
                {
                    p.setValue(name, OceanParams.denorm(t, lo, hi));
                    cb(Dirty.ALL);
                }
            });
        }

        // Only the angles are unitless-looking otherwise; km / m/s / scale need no
        // suffix beyond the label the table already carries.
        private function unitOf(name:String):String
        {
            if (name == "sunElevation" || name == "sunAzimuth" ||
                name == "windDirection" || name == "swellDirection")
            {
                return "\u00b0";
            }
            return "";
        }
    }
}