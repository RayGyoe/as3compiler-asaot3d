// panel.PanelState -- the control panel's model (M24).
//
// WHY A MODEL AT ALL: a widget reports (`onChange`/`onSelect`) and NEVER mutates
// the scene. The frame loop is the only place that reads this state and writes
// Scene / Light / Material / AGALRenderer, so the panel and the shader can never
// disagree about what the current value is. That is the same split as
// asaotui's docs app (model -> notify -> invalidate -> describe) and the same
// reason the M20 fog bug was invisible: two places held "the fog scale" and only
// one of them was ever looked at.
//
// Values are the AUTHOR's units (world units, degrees, 0..1 exposure), not the
// widget's. A slider speaks 0..1 (asaot.ui.SliderNode.value), so the mapping
// lives in one place -- the getters below -- and the view/renderer never repeat
// the arithmetic.
package panel
{
    public class PanelState
    {
        // ---- fog --------------------------------------------------------
        public var fogOn:Boolean = true;
        public var fogNear:Number = 8;
        public var fogFar:Number = 34;
        // Fog colour, warm brown: the M20 acceptance scene's own value, so a
        // reader who compares the two screenshots sees the same bar colour.
        public var fogColor:int = 0x7a4326;

        // ---- sun --------------------------------------------------------
        public var sunIntensity:Number = 2.6;
        public var sunAngle:Number = 35;         // degrees around +Y
        public var sunHeight:Number = 4.0;
        public var shadows:Boolean = true;

        // ---- render -----------------------------------------------------
        public var toneMapping:int = 2;          // AGALRenderer.ACESFilmicToneMapping
        public var exposure:Number = 1.0;
        public var wireframe:Boolean = false;

        // Tone-mapping menu. Order IS the mapping (index == AGALRenderer constant
        // 0/1/2), so the select's onSelect index can be stored as-is; a label list
        // that did not line up with the constants would silently pick the wrong
        // curve.
        public static const TONE_LABELS:Array = ["None", "Linear", "ACES"];

        // ---- the 0..1 <-> author-units mapping ---------------------------
        //
        // WINDOWS ARE CHOSEN SO THE DEFAULT SITS AT THE SAME FRACTION for every
        // control (fog near 8 of 0..20, far 34 of 12..60, sun 2.6 of 0..5,
        // exposure 1.0 of 0..2.5): a panel whose knobs all start at the same place
        // reads at a glance, and a wrong drag is obvious.
        public static const FOG_NEAR_MIN:Number = 0;
        public static const FOG_NEAR_MAX:Number = 20;
        public static const FOG_FAR_MIN:Number = 12;
        public static const FOG_FAR_MAX:Number = 60;
        public static const SUN_MAX:Number = 5;
        public static const EXPOSURE_MAX:Number = 2.5;

        public function fogNear01():Number
        {
            return (this.fogNear - FOG_NEAR_MIN) / (FOG_NEAR_MAX - FOG_NEAR_MIN);
        }

        public function setFogNear01(v:Number):void
        {
            this.fogNear = FOG_NEAR_MIN + clamp01(v) * (FOG_NEAR_MAX - FOG_NEAR_MIN);
            // `far` must stay beyond `near` or the fog scale is 1/(far-near) of a
            // non-positive span. The renderer's linearFogScale() already guards an
            // empty span, but a panel that can produce one is a panel that can
            // silently switch the fog off, so the invariant is kept HERE.
            if (this.fogFar <= this.fogNear) this.fogFar = this.fogNear + 1;
        }

        public function fogFar01():Number
        {
            return (this.fogFar - FOG_FAR_MIN) / (FOG_FAR_MAX - FOG_FAR_MIN);
        }

        public function setFogFar01(v:Number):void
        {
            this.fogFar = FOG_FAR_MIN + clamp01(v) * (FOG_FAR_MAX - FOG_FAR_MIN);
            if (this.fogFar <= this.fogNear) this.fogFar = this.fogNear + 1;
        }

        public function sunIntensity01():Number
        {
            return this.sunIntensity / SUN_MAX;
        }

        public function setSunIntensity01(v:Number):void
        {
            this.sunIntensity = clamp01(v) * SUN_MAX;
        }

        public function sunAngle01():Number
        {
            return (this.sunAngle + 180) / 360;
        }

        public function setSunAngle01(v:Number):void
        {
            this.sunAngle = clamp01(v) * 360 - 180;
        }

        public function exposure01():Number
        {
            return this.exposure / EXPOSURE_MAX;
        }

        public function setExposure01(v:Number):void
        {
            this.exposure = clamp01(v) * EXPOSURE_MAX;
        }

        public function reset():void
        {
            this.fogOn = true;
            this.fogNear = 8;
            this.fogFar = 34;
            this.sunIntensity = 2.6;
            this.sunAngle = 35;
            this.shadows = true;
            this.toneMapping = 2;
            this.exposure = 1.0;
            this.wireframe = false;
        }

        // One line for the log: the panel's whole state, in author units, so a
        // headless AIR run can be judged from stdout without a screenshot.
        public function describe():String
        {
            return "fog=" + this.fogOn + "(" + round2(this.fogNear) + ".." +
                round2(this.fogFar) + ")" +
                " sun=" + round2(this.sunIntensity) + "@" + round2(this.sunAngle) + "deg" +
                " shadows=" + this.shadows +
                " tone=" + TONE_LABELS[this.toneMapping] + " (" + this.toneMapping + ")" +
                " exposure=" + round2(this.exposure) +
                " wireframe=" + this.wireframe;
        }

        private static function clamp01(v:Number):Number
        {
            if (isNaN(v)) return 0;
            if (v < 0) return 0;
            if (v > 1) return 1;
            return v;
        }

        private static function round2(v:Number):Number
        {
            return Math.round(v * 100) / 100;
        }
    }
}