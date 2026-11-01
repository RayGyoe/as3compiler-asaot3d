// asaot.three.lights.LightProbe -- a light whose colour/intensity live in SH.
//
// Borrows src/lights/LightProbe.js (r187): a Light whose `sh` is a
// SphericalHarmonics3 instead of a flat colour. three.js's shader evaluates the
// SH per fragment and adds it to the AMBIENT bucket (`irradiance`), keeping it
// separate from the environment's `iblIrradiance`
// (lights_fragment_begin.glsl.js:224-232). That split is preserved here.
//
// M27 deviates in ONE place, and the deviation is visible in the type: this
// backend cannot evaluate SH9 in AGAL inside the instruction budget the standard
// program has left (a faithful evaluation is ~40 instructions against ~90 of
// headroom, before M25-R1's own needs). So the renderer BAKES the probe's
// irradiance into a small cube face set on the CPU and samples it at the
// shading normal -- the same "bake on the CPU, sample with one `tex`" strategy
// M25 uses for HDR environments. `SphericalHarmonics3` and
// `LightProbeGenerator` are still the three.js API and still the definition of
// the value; only the evaluation site moved (D176).
//
// `version` is the invalidation hook: mutating `sh` in place cannot be observed,
// so bump it (or call `invalidate()`) and the renderer re-bakes on the next
// draw. Assigning a new `sh` object bumps it automatically.
package asaot.three.lights
{
    import asaot.three.math.SphericalHarmonics3;
import asaot.three.math.Vector3;

    public class LightProbe extends Light
    {
        // Set by the sh setter; the renderer compares it against the version it
        // baked from.
        public var version:int;

        private var _sh:SphericalHarmonics3;

        public function LightProbe(sh:SphericalHarmonics3 = null, intensity:Number = 1)
        {
            // three.js calls Light(undefined, intensity), and `new Color(undefined)`
            // is white -- so a probe with no color behaves like a white light and
            // all the direction comes from `sh`.
            super(0xffffff, intensity);
            this._sh = sh != null ? sh : new SphericalHarmonics3();
            this.version = 0;
        }

        public function get sh():SphericalHarmonics3 { return this._sh; }

        public function set sh(value:SphericalHarmonics3):void
        {
            this._sh = value != null ? value : new SphericalHarmonics3();
            this.version++;
        }

        public function invalidate():void
        {
            this.version++;
        }

        // The irradiance this probe delivers to a surface with normal `normal`,
        // in the same units as three.js: coefficient * A_l * basis * intensity.
        public function getIrradianceAt(normal:Vector3, target:Vector3):Vector3
        {
            this._sh.getIrradianceAt(normal, target);
            target.multiplyScalar(this.intensity);
            return target;
        }
    }
}