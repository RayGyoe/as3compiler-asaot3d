// panel.OceanParams -- the M34 control panel's model.
//
// WHAT IT IS: the same state -> frame-loop split as M24's PanelState. A widget
// reports 0..1 (asaot.ui.SliderNode.value is always 0..1) and this class converts
// it into the AUTHOR's units; nothing here touches a uniform, a texture or the
// camera. OceanM34's frame loop is the only reader, so the panel and the shaders
// cannot disagree about "the current wind speed".
//
// WHERE THE NUMBERS COME FROM: `temp/ultra-water/src/main.js`'s lil-gui tree. The
// names, the ranges and the defaults are the reference's, so a reader can put the
// web page and this demo side by side and move the same slider on both. Two
// deliberate exceptions, both noted at the field:
//
//   * windDirection / swellDirection default to the PORT's angles (0.6 rad and
//     0.6 - 0.9 rad) rather than the reference's 20 deg / -15 deg. The port picked
//     its own bearing before the panel existed, and changing a default here would
//     silently change the accepted image -- a control panel is not a retune.
//   * water presets: index 0 is the port's own colour ("port default"), then the
//     reference's six. Applying "clear" would otherwise repaint the accepted sea.
//
// WHAT IS NOT HERE, and why (all reported in the log at startup):
//   * scatter colour as a colour picker -- asaotui has no colour widget yet, so the
//     presets are the only way to move it.
//   * MSAA is a SELECT over real sample counts (see `msaa` below): the channel grows
//     a per-target multisample companion in Context3DNative.setRenderTargetSamples,
//     so the scene targets are genuinely multisampled. `renderScale` above 1 is the
//     orthogonal supersampling knob, resolved by the four-tap box in grade.frag.
//   * lens droplets and the meniscus band -- neither is in the ported pass list yet,
//     so a slider would be a picture of a control.
//
// THE GRADE'S DEFAULTS ARE IDENTITY, NOT THE REFERENCE'S. Ultra-Water ships its AgX
// look at contrast 1.12 / saturation 1.3 (PostFX.js defaults, which main.js does not
// override). This port's grade is ACES plus a 0.22 vignette, and its accepted frame
// was rendered at contrast 1.0 / saturation 1.0: copying those two numbers across
// two different tone curves would not buy parity, it would buy an unverified image.
// The ranges are the reference's, so the same slider in the same place does the same
// thing; only the starting point differs, and the panel is one drag away from the
// web's look.
package panel
{
    public class OceanParams
    {
        // ------------------------------------------------------------------
        // author units
        // ------------------------------------------------------------------
        public var sunElevation:Number = 3.5;       // degrees, the reference's golden hour
        public var sunAzimuth:Number = 205.0;       // degrees
        public var sunIntensity:Number = 9.0;       // the reference's SUN_INTENSITY
        public var cloudCoverage:Number = 0.42;     // port default (reference GUI shows 0.38)

        public var windSpeed:Number = 9.0;          // m/s
        public var windDirection:Number = 34.3775;  // degrees (0.6 rad, the port's WIND_ANGLE)
        public var fetchKm:Number = 120.0;
        public var waveScale:Number = 1.0;
        public var spreadBlend:Number = 0.85;
        public var swellScale:Number = 0.7;
        public var swellDirection:Number = -17.1887; // degrees (0.6 rad - 0.9 rad)
        public var choppiness:Number = 0.85;
        public var timeScale:Number = 1.0;

        public var preset:int = 0;
        public var clarity:Number = 1.0;
        public var roughness:Number = 0.02;
        public var refraction:Number = 0.06;
        public var reflectionDistort:Number = 0.04;
        public var foamBias:Number = 0.05;
        public var foamScale:Number = 1.3;
        public var glint:Number = 0.6;

        public var exposure:Number = 0.45;

        // ---- post (PostFX.js) --------------------------------------------
        // Auto exposure meters the HDR frame into a 32x32 log-luminance grid and adapts
        // a 1x1 exposure over ~0.4 s / ~1 s (brighten / darken). `exposure` is then an
        // exposure COMPENSATION (1 = meter-neutral) instead of an absolute multiplier,
        // exactly like the reference's `ui.exposure * uwComp`.
        public var autoExposure:Boolean = false;
        public var keyValue:Number = 0.18;          // 0.18 puts the geometric mean at middle grey
        public var minExposure:Number = 0.05;
        public var maxExposure:Number = 20.0;
        public var bloomStrength:Number = 0.05;     // main.js's override of the class default
        public var bloomThreshold:Number = 1.5;     // ditto: only above-white blooms
        public var bloomClamp:Number = 64.0;
        public var contrast:Number = 1.0;           // identity: see the header note
        public var saturation:Number = 1.0;
        public var vignette:Number = 0.22;          // the composite's own vignette

        // ---- underwater (UnderwaterPass.js) ------------------------------
        // `scattering` is the turbidity of the water column: it is added to the
        // extinction in the shaft march, so a muddy sea loses its god rays and fogs
        // the frame from the camera out. The reference's sliders are `scattering`
        // (0..0.5) and `shafts`/`shaftRange`; `underwaterExposure` is its `look`
        // compensation that keeps a submerged camera from metering to milk.
        public var scattering:Number = 0.055;      // 1/m, matches PRESETS[0]
        public var shafts:Number = 0.9;
        public var shaftRange:Number = 42.0;        // metres
        public var underwaterExposure:Number = 0.55;

        // ---- quality -----------------------------------------------------
        // Multiplies the internal render size (RW x RH). Above 1 the HDR target is
        // larger than the window and grade.frag resolves it with a four-tap box.
        public var renderScale:Number = 1.0;

        // Multisample level of the SCENE targets (opaque/water/spray/reflection and
        // their depth). 1 = off, which is also the AIR-parity default: Stage3D has no
        // such knob, so turning it on is this port's own enhancement and must be asked
        // for. Multisampling averages subpixel COVERAGE, so it fixes edges (island
        // silhouettes, the water line, spray particles) and leaves the interior of a
        // surface untouched -- which is why the full-screen GPU-data passes keep one
        // sample: they have no edge to improve.
        public var msaa:int = 1;

        public var reflections:Boolean = true;

        // Which named camera the frame loop should use. 0 is the demo's own 26 s
        // loop (the one that crosses the waterline, so the self-checks see both
        // halves); 1.. are the reference's `views` entries, in its GUI order.
        public var view:int = 0;

        // HOW MANY TIMES A VIEW HAS BEEN REQUESTED. `view` alone cannot express
        // "re-apply the view that is already selected": the cruise (0) is the default
        // and a drag transfers the camera to OrbitControls without changing the menu,
        // so clicking "auto loop (26 s)" again has to be able to give it back. The
        // select increments this on EVERY pick (the widget reports a pick on the row,
        // not on a value change), and the frame loop re-applies when the counter
        // moves. It is a request counter, not scene state -- nothing renders it.
        public var viewReq:int = 0;

        // ---- water colour, derived ---------------------------------------
        // `absorption` is what the shaders sample, `absorbBase` is the preset's own
        // value before `clarity` divides it (main.js: `absorption.copy(base)
        // .multiplyScalar(1 / clarity)`). Kept as ARRAYS that are mutated in place:
        // the uniform upload reads them every frame, and a fresh array per frame
        // would be an allocation in the hot path.
        public var absorption:Array = [0.17, 0.055, 0.038];
        public var absorbBase:Array = [0.17, 0.055, 0.038];
        public var scatter:Array = [0.010, 0.062, 0.085];
        // Per-preset tint of thin foam, as a multiplier on the port's own foam shading
        // (see PRESETS). [1,1,1] is the port's look, so preset 0 is a no-op.
        public var foamTint:Array = [1.0, 1.0, 1.0];

        // ------------------------------------------------------------------
        // tables (single source of truth for ranges + labels)
        // ------------------------------------------------------------------
        // [name, label, lo, hi, decimals] -- `name` is what setValue/valueOf take.
        public static const SUN:Array = [
            ["sunElevation", "Elevation", -2, 70, 1],
            ["sunAzimuth", "Azimuth", 0, 360, 1],
            ["sunIntensity", "Intensity", 0, 20, 1],
            ["cloudCoverage", "Cloud cover", 0, 1, 2]
        ];

        public static const WAVES:Array = [
            ["windSpeed", "Wind speed", 1, 25, 1],
            ["windDirection", "Wind dir", -180, 180, 1],
            ["fetchKm", "Fetch km", 5, 1000, 0],
            ["waveScale", "Wave scale", 0, 3, 2],
            ["spreadBlend", "Spread blend", 0, 1, 2],
            ["swellScale", "Swell scale", 0, 3, 2],
            ["swellDirection", "Swell dir", -180, 180, 1],
            ["choppiness", "Choppiness", 0, 2, 2],
            ["timeScale", "Time scale", 0, 3, 2]
        ];

        public static const WATER:Array = [
            ["clarity", "Clarity", 0.2, 4, 2],
            ["roughness", "Roughness", 0.005, 0.2, 3],
            ["refraction", "Refraction", 0, 0.2, 3],
            ["reflectionDistort", "Refl distort", 0, 0.2, 3],
            ["foamBias", "Foam bias", -0.5, 1.5, 2],
            ["foamScale", "Foam scale", 0, 6, 2],
            ["glint", "Glitter", 0, 1, 2]
        ];

        public static const POST:Array = [
            ["exposure", "Exposure", 0.25, 4, 2],
            ["keyValue", "Key value", 0.05, 0.6, 2],
            ["bloomStrength", "Bloom", 0, 0.5, 3],
            ["bloomThreshold", "Bloom thresh", 0, 10, 2],
            ["contrast", "Contrast", 0.7, 1.6, 2],
            ["saturation", "Saturation", 0, 2, 2],
            ["vignette", "Vignette", 0, 1, 2]
        ];

        public static const UNDERWATER:Array = [
            ["scattering", "Turbidity", 0, 0.5, 3],
            ["shafts", "Sun shafts", 0, 4, 2],
            ["shaftRange", "Shaft range", 5, 120, 0],
            ["underwaterExposure", "Underwater exp", 0.2, 2, 2]
        ];

        // MSAA is a SELECT for the same reason render scale is: three honest levels,
        // each one a real sample count on the scene targets. 8x is accepted by the
        // channel but not offered here -- at 2x render scale the scene targets alone
        // would be ~250 MB of multisample memory for a difference no frame shows.
        public static const MSAA_LEVELS:Array = [1, 2, 4];

        public static function msaaLabels():Array
        {
            return ["off", "2x", "4x"];
        }

        // Index of the level nearest `v` (values snap, they never land between two
        // entries), so a restored state still highlights a row.
        public static function msaaIndex(v:Number):int
        {
            var best:int = 0;
            var bd:Number = Math.abs(MSAA_LEVELS[0] - v);
            for (var i:int = 1; i < MSAA_LEVELS.length; i++)
            {
                var d:Number = Math.abs(MSAA_LEVELS[i] - v);
                if (d < bd) { bd = d; best = i; }
            }
            return best;
        }

        // Render scale is a SELECT, not a slider: every value rebuilds every
        // size-dependent render target, and the native channel has no texture dispose,
        // so a drag across a continuous range would leak one target set per pixel of
        // travel. Six steps bound the rebuilds and the leak, and match the "snap to a
        // quality preset" feel of the reference's own resolution row.
        public static const SCALES:Array = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

        public static function scaleLabels():Array
        {
            var out:Array = [];
            for (var i:int = 0; i < SCALES.length; i++)
            {
                var v:Number = SCALES[i];
                out.push((v == Math.floor(v) ? String(int(v)) : String(v)) + "x");
            }
            return out;
        }

        // Index of the scale nearest `v`, so a value restored from elsewhere still
        // highlights a row.
        public static function scaleIndex(v:Number):int
        {
            var best:int = 0;
            var bd:Number = Math.abs(SCALES[0] - v);
            for (var i:int = 1; i < SCALES.length; i++)
            {
                var d:Number = Math.abs(SCALES[i] - v);
                if (d < bd) { bd = d; best = i; }
            }
            return best;
        }

        // Camera menu. Order IS the index stored in `view`, and the first entry is
        // the demo's own loop -- an out-of-range view falls back to it.
        public static const VIEWS:Array = [
            "auto loop (26 s)",
            "Golden hour",
            "Breakers",
            "Lagoon",
            "Open ocean",
            "Aerial",
            "Underwater"
        ];

        // [name, absorption r/g/b, scatter r/g/b, foam tint r/g/b, turbidity]. Index 0
        // is the port's own look; 1..6 are the reference's WATER_PRESETS in its own
        // order, with their own foam tint and `underwater.scattering`.
        //
        // The foam tint is a MULTIPLIER here (1,1,1 = the port's existing foam), not the
        // albedo base the reference replaces: the port's foam shading is a different
        // formula, and re-basing it would repaint the accepted image.
        public static const PRESETS:Array = [
            ["port default", [0.17, 0.055, 0.038], [0.010, 0.062, 0.085], [1.0, 1.0, 1.0], 0.055],
            ["clear", [0.42, 0.075, 0.048], [0.0, 0.05, 0.08], [0.62, 0.78, 0.82], 0.03],
            ["tropical", [0.36, 0.045, 0.06], [0.0, 0.085, 0.085], [0.66, 0.86, 0.84], 0.02],
            ["toxic green", [0.45, 0.1, 1.1], [0.05, 0.1, 0.004], [0.74, 0.84, 0.42], 0.08],
            ["purple", [0.22, 0.85, 0.1], [0.05, 0.0, 0.09], [0.8, 0.66, 0.88], 0.04],
            ["rust orange", [0.1, 0.34, 1.2], [0.11, 0.035, 0.004], [0.9, 0.72, 0.55], 0.1],
            ["murky brown", [0.55, 0.62, 0.9], [0.045, 0.045, 0.022], [0.78, 0.74, 0.6], 0.25]
        ];

        public static function presetLabels():Array
        {
            var out:Array = [];
            var i:int = 0;
            while (i < PRESETS.length)
            {
                out.push(PRESETS[i][0]);
                i++;
            }
            return out;
        }

        // ------------------------------------------------------------------
        // 0..1 <-> author units
        // ------------------------------------------------------------------
        // The range comes from the table entry the caller already has, so there is
        // exactly one place a slider's span is written down.
        public static function norm(v:Number, lo:Number, hi:Number):Number
        {
            var span:Number = hi - lo;
            if (!(span > 0)) return 0;
            return clamp01((v - lo) / span);
        }

        public static function denorm(t:Number, lo:Number, hi:Number):Number
        {
            return lo + clamp01(t) * (hi - lo);
        }

        // ------------------------------------------------------------------
        // field access by NAME (the tables' first column)
        // ------------------------------------------------------------------
        // if/else rather than `this[name]`: a class instance is not a dynamic object
        // in as-aot, and `this["sunElevation"]` is not a property read there. The
        // chains below are user-edit paths (a drag), never per-frame work.
        public function valueOf(name:String):Number
        {
            if (name == "sunElevation") return this.sunElevation;
            if (name == "sunAzimuth") return this.sunAzimuth;
            if (name == "sunIntensity") return this.sunIntensity;
            if (name == "cloudCoverage") return this.cloudCoverage;
            if (name == "windSpeed") return this.windSpeed;
            if (name == "windDirection") return this.windDirection;
            if (name == "fetchKm") return this.fetchKm;
            if (name == "waveScale") return this.waveScale;
            if (name == "spreadBlend") return this.spreadBlend;
            if (name == "swellScale") return this.swellScale;
            if (name == "swellDirection") return this.swellDirection;
            if (name == "choppiness") return this.choppiness;
            if (name == "timeScale") return this.timeScale;
            if (name == "clarity") return this.clarity;
            if (name == "roughness") return this.roughness;
            if (name == "refraction") return this.refraction;
            if (name == "reflectionDistort") return this.reflectionDistort;
            if (name == "foamBias") return this.foamBias;
            if (name == "foamScale") return this.foamScale;
            if (name == "glint") return this.glint;
            if (name == "exposure") return this.exposure;
            if (name == "keyValue") return this.keyValue;
            if (name == "bloomStrength") return this.bloomStrength;
            if (name == "bloomThreshold") return this.bloomThreshold;
            if (name == "contrast") return this.contrast;
            if (name == "saturation") return this.saturation;
            if (name == "vignette") return this.vignette;
            if (name == "scattering") return this.scattering;
            if (name == "shafts") return this.shafts;
            if (name == "shaftRange") return this.shaftRange;
            if (name == "underwaterExposure") return this.underwaterExposure;
            if (name == "renderScale") return this.renderScale;
            if (name == "msaa") return this.msaa;
            throw new Error("OceanParams.valueOf: unknown control '" + name + "'");
        }

        public function setValue(name:String, v:Number):void
        {
            if (name == "sunElevation") { this.sunElevation = v; return; }
            if (name == "sunAzimuth") { this.sunAzimuth = wrap360(v); return; }
            if (name == "sunIntensity") { this.sunIntensity = nonNeg(v); return; }
            if (name == "cloudCoverage") { this.cloudCoverage = clamp01(v); return; }
            if (name == "windSpeed") { this.windSpeed = Math.max(0.1, v); return; }
            if (name == "windDirection") { this.windDirection = v; return; }
            if (name == "fetchKm") { this.fetchKm = Math.max(1.0, v); return; }
            if (name == "waveScale") { this.waveScale = nonNeg(v); return; }
            if (name == "spreadBlend") { this.spreadBlend = clamp01(v); return; }
            if (name == "swellScale") { this.swellScale = nonNeg(v); return; }
            if (name == "swellDirection") { this.swellDirection = v; return; }
            if (name == "choppiness") { this.choppiness = nonNeg(v); return; }
            if (name == "timeScale") { this.timeScale = nonNeg(v); return; }
            if (name == "clarity") { this.clarity = Math.max(0.05, v); this.refreshAbsorption(); return; }
            if (name == "roughness") { this.roughness = nonNeg(v); return; }
            if (name == "refraction") { this.refraction = nonNeg(v); return; }
            if (name == "reflectionDistort") { this.reflectionDistort = nonNeg(v); return; }
            if (name == "foamBias") { this.foamBias = v; return; }
            if (name == "foamScale") { this.foamScale = nonNeg(v); return; }
            if (name == "glint") { this.glint = clamp01(v); return; }
            if (name == "exposure") { this.exposure = Math.max(0.01, v); return; }
            if (name == "keyValue") { this.keyValue = Math.max(0.005, v); return; }
            if (name == "bloomStrength") { this.bloomStrength = nonNeg(v); return; }
            if (name == "bloomThreshold") { this.bloomThreshold = nonNeg(v); return; }
            if (name == "contrast") { this.contrast = Math.max(0.1, v); return; }
            if (name == "saturation") { this.saturation = nonNeg(v); return; }
            if (name == "vignette") { this.vignette = clamp01(v); return; }
            if (name == "scattering") { this.scattering = nonNeg(v); return; }
            if (name == "shafts") { this.shafts = nonNeg(v); return; }
            if (name == "shaftRange") { this.shaftRange = Math.max(1.0, v); return; }
            if (name == "underwaterExposure") { this.underwaterExposure = Math.max(0.01, v); return; }
            if (name == "renderScale") { this.renderScale = Math.min(2.0, Math.max(0.5, v)); return; }
            if (name == "msaa") { this.msaa = MSAA_LEVELS[msaaIndex(v)]; return; }
            throw new Error("OceanParams.setValue: unknown control '" + name + "'");
        }

        // ------------------------------------------------------------------
        // water colour
        // ------------------------------------------------------------------
        public function setPreset(i:int):void
        {
            var n:int = PRESETS.length;
            var k:int = i % n;
            if (k < 0) k += n;
            this.preset = k;
            var e:Array = PRESETS[k];
            var a:Array = e[1];
            var s:Array = e[2];
            var t:Array = e[3];
            this.absorbBase[0] = a[0];
            this.absorbBase[1] = a[1];
            this.absorbBase[2] = a[2];
            this.scatter[0] = s[0];
            this.scatter[1] = s[1];
            this.scatter[2] = s[2];
            this.foamTint[0] = t[0];
            this.foamTint[1] = t[1];
            this.foamTint[2] = t[2];
            // turbidity is part of the LOOK, not a separate switch: the reference's
            // preset handler sets `underwater.params.scattering` with the colours.
            this.scattering = e[4];
            this.refreshAbsorption();
        }

        private function refreshAbsorption():void
        {
            var k:Number = 1.0 / this.clarity;
            this.absorption[0] = this.absorbBase[0] * k;
            this.absorption[1] = this.absorbBase[1] * k;
            this.absorption[2] = this.absorbBase[2] * k;
        }

        // ------------------------------------------------------------------
        // reset + log
        // ------------------------------------------------------------------
        public function reset():void
        {
            var d:OceanParams = new OceanParams();
            this.sunElevation = d.sunElevation;
            this.sunAzimuth = d.sunAzimuth;
            this.sunIntensity = d.sunIntensity;
            this.cloudCoverage = d.cloudCoverage;
            this.windSpeed = d.windSpeed;
            this.windDirection = d.windDirection;
            this.fetchKm = d.fetchKm;
            this.waveScale = d.waveScale;
            this.spreadBlend = d.spreadBlend;
            this.swellScale = d.swellScale;
            this.swellDirection = d.swellDirection;
            this.choppiness = d.choppiness;
            this.timeScale = d.timeScale;
            this.preset = d.preset;
            this.clarity = d.clarity;
            this.roughness = d.roughness;
            this.refraction = d.refraction;
            this.reflectionDistort = d.reflectionDistort;
            this.foamBias = d.foamBias;
            this.foamScale = d.foamScale;
            this.glint = d.glint;
            this.exposure = d.exposure;
            this.autoExposure = d.autoExposure;
            this.keyValue = d.keyValue;
            this.bloomStrength = d.bloomStrength;
            this.bloomThreshold = d.bloomThreshold;
            this.contrast = d.contrast;
            this.saturation = d.saturation;
            this.vignette = d.vignette;
            this.scattering = d.scattering;
            this.shafts = d.shafts;
            this.shaftRange = d.shaftRange;
            this.underwaterExposure = d.underwaterExposure;
            this.renderScale = d.renderScale;
            this.msaa = d.msaa;
            this.reflections = d.reflections;
            this.view = d.view;
            // NOT a copy of the default, an INCREMENT. A Reset is the user's way of
            // saying "put the camera back", and it has to work in the one case where
            // nothing else moved: the camera is free (a drag took it) while `view` is
            // already 0 and the counter is already at its default. Copying 0 there
            // leaves the epoch unchanged, so applyView() would see no request at all.
            this.viewReq = this.viewReq + 1;
            this.absorbBase[0] = d.absorbBase[0];
            this.absorbBase[1] = d.absorbBase[1];
            this.absorbBase[2] = d.absorbBase[2];
            this.scatter[0] = d.scatter[0];
            this.scatter[1] = d.scatter[1];
            this.scatter[2] = d.scatter[2];
            this.foamTint[0] = d.foamTint[0];
            this.foamTint[1] = d.foamTint[1];
            this.foamTint[2] = d.foamTint[2];
            this.refreshAbsorption();
        }

        // One line, author units: a headless run can be judged from stdout without a
        // screenshot, and the panel's effect on the scene is auditable in a diff.
        public function describe():String
        {
            return "sun=" + r1(this.sunElevation) + "deg/" + r1(this.sunAzimuth) + "deg x" +
                r1(this.sunIntensity) + " cloud=" + r2(this.cloudCoverage) +
                " | wind=" + r1(this.windSpeed) + "m/s@" + r1(this.windDirection) + "deg fetch=" +
                Math.round(this.fetchKm) + "km scale=" + r2(this.waveScale) +
                " swell=" + r2(this.swellScale) + "@" + r1(this.swellDirection) +
                " chop=" + r2(this.choppiness) + " time=" + r2(this.timeScale) +
                " | water=" + PRESETS[this.preset][0] + " clarity=" + r2(this.clarity) +
                " rough=" + r3(this.roughness) + " glint=" + r2(this.glint) +
                " | exposure=" + r2(this.exposure) +
                " auto=" + this.autoExposure + " key=" + r2(this.keyValue) +
                " bloom=" + r3(this.bloomStrength) + "@" + r2(this.bloomThreshold) +
                " contrast=" + r2(this.contrast) + " saturation=" + r2(this.saturation) +
                " vignette=" + r2(this.vignette) +
                " | turbidity=" + r3(this.scattering) + " shafts=" + r2(this.shafts) +
                " scale=" + r2(this.renderScale) + " msaa=" + this.msaa +
                " reflections=" + this.reflections +
                " view=" + VIEWS[this.view];
        }

        private static function clamp01(v:Number):Number
        {
            if (isNaN(v)) return 0;
            if (v < 0) return 0;
            if (v > 1) return 1;
            return v;
        }

        private static function nonNeg(v:Number):Number
        {
            if (isNaN(v) || v < 0) return 0;
            return v;
        }

        private static function wrap360(v:Number):Number
        {
            if (isNaN(v)) return 0;
            var r:Number = v % 360;
            if (r < 0) r += 360;
            return r;
        }

        private static function r1(v:Number):Number { return Math.round(v * 10) / 10; }
        private static function r2(v:Number):Number { return Math.round(v * 100) / 100; }
        private static function r3(v:Number):Number { return Math.round(v * 1000) / 1000; }
    }
}