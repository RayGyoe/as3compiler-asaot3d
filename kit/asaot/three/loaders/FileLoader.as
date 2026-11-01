// asaot.three.loaders.FileLoader -- low-level file loader over URLLoader.
//
// Borrows the SHAPE of three.js src/loaders/FileLoader.js (r187): the
// load(url, onLoad, onProgress, onError) callback contract, the path prefix,
// the responseType knob, request headers, and abort(). three.js rides the Fetch
// API; as-aot's native counterpart is flash.net.URLLoader (same split as
// D23/D24 -- borrow the callback shape, not the transport).
//
// DIVERGENCES (three-api-design.md §12 / §31):
//   D32  responseType maps onto URLLoaderDataFormat + a post-read conversion:
//        '' / 'text' -> TEXT (String), 'arraybuffer' -> BINARY (ByteArray),
//        'json' -> the text parsed with JSON.parse. 'blob' / 'document' have no
//        AS3 counterpart (no Blob/Document type) and now report through onError
//        instead of silently behaving as text (three-api-design.md §31 L3 --
//        silent degradation is what §1.5 of AGENTS.md forbids).
//   D33  no duplicate-URL fan-out: three.js keeps a `loading[url]` table and
//        delivers one fetch to every queued callback; AS3 has no equivalent
//        table and the loaders that use FileLoader construct one instance per
//        load anyway. Every load() call therefore owns its own URLLoader AND its
//        own listener closures (D158) -- a second load() on the same instance
//        does NOT hijack the first one's callbacks.
//   D34  mimeType is kept as a data field (setMimeType): the native reader needs
//        no MIME hint, and three.js only uses it to pick a charset decoder.
//   D158 per-load callbacks, never instance fields: keeping onLoad/onError in
//        fields made a second load() deliver the FIRST file's bytes to the
//        SECOND call's onLoad and starve the first (neither three.js's fan-out
//        nor AIR's per-URLLoader delivery). three.js is safe here because each
//        load() creates fresh closures; AS3 closures over a method's locals are
//        per-invocation too, so the same shape works.
//   D160 requestHeader IS borrowed: the old D25 note lumped it with
//        priority/cache, but AIR expresses it natively -- URLRequest.requestHeaders
//        holds URLRequestHeader values and the runtime really sends them. abort()
//        is borrowed too (URLLoader.close()); like three.js's AbortController it
//        cancels every request this instance started.
package asaot.three.loaders
{
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.events.ProgressEvent;
    import flash.net.URLLoader;
    import flash.net.URLLoaderDataFormat;
    import flash.net.URLRequest;
    import flash.net.URLRequestHeader;

    public class FileLoader extends Loader
    {
        // Expected MIME type (three.js FileLoader.js:50). Unused by the native
        // reader: it only steers three.js's charset decoder (D34).
        public var mimeType:String;

        // '' or 'text' (default) -> String payload; 'arraybuffer' -> ByteArray;
        // 'json' -> parsed object (three.js FileLoader.js:229-277, mapped per D32).
        public var responseType:String;

        // Header name -> value, replaced wholesale by setRequestHeader (three.js
        // Loader.js:192). Applied per request as URLRequestHeader entries (D160).
        private var _requestHeader:Object;

        // Requests started by this instance that have not settled yet, so abort()
        // can cancel them all (three.js keeps one AbortController per instance).
        private var _inflight:Array;

        public function FileLoader(manager:LoadingManager = null)
        {
            super(manager);
            this.mimeType = '';
            this.responseType = '';
            this._requestHeader = {};
            this._inflight = [];
        }

        public function setResponseType(value:String):FileLoader
        {
            this.responseType = value;
            return this;
        }

        public function setMimeType(value:String):FileLoader
        {
            this.mimeType = value;
            return this;
        }

        // Replaces the whole header map (three.js semantics: no merging).
        public function setRequestHeader(value:Object):FileLoader
        {
            this._requestHeader = value != null ? value : {};
            return this;
        }

        // Cancels every request this instance started. The callbacks of a
        // cancelled request never fire -- same observable shape as an aborted
        // fetch in three.js. `close()` throws #2029 when the job already finished
        // (AIR text), which for us is just "nothing to abort" (three.js no-op).
        public function abort():void
        {
            var n:int = this._inflight.length;
            var i:int;
            for (i = 0; i < n; i++)
            {
                var ul:URLLoader = this._inflight[i] as URLLoader;
                if (ul == null) continue;
                try
                {
                    ul.close();
                }
                catch (err:Error)
                {
                    // #2029: nothing in flight anymore.
                }
            }
            this._inflight = [];
        }

        // Every call owns one URLLoader plus the closures that read it (D158).
        // Nothing is stored on the instance, so concurrent / repeated load()
        // calls cannot cross-deliver data or callbacks.
        public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):void
        {
            if (url == null) url = '';
            if (this.path != null && this.path.length > 0) url = this.path + url;
            // L6: the manager's URL modifier runs AFTER the path prefix, exactly
            // like three.js FileLoader.js:82-84.
            url = this.manager.resolveURL(url);

            var responseType:String = this.responseType;   // per-call snapshot (D158 spirit)

            // 'blob' / 'document' have no AS3 representation: report instead of
            // silently handing back text (D32 / §31 L3).
            if (responseType != '' && responseType != 'text'
                && responseType != 'arraybuffer' && responseType != 'json')
            {
                if (onError != null) onError(new Error("FileLoader: unsupported responseType '"
                                                      + responseType + "' (no AS3 counterpart)"));
                return;
            }

            var ul:URLLoader = new URLLoader();
            if (responseType == 'arraybuffer') ul.dataFormat = URLLoaderDataFormat.BINARY;
            var req:URLLoader = ul;
            var self:FileLoader = this;
            this._inflight.push(ul);

            ul.addEventListener(Event.COMPLETE, function(e:Event):void
            {
                self._settle(req);
                if (onLoad == null)
                {
                    self.manager.itemEnd(url);
                    return;
                }
                if (responseType == 'json')
                {
                    try
                    {
                        onLoad(JSON.parse(String(req.data)));
                    }
                    catch (err:Error)
                    {
                        if (onError != null) onError(err);
                    }
                    self.manager.itemEnd(url);
                    return;
                }
                onLoad(req.data);
                self.manager.itemEnd(url);
            });
            ul.addEventListener(ProgressEvent.PROGRESS, function(e:ProgressEvent):void
            {
                if (onProgress != null) onProgress(e);
            });
            ul.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void
            {
                self._settle(req);
                if (onError != null) onError(e);
                // three.js calls itemError THEN itemEnd on the error path
                // (FileLoader.js:299-318), so a failed item still balances the
                // batch and onLoad can fire.
                self.manager.itemError(url);
                self.manager.itemEnd(url);
            });

            var request:URLRequest = new URLRequest(url);
            var names:Array = this._headerNames();
            var i:int;
            for (i = 0; i < names.length; i++)
            {
                var name:String = names[i];
                request.requestHeaders.push(new URLRequestHeader(name, String(this._requestHeader[name])));
            }

            ul.load(request);
            // L6: counted AFTER the request is started, matching three.js
            // (FileLoader.js:322). The fetch-based fast path for cached URLs does
            // not exist here (D161), so there is no synchronous completion to
            // race with.
            this.manager.itemStart(url);
        }

        // The header names of the current map, in insertion order (three.js hands
        // a Headers() the raw object; the order is the object's own).
        private function _headerNames():Array
        {
            var out:Array = [];
            var map:Object = this._requestHeader;
            if (map == null) return out;
            for (var key:String in map) out.push(key);
            return out;
        }

        private function _settle(req:URLLoader):void
        {
            var n:int = this._inflight.length;
            var i:int;
            for (i = 0; i < n; i++)
            {
                if (this._inflight[i] === req)
                {
                    this._inflight.splice(i, 1);
                    return;
                }
            }
        }
    }
}