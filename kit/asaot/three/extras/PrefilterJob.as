// asaot.three.extras.PrefilterJob -- the M25-R1 ladder bake, one level per step.
//
// WHY THIS EXISTS. EnvironmentPrefilter.bake() is the whole ladder in one call,
// which is what a probe or an AOT build wants. An AIR frame is a different
// budget: measured on this machine, the same six-level bake at 128px costs 84ms
// natively but 2186ms under `adl` (AVM2 interpreting the same texel loops, ~26x
// slower). Two seconds inside one frame is over a third of AIR's 15-second
// script watchdog, and a loader callback that lands just before a shadow-map
// rebuild pushes the frame over it: the demo hit Error #1502 in
// Object3D.updateMatrixWorld with a healthy stack, i.e. the watchdog firing on
// accumulated frame work rather than on any bug.
//
// So the bake is split: step() bakes ONE level (~360ms under adl) and returns.
// The demo calls it from updateFrame, and the ladder grows a level per frame --
// level 0 is the sharp cube, so the environment appears on the first step and
// then refines. Nothing about the result changes; the levels, the divisor and
// the texels are identical to bake().
package asaot.three.extras
{
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.FloatPanorama;
    import asaot.three.textures.HDRImage;
    import asaot.three.textures.PanoramaSampler;

    public class PrefilterJob
    {
        private var _base:FloatPanorama = null;
        private var _levels:Vector.<Number> = null;
        private var _faceSize:int = 0;
        private var _scale:Number = 1;

        // Partially filled: entry i is null until level i has been baked.
        public var cubes:Vector.<CubeTexture> = null;
        private var _next:int = 0;

        public function PrefilterJob(img:HDRImage, faceSize:int, scale:Number = 0)
        {
            if (img == null) throw new Error("PrefilterJob: null HDRImage");
            if (faceSize <= 0) throw new Error("PrefilterJob: faceSize must be > 0");
            _base = FloatPanorama.fromHDRImage(img);
            _levels = EnvironmentPrefilter.LEVEL_ROUGHNESS;
            _faceSize = faceSize;
            _scale = scale > 0 ? scale : EquirectangularToCube.autoScale(img);
            cubes = new Vector.<CubeTexture>(_levels.length, true);
        }

        public function get levelCount():int { return _levels.length; }
        public function get completed():int { return _next; }
        public function get done():Boolean { return _next >= _levels.length; }
        public function get faceSize():int { return _faceSize; }
        public function get hdrScale():Number { return _scale; }

        // Bakes the next level and returns `done`. Idempotent once finished.
        public function step():Boolean
        {
            if (this.done) return true;
            var r:Number = _levels[_next];
            var src:PanoramaSampler = EnvironmentPrefilter.blurFor(_base, r);
            cubes[_next] = EquirectangularToCube.decorate(new CubeTexture(
                EquirectangularToCube.bakeBitmapsSampled(src, _faceSize, _scale)), _scale);
            _next++;
            return this.done;
        }

        // The levels baked so far, as a ladder the renderer can already use. Each
        // level carries its own roughness, so a partial ladder simply means the
        // rough end still resolves to the sharpest cube that exists -- visibly
        // better each frame, never invalid.
        public function partial():PrefilteredEnvironment
        {
            if (_next == 0) return null;
            var n:int = _next;
            var picked:Vector.<CubeTexture> = new Vector.<CubeTexture>(n, true);
            var rough:Vector.<Number> = new Vector.<Number>(n, true);
            var i:int;
            for (i = 0; i < n; i++)
            {
                picked[i] = cubes[i];
                rough[i] = _levels[i];
            }
            return new PrefilteredEnvironment(picked, rough, _scale, _faceSize);
        }

        // The finished ladder; null until every level is baked.
        public function get result():PrefilteredEnvironment
        {
            return this.done ? this.partial() : null;
        }
    }
}