// OceanM34Assets.as -- the GLSL this demo ships, embedded at build time.
//
// WHY EMBED AND NOT `app:/assets/...`. A shader is source code, not content: it has to be
// identical in the two builds this repo always keeps side by side (AOT and `adl`), and a
// runtime read adds an ioError path that can only fail the way a demo fails -- late, in a
// frame, as a black screen. `[Embed(mimeType="application/octet-stream")]` turns each file
// into a ByteArray class in BOTH toolchains, so the GLSL is versioned with the code, is
// identical in the SWF and the Mach-O, and cannot be found missing at runtime.
//
// The files themselves live in asaot3d/assets/ocean/ and are includable blocks, not just
// whole programs: a pass pulls the declarations it actually references. That matters
// because the native channel binds author uniforms BY REFLECTED NAME, and a uniform the
// optimiser dropped is an ArgumentError at draw time -- a block that carries a uniform a
// pass does not use is a latent crash, not dead weight.
package
{
    import flash.utils.ByteArray;

    public class OceanM34Assets
    {
        // ---- atmosphere (Hillaire 2020 sky, ported from src/scene/atmosphere.js) ----
        [Embed(source="../../../assets/ocean/atmo_core.glsl", mimeType="application/octet-stream")]
        private static const ATMO_CORE:Class;
        [Embed(source="../../../assets/ocean/atmo_math.glsl", mimeType="application/octet-stream")]
        private static const ATMO_MATH:Class;
        [Embed(source="../../../assets/ocean/atmo_lut.glsl", mimeType="application/octet-stream")]
        private static const ATMO_LUT:Class;
        [Embed(source="../../../assets/ocean/atmo_sky.glsl", mimeType="application/octet-stream")]
        private static const ATMO_SKY:Class;
        [Embed(source="../../../assets/ocean/atmo_phases.glsl", mimeType="application/octet-stream")]
        private static const ATMO_PHASES:Class;
        [Embed(source="../../../assets/ocean/atmo_ms.glsl", mimeType="application/octet-stream")]
        private static const ATMO_MS:Class;
        [Embed(source="../../../assets/ocean/atmo_integrate.glsl", mimeType="application/octet-stream")]
        private static const ATMO_INTEGRATE:Class;
        [Embed(source="../../../assets/ocean/atmo_integrate_ms.glsl", mimeType="application/octet-stream")]
        private static const ATMO_INTEGRATE_MS:Class;

        // ---- ocean simulation (Ultra-Water src/water/OceanSim.js) ----
        [Embed(source="../../../assets/ocean/sim_common.glsl", mimeType="application/octet-stream")]
        private static const SIM_COMMON:Class;
        [Embed(source="../../../assets/ocean/sim_init.frag", mimeType="application/octet-stream")]
        private static const SIM_INIT:Class;
        [Embed(source="../../../assets/ocean/sim_evolve.frag", mimeType="application/octet-stream")]
        private static const SIM_EVOLVE:Class;
        [Embed(source="../../../assets/ocean/sim_fft.frag", mimeType="application/octet-stream")]
        private static const SIM_FFT:Class;
        [Embed(source="../../../assets/ocean/sim_assemble.frag", mimeType="application/octet-stream")]
        private static const SIM_ASSEMBLE:Class;

        // ---- the frame: geometry, water, downstream effects, composite ----
        [Embed(source="../../../assets/ocean/quad.vert", mimeType="application/octet-stream")]
        private static const QUAD_VERT:Class;
        [Embed(source="../../../assets/ocean/sky.vert", mimeType="application/octet-stream")]
        private static const SKY_VERT:Class;
        [Embed(source="../../../assets/ocean/sky.frag", mimeType="application/octet-stream")]
        private static const SKY_FRAG:Class;
        [Embed(source="../../../assets/ocean/trans.frag", mimeType="application/octet-stream")]
        private static const TRANS_FRAG:Class;
        [Embed(source="../../../assets/ocean/ms.frag", mimeType="application/octet-stream")]
        private static const MS_FRAG:Class;
        [Embed(source="../../../assets/ocean/sky_lut.frag", mimeType="application/octet-stream")]
        private static const SKY_LUT_FRAG:Class;
        [Embed(source="../../../assets/ocean/water.vert", mimeType="application/octet-stream")]
        private static const WATER_VERT:Class;
        [Embed(source="../../../assets/ocean/water.frag", mimeType="application/octet-stream")]
        private static const WATER_FRAG:Class;
        [Embed(source="../../../assets/ocean/water_at.glsl", mimeType="application/octet-stream")]
        private static const WATER_AT:Class;
        [Embed(source="../../../assets/ocean/terrain.vert", mimeType="application/octet-stream")]
        private static const TERRAIN_VERT:Class;
        [Embed(source="../../../assets/ocean/terrain.frag", mimeType="application/octet-stream")]
        private static const TERRAIN_FRAG:Class;
        [Embed(source="../../../assets/ocean/caustics.vert", mimeType="application/octet-stream")]
        private static const CAUSTICS_VERT:Class;
        [Embed(source="../../../assets/ocean/caustics.frag", mimeType="application/octet-stream")]
        private static const CAUSTICS_FRAG:Class;
        [Embed(source="../../../assets/ocean/caustics_lookup.glsl", mimeType="application/octet-stream")]
        private static const CAUSTICS_LOOKUP:Class;
        [Embed(source="../../../assets/ocean/spray.vert", mimeType="application/octet-stream")]
        private static const SPRAY_VERT:Class;
        [Embed(source="../../../assets/ocean/spray.frag", mimeType="application/octet-stream")]
        private static const SPRAY_FRAG:Class;
        [Embed(source="../../../assets/ocean/lens.frag", mimeType="application/octet-stream")]
        private static const LENS_FRAG:Class;
        [Embed(source="../../../assets/ocean/shafts.frag", mimeType="application/octet-stream")]
        private static const SHAFTS_FRAG:Class;
        [Embed(source="../../../assets/ocean/composite.frag", mimeType="application/octet-stream")]
        private static const COMPOSITE_FRAG:Class;
        [Embed(source="../../../assets/ocean/present.frag", mimeType="application/octet-stream")]
        private static const PRESENT_FRAG:Class;

        private static var _cache:Object = {};

        // One asset as text. Cached: a program is compiled once per material, but the
        // strings are also used by the log line that reports the assembled sizes.
        public static function text(name:String):String
        {
            var hit:String = _cache[name];
            if (hit != null) return hit;
            var cls:Class = CLS[name];
            if (cls == null) throw new Error("OceanM34Assets: no asset named '" + name + "'");
            var bytes:ByteArray = new cls() as ByteArray;
            var s:String = bytes.readUTFBytes(bytes.length);
            _cache[name] = s;
            return s;
        }

        // Assemble a program: one `#version` line at the very top (GLSL requires it
        // first, and every block file starts with its own copy), then the include blocks
        // in dependency order, then the pass's own body with its `#version` stripped.
        //
        // The blocks must be listed in the order their symbols are declared: GLSL has no
        // forward declarations, so atmo_phases before atmo_integrate, and so on.
        public static function program(main:String, includes:Array):String
        {
            // `precision highp` is not the default for float or int in ES 3.00, and a
            // mediump FFT stage index would silently wrap; it goes in the header so no
            // block can forget it.
            var out:String = "#version 300 es\nprecision highp float;\nprecision highp int;\n";
            var i:int;
            if (includes != null)
            {
                for (i = 0; i < includes.length; i++)
                {
                    out += stripVersion(text(String(includes[i]))) + "\n";
                }
            }
            return out + stripVersion(text(main));
        }

        private static function stripVersion(s:String):String
        {
            var nl:int = s.indexOf("\n");
            if (nl < 0) return s;
            if (s.substr(0, nl).indexOf("#version") >= 0) return s.substr(nl + 1);
            return s;
        }

        private static const CLS:Object = {
            atmo_core: ATMO_CORE,
            atmo_math: ATMO_MATH,
            atmo_lut: ATMO_LUT,
            atmo_sky: ATMO_SKY,
            atmo_phases: ATMO_PHASES,
            atmo_ms: ATMO_MS,
            atmo_integrate: ATMO_INTEGRATE,
            atmo_integrate_ms: ATMO_INTEGRATE_MS,
            sim_common: SIM_COMMON,
            sim_init: SIM_INIT,
            sim_evolve: SIM_EVOLVE,
            sim_fft: SIM_FFT,
            sim_assemble: SIM_ASSEMBLE,
            quad: QUAD_VERT,
            sky_vert: SKY_VERT,
            sky_frag: SKY_FRAG,
            trans_frag: TRANS_FRAG,
            ms_frag: MS_FRAG,
            sky_lut_frag: SKY_LUT_FRAG,
            water_vert: WATER_VERT,
            water_frag: WATER_FRAG,
            water_at: WATER_AT,
            terrain_vert: TERRAIN_VERT,
            terrain_frag: TERRAIN_FRAG,
            caustics_vert: CAUSTICS_VERT,
            caustics_frag: CAUSTICS_FRAG,
            caustics_lookup: CAUSTICS_LOOKUP,
            spray_vert: SPRAY_VERT,
            spray_frag: SPRAY_FRAG,
            lens_frag: LENS_FRAG,
            shafts_frag: SHAFTS_FRAG,
            composite_frag: COMPOSITE_FRAG,
            present_frag: PRESENT_FRAG
        };
    }
}