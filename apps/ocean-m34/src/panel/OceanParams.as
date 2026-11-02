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
//   * scatter colour as a colour picker -- asaotui has no colour widget yet, so
//     the presets are the only way to move it.
//   * turbidity / contrast / saturation / bloom -- the ported shaders do not
//     declare those uniforms (the LUT is baked from fixed Rayleigh/Mie/ozone
//     coefficients and the composite grades with one exposure multiply). Adding
//     them would mean editing the shaders, which are the original author's.
//   * render resolution / MSAA -- both are baked into the target sizes and the
//     pass list at createScene(); a live change is a rebuild, not a drag.
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

        public var reflections:Boolean = true;

        // Which named camera the frame loop should use. 0 is the demo's own 26 s
        // loop (the one that crosses the waterline, so the self-checks see both
        // halves); 1.. are the reference's `views` entries, in its GUI order.
        public var view:int = 0;

        // ---- water colour, derived ---------------------------------------
        // `absorption` is what the shaders sample, `absorbBase` is the preset's own
        // value before `clarity` divides it (main.js: `absorption.copy(base)
        // .multiplyScalar(1 / clarity)`). Kept as ARRAYS that are mutated in place:
        // the uniform upload reads them every frame, and a fresh array per frame
        // would be an allocation in the hot path.
        public var absorption:Array = [0.17, 0.055, 0.038];
        public var absorbBase:Array = [0.17, 0.055, 0.038];
        public var scatter:Array = [0.010, 0.062, 0.085];

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
            ["exposure", "Exposure", 0.25, 4, 2]
        ];

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

        // [name, absorption r/g/b, scatter r/g/b]. Index 0 is the port's own look;
        // 1..6 are the reference's WATER_PRESETS in its own order.
        public static const PRESETS:Array = [
            ["port default", [0.17, 0.055, 0.038], [0.010, 0.062, 0.085]],
            ["clear", [0.42, 0.075, 0.048], [0.0, 0.05, 0.08]],
            ["tropical", [0.36, 0.045, 0.06], [0.0, 0.085, 0.085]],
            ["toxic green", [0.45, 0.1, 1.1], [0.05, 0.1, 0.004]],
            ["purple", [0.22, 0.85, 0.1], [0.05, 0.0, 0.09]],
            ["rust orange", [0.1, 0.34, 1.2], [0.11, 0.035, 0.004]],
            ["murky brown", [0.55, 0.62, 0.9], [0.045, 0.045, 0.022]]
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
            this.absorbBase[0] = a[0];
            this.absorbBase[1] = a[1];
            this.absorbBase[2] = a[2];
            this.scatter[0] = s[0];
            this.scatter[1] = s[1];
            this.scatter[2] = s[2];
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
            this.reflections = d.reflections;
            this.view = d.view;
            this.absorbBase[0] = d.absorbBase[0];
            this.absorbBase[1] = d.absorbBase[1];
            this.absorbBase[2] = d.absorbBase[2];
            this.scatter[0] = d.scatter[0];
            this.scatter[1] = d.scatter[1];
            this.scatter[2] = d.scatter[2];
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