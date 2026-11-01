// asaot.three.loaders.ImageLoader -- decodes an image file into a Bitmap.
//
// Borrows the SHAPE of three.js src/loaders/ImageLoader.js (r187): load(url,
// onLoad, onProgress, onError) delivering an "image element" to onLoad, and
// RETURNING that element synchronously so the caller can hold it while the
// bytes are still in flight (ImageLoader.js:55 `return image`).
// three.js creates an HTMLImageElement; the AIR equivalent is a
// flash.display.Loader whose content is the decoded Bitmap (AIR decodes into
// a Bitmap exactly like an <img> decodes into a raster image).
//
// The IO chain is URLLoader(BINARY) -> Loader.loadBytes -> LoaderInfo.COMPLETE;
// the decoded Bitmap is handed to onLoad. onProgress is unsupported (three.js
// ImageLoader documents the same -- the decode has no progress stream) and is
// accepted but never called.
//
// DIVERGENCES (three-api-design.md §12 / §31):
//   D158 per-load state: the decode handle and the callbacks live in this
//        load() call's locals, not in instance fields. With fields, a second
//        load() on the same instance made the FIRST image arrive at the SECOND
//        call's onLoad and starved the first -- three.js is immune because it
//        builds fresh closures per call.
//   D159 load() returns the handle: three.js returns the Image; we return the
//        flash.display.Loader that will hold the decoded Bitmap in `.content`.
//        A `null` return would force callers into out-parameters, and the base
//        Loader deliberately declares no `load` (D26), so there is no signature
//        to break.
package asaot.three.loaders
{
    import flash.display.Bitmap;
    // NOTE: flash.display.Loader is NOT imported here. An import would shadow
    // this package's own `Loader` base class in as-aot's name resolution (it
    // prefers imports over same-package classes, diverging from mxmlc/adl,
    // which resolve same-package first -- tracked in as3compiler TODO.md), so
    // the flash Loader is fully qualified at its use sites below.
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.net.URLLoader;
    import flash.net.URLLoaderDataFormat;
    import flash.net.URLRequest;
    import flash.utils.ByteArray;

    public class ImageLoader extends Loader
    {
        public function ImageLoader(manager:LoadingManager = null)
        {
            super(manager);
        }

        // Returns the decode handle immediately (D159); onLoad receives the
        // decoded Bitmap once the bytes have been read and decoded.
        public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):flash.display.Loader
        {
            if (url == null) url = '';
            if (this.path != null && this.path.length > 0) url = this.path + url;
            // L6: path prefix first, then the manager's URL modifier
            // (three.js ImageLoader.js:47-49).
            url = this.manager.resolveURL(url);

            var ldr:flash.display.Loader = new flash.display.Loader();
            var self:ImageLoader = this;
            ldr.contentLoaderInfo.addEventListener(Event.COMPLETE, function(e:Event):void
            {
                // itemEnd belongs to the DECODE, not the byte read: three.js ends
                // the item in the image's `load` listener (ImageLoader.js:59-65).
                self.manager.itemEnd(url);
                if (onLoad != null) onLoad(ldr.content as Bitmap);
            });
            ldr.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void
            {
                self.manager.itemError(url);
                self.manager.itemEnd(url);
                if (onError != null) onError(e);
            });

            var ul:URLLoader = new URLLoader();
            ul.dataFormat = URLLoaderDataFormat.BINARY;
            var req:URLLoader = ul;
            ul.addEventListener(Event.COMPLETE, function(e:Event):void
            {
                var bytes:ByteArray = req.data as ByteArray;
                if (bytes == null)
                {
                    self.manager.itemError(url);
                    self.manager.itemEnd(url);
                    if (onError != null) onError(new IOErrorEvent(IOErrorEvent.IO_ERROR));
                    return;
                }
                ldr.loadBytes(bytes);
            });
            ul.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void
            {
                self.manager.itemError(url);
                self.manager.itemEnd(url);
                if (onError != null) onError(e);
            });
            ul.load(new URLRequest(url));
            this.manager.itemStart(url);
            return ldr;
        }
    }
}