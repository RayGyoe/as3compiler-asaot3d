// asaot.three.loaders.TextureLoader -- loads a texture from an image file.
//
// Borrows the SHAPE of three.js src/loaders/TextureLoader.js (r187): load()
// returns the Texture synchronously and fills texture.image asynchronously,
// then calls onLoad(texture) (TextureLoader.js:46-56). The delegation target
// is ImageLoader (which delivers a decoded Bitmap instead of three.js's
// HTMLImageElement); texture.image is the Bitmap's BitmapData -- the same
// field the renderer uploads (Texture.image is BitmapData in this kit).
// DIVERGENCES (three-api-design.md §12 / §31):
//   D158 per-load state: the texture being filled and the user callbacks are
//        this load() call's locals. Three.js relies on exactly this (a fresh
//        closure per load() in TextureLoader.js:46); keeping them in fields made
//        two overlapping loads write BOTH images into the second texture and
//        fire the second callback twice.
package asaot.three.loaders
{
    import asaot.three.textures.Texture;
    import flash.display.Bitmap;

    public class TextureLoader extends Loader
    {
        public function TextureLoader()
        {
            super();
        }

        public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):Texture
        {
            var texture:Texture = new Texture();
            // L6: the child loader inherits this loader's manager so the decode
            // counts once against the same batch (three.js TextureLoader.js:50).
            var loader:ImageLoader = new ImageLoader(this.manager);
            loader.setPath(this.path);

            loader.load(url,
                function(bmp:Bitmap):void
                {
                    texture.image = bmp != null ? bmp.bitmapData : null;
                    texture.needsUpdate = true;
                    if (onLoad != null) onLoad(texture);
                },
                onProgress,
                function(e:Object):void
                {
                    if (onError != null) onError(e);
                });
            return texture;
        }
    }
}
