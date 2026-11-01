// asaot.three.loaders.LoadingManager -- aggregate progress / failure collector.
//
// Borrows the SHAPE of three.js src/loaders/LoadingManager.js (r187): the
// itemStart/itemEnd/itemError triple every loader calls, the onStart/onLoad/
// onProgress/onError callback slots, and setURLModifier() as a pre-request URL
// hook. three.js binds those as per-instance closures created in the
// constructor; AS3 has no closures-at-construction idiom worth copying, so they
// are plain methods plus public callback fields -- the observable contract
// (who is called, with what, and in which order) is identical.
//
// DIVERGENCES (three-api-design.md §31 / §31.8):
//   D162 resolveURL does NOT run String.normalize('NFC'): as-aot implements no
//        Unicode normalization data, so calling it would either throw or be a
//        lie. A non-NFC URL therefore reaches the file system as authored
//        (three.js would percent-encode the NFC form).
//   D163 no `manager.abortController`: three.js merges a manager-level
//        AbortController into every fetch signal so one call can cancel a whole
//        loading batch. AS3's cancellation is URLLoader.close() per request, and
//        the loaders already expose their own abort() (D160); a manager-wide
//        cancel would need every loader to keep a resolvable list of its own
//        in-flight requests, which is a separate (registered) decision.
//   D164 addHandler/getHandler/removeHandler are implemented but NOT consumed by
//        the loaders in this kit: they exist so ported code that registers a
//        handler still runs, and so the table shape is available when a
//        pluggable loader is actually wired in.
//
// The accounting is three.js's exactly: itemStart increments `itemsTotal` and
// fires onStart only on the FIRST start of a batch (`isLoading` flips false->
// true); itemEnd increments `itemsLoaded`, fires onProgress on EVERY end, and
// fires onLoad when loaded == total; itemError fires onError but does NOT
// balance the counters -- a failed item calls itemError AND itemEnd (that is
// what FileLoader does at three.js:299-318), so the batch still completes.
package asaot.three.loaders
{
    public class LoadingManager
    {
        // Fired by the first itemStart of a batch (url, itemsLoaded, itemsTotal).
        public var onStart:Function;
        // Fired when the last itemEnd balances the batch (no arguments).
        public var onLoad:Function;
        // Fired on every itemEnd (url, itemsLoaded, itemsTotal).
        public var onProgress:Function;
        // Fired on itemError (url).
        public var onError:Function;

        private var _isLoading:Boolean;
        private var _itemsLoaded:int;
        private var _itemsTotal:int;
        private var _urlModifier:Function;
        // Flat pairs: [regex0, loader0, regex1, loader1, ...] -- three.js's
        // `handlers.push( regex, loader )` shape (D164).
        private var _handlers:Array;

        public function LoadingManager(onLoad:Function = null, onProgress:Function = null, onError:Function = null)
        {
            this.onStart = null;
            this.onLoad = onLoad;
            this.onProgress = onProgress;
            this.onError = onError;
            this._isLoading = false;
            this._itemsLoaded = 0;
            this._itemsTotal = 0;
            this._urlModifier = null;
            this._handlers = [];
        }

        public function get itemsLoaded():int
        {
            return this._itemsLoaded;
        }

        public function get itemsTotal():int
        {
            return this._itemsTotal;
        }

        // True between the first itemStart and the balancing itemEnd.
        public function get isLoading():Boolean
        {
            return this._isLoading;
        }

        // Called by a loader when it starts one item.
        public function itemStart(url:String):void
        {
            this._itemsTotal++;
            if (this._isLoading == false)
            {
                if (this.onStart != null) this.onStart(url, this._itemsLoaded, this._itemsTotal);
            }
            this._isLoading = true;
        }

        // Called by a loader when one item settles -- success OR failure
        // (three.js FileLoader's error path calls itemError then itemEnd).
        public function itemEnd(url:String):void
        {
            this._itemsLoaded++;
            if (this.onProgress != null) this.onProgress(url, this._itemsLoaded, this._itemsTotal);
            if (this._itemsLoaded == this._itemsTotal)
            {
                this._isLoading = false;
                if (this.onLoad != null) this.onLoad();
            }
        }

        // Called by a loader when one item failed. Does not touch the counters:
        // the loader still owes an itemEnd (see the header).
        public function itemError(url:String):void
        {
            if (this.onError != null) this.onError(url);
        }

        // Applies the URL modifier (if any). Loaders call this AFTER their own
        // path prefix, which is what three.js does (FileLoader.js:82-84,
        // ImageLoader.js:47-49).
        public function resolveURL(url:String):String
        {
            if (this._urlModifier != null) return String(this._urlModifier(url));
            return url;
        }

        public function setURLModifier(transform:Function):LoadingManager
        {
            this._urlModifier = transform;
            return this;
        }

        public function addHandler(regex:String, loader:Object):LoadingManager
        {
            this._handlers.push(regex);
            this._handlers.push(loader);
            return this;
        }

        public function removeHandler(regex:String):LoadingManager
        {
            var i:int;
            var n:int = this._handlers.length;
            for (i = 0; i + 1 < n; i += 2)
            {
                if (this._handlers[i] === regex)
                {
                    this._handlers.splice(i, 2);
                    return this;
                }
            }
            return this;
        }

        // Returns the loader registered for a URL, or null. Handlers are matched
        // in registration order, like three.js (getHandler).
        public function getHandler(url:String):Object
        {
            var i:int;
            var n:int = this._handlers.length;
            for (i = 0; i + 1 < n; i += 2)
            {
                if (String(url).search(String(this._handlers[i])) >= 0) return this._handlers[i + 1];
            }
            return null;
        }
    }
}