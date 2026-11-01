// asaot.three.loaders.CubeTextureLoader -- six-image environment map loader.
//
// Borrows the SHAPE of three.js src/loaders/CubeTextureLoader.js (r187):
// load(urls[6], onLoad, onProgress, onError) returns the CubeTexture
// synchronously and fills its six faces as the images decode, then calls
// onLoad(cubeTexture) once (CubeTextureLoader.js:26-62).
//
// DIVERGENCE D47: this class does NOT extend Loader. three.js's load() takes an
// ARRAY of six URLs, while asaot.three.loaders.Loader declares
// load(url:String, ...) and AS3 override signatures are invariant -- a
// Vector.<String> parameter is not a legal override and would silently change
// the base contract. The class therefore carries its own `path` + setPath(),
// the two Loader knobs a cube loader actually uses.
//
// Faces decode independently and out of order, so each completion writes its
// OWN face slot (index carried in a per-iteration holder object, the same
// capture workaround GLTFLoader._fetchBuffer uses -- AS3 closures capture the
// loop variable, not a per-iteration copy) and a pending counter fires onLoad
// only after the sixth arrives.
//
// D158: the pending counter and both callbacks live in a per-load `state`
// object, not in instance fields. With fields, a second load() on the same
// instance reset the counter and swapped the callback under the first load's
// in-flight faces (three.js builds a fresh `loaded`/closure per call).
package asaot.three.loaders
{
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.Texture;
    import flash.display.Bitmap;
    import flash.display.BitmapData;

    public class CubeTextureLoader
    {
        public var path:String;

        // L6: aggregate progress collector, same default as Loader's (this class
        // does not extend Loader -- D47 -- so it carries the field itself).
        public var manager:LoadingManager;

        public function CubeTextureLoader(manager:LoadingManager = null)
        {
            this.path = '';
            this.manager = manager != null ? manager : Loader.DefaultLoadingManager;
        }

        public function setManager(manager:LoadingManager):CubeTextureLoader
        {
            this.manager = manager != null ? manager : Loader.DefaultLoadingManager;
            return this;
        }

        public function setPath(value:String):CubeTextureLoader
        {
            this.path = value;
            return this;
        }

        // urls must hold six entries (+X, -X, +Y, -Y, +Z, -Z). The CubeTexture
        // is returned immediately with six empty face slots; onLoad fires when
        // every face has decoded.
        public function load(urls:Vector.<String>, onLoad:Function = null, onProgress:Function = null, onError:Function = null):CubeTexture
        {
            var cube:CubeTexture = new CubeTexture();
            // M17: three.js r187 CubeTextureLoader.load sets
            // `texture.colorSpace = SRGBColorSpace` (CubeTextureLoader.js:62), and
            // an environment map is photographic sRGB data. Without the flag the
            // renderer fed the env texels straight into the linear lighting math
            // and then sRGB-encoded the result, i.e. gamma applied twice.
            cube.colorSpace = Texture.SRGBColorSpace;
            var faces:Vector.<BitmapData> = new Vector.<BitmapData>();
            var k:int;
            for (k = 0; k < 6; k++) faces.push(null);
            cube.images = faces;

            var n:int = urls != null ? urls.length : 0;
            if (n != 6)
            {
                if (onError != null) onError('CubeTextureLoader.load expects 6 face URLs, got ' + n);
                return cube;
            }

            var state:Object = {};
            state["pending"] = 6;
            state["onLoad"] = onLoad;
            state["onError"] = onError;

            var i:int;
            for (i = 0; i < 6; i++) this._loadFace(cube, i, urls[i], state);
            return cube;
        }

        // One ImageLoader per face. Deliberately a METHOD, not an inline closure
        // in the loop above: AS3 `var` is function-scoped, so a holder object
        // created inside `load`'s loop would be shared by all six closures and
        // every face would land in the last slot. A separate invocation gives
        // each closure its own scope (the same reason GLTFLoader._fetchBuffer
        // exists).
        private function _loadFace(cube:CubeTexture, index:int, url:String, state:Object):void
        {
            var self:CubeTextureLoader = this;
            var holder:Object = {};
            holder["side"] = index;

            var loader:ImageLoader = new ImageLoader(this.manager);
            loader.setPath(this.path);
            loader.load(url,
                function(bmp:Bitmap):void
                {
                    var data:BitmapData = bmp != null ? bmp.bitmapData : null;
                    cube.images[int(holder["side"])] = data;
                    self._faceDone(cube, state);
                },
                null,
                function(e:Object):void
                {
                    var err:Function = state["onError"] as Function;
                    if (err != null) err(e);
                });
        }

        private function _faceDone(cube:CubeTexture, state:Object):void
        {
            state["pending"] = int(state["pending"]) - 1;
            if (int(state["pending"]) > 0) return;
            // One version bump after the last face: the renderer uploads all six
            // in a single pass (a partially filled cube would render as garbage).
            cube.needsUpdate = true;
            var cb:Function = state["onLoad"] as Function;
            if (cb != null) cb(cube);
        }
    }
}