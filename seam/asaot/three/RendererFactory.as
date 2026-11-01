// asaot.three.RendererFactory -- picks the renderer backend at RUN time.
//
// The engine has exactly one renderer seam (IRenderer) and two implementations:
//
//   AGALRenderer         default; machine-generates AGAL, runs wherever AIR runs.
//   NativeShaderRenderer E6 (opt-in); drives Context3DNative so an author's GLSL
//                        ES 3.00 can reach the GPU.
//
// WHY A PROBE RATHER THAN A BUILD-TIME CHOICE. The same sources must build twice:
// `--features native-shader` (the class exists and this returns it) and a default
// build / `adl` (the class does not exist at all). AS3 has no constant-existence
// test and a static reference to a missing class is a compile error in type
// position (#1046) or a runtime #1065 in expression position, so the only portable
// shape is `getDefinitionByName("...")` inside try/catch -- exactly what
// AGALRenderer.translatorClass() does for AGALTranslator. A miss is not an error
// here: it is the answer "this build has no native channel".
//
// CONSEQUENCE FOR --air-app, and the reason `extra-roots` exists (§6.7 of
// native-shader.md): that probe is a STRING, so the reachability closure sees no
// reference edge to NativeShaderRenderer and drops its source file. Add
//
//     "extra-roots": ["asaot.three.NativeShaderRenderer"]
//
// to the demo's build manifest. Without it the probe misses, the factory falls
// back to AGALRenderer, and a ShaderMaterial reports the missing channel instead
// of drawing -- loud, but not the build the author asked for.
package asaot.three
{
    import flash.display3D.Context3D;
    import flash.utils.getDefinitionByName;

    public class RendererFactory
    {
        public static const NATIVE_RENDERER:String = "asaot.three.NativeShaderRenderer";
        public static const NATIVE_CONTEXT:String = "flash.display3D.Context3DNative";

        // Probed once. A null answer is cached as an answer, not re-probed: a
        // class cannot appear mid-run, and this is called on every renderer
        // construction (every demo, every window).
        private static var _probed:Boolean = false;
        private static var _nativeClass:Class = null;

        public static function create(context:Context3D):AGALRenderer
        {
            var cls:Class = nativeRendererClass();
            if (cls == null) return new AGALRenderer(context);
            return AGALRenderer(new cls(context));
        }

        // The class to instantiate, or null. Public so a demo can print which
        // backend it got instead of guessing from the picture.
        public static function nativeRendererClass():Class
        {
            if (_probed) return _nativeClass;
            _probed = true;
            if (!hasNativeChannel()) return null;
            try
            {
                _nativeClass = Class(getDefinitionByName(NATIVE_RENDERER));
            }
            catch (e:Error)
            {
                // The feature is on but this build's sources do not include the
                // renderer (the --air-app closure case above).
                _nativeClass = null;
            }
            return _nativeClass;
        }

        // Does this build carry Context3DNative at all? Distinct from the question
        // above: with the class present but the *renderer* pruned, a ShaderMaterial
        // still cannot be drawn, and the diagnostic should say which one is missing.
        public static function hasNativeChannel():Boolean
        {
            try
            {
                var cls:Class = Class(getDefinitionByName(NATIVE_CONTEXT));
                return cls != null;
            }
            catch (e:Error)
            {
                return false;
            }
        }

        // A one-line answer for a demo's HUD / a probe's stdout. Names the two
        // facts separately so a report never has to be interpreted.
        public static function describe():String
        {
            var channel:Boolean = hasNativeChannel();
            var renderer:Boolean = (nativeRendererClass() != null);
            return "native channel=" + channel + " native renderer=" + renderer +
                (renderer ? "" : " (ShaderMaterial will refuse to draw)");
        }
    }
}