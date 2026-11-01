// asaot.three.loaders.Loader -- abstract base class for asset loaders.
//
// Borrows the SHAPE of three.js src/loaders/Loader.js (r187): a `load(url,
// onLoad, onProgress, onError)` callback-style async entry point (NOT a Promise),
// a `parse(data)` hook, and the path/resourcePath/crossOrigin/withCredentials
// knobs with chainable setters. three.js defers the actual IO to a FileLoader
// (XHR); as-aot's counterpart is the Stage3D-era URLLoader/URLRequest pair, so
// concrete loaders read a local file through those (see ObjectLoader).
//
// DIVERGENCES (three-api-design.md §12):
//   D23  AS3 has no `abstract` class: `load`/`parse` are concrete no-ops that a
//        subclass overrides, documented as "must override". A base instance is a
//        programming error, not a compile error.
//   D24  three.js has loadAsync (a Promise wrapper); AS3/as-aot has no Promise,
//        so only the callback `load` is provided.
//   D25  requestHeader/priority/cache are XHR/fetch concerns with no Stage3D-era
//        AS3 equivalent, so they are NOT borrowed (same rule as N3 -- borrow the
//        callback shape, not the transport). D160 later NARROWED this to
//        priority/cache: URLRequest.requestHeaders is real state, so
//        setRequestHeader() and abort() are borrowed after all.
//   D161 manager (L6) is borrowed: `manager` is the LoadingManager a loader
//        reports items to, and it defaults to the global DefaultLoadingManager
//        exactly like three.js Loader.js:23. A manager is what makes "all of this
//        batch finished" observable -- the per-loader callbacks cannot express it.
package asaot.three.loaders
{
    public class Loader
    {
        // The instance every loader reports to when the caller passes none
        // (three.js Loader.js:23 `DefaultLoadingManager`).
        public static var DefaultLoadingManager:LoadingManager = new LoadingManager();

        // The base path from which the asset is loaded.
        public var path:String;

        // The base path from which dependent resources (e.g. textures) are loaded.
        public var resourcePath:String;

        // CORS string. Kept for API-shape parity with three.js; as-aot's local
        // URLLoader ignores it (no browser same-origin policy on a native app).
        public var crossOrigin:String;

        // Kept for API-shape parity; no equivalent in the native IO path.
        public var withCredentials:Boolean;

        // Aggregate progress / failure collector (L6). Never null: falls back to
        // DefaultLoadingManager, as in three.js.
        public var manager:LoadingManager;

        public function Loader(manager:LoadingManager = null)
        {
            this.path = '';
            this.resourcePath = '';
            this.crossOrigin = 'anonymous';
            this.withCredentials = false;
            this.manager = manager != null ? manager : Loader.DefaultLoadingManager;
        }

        // three.js Loader.js:229 setManager.
        public function setManager(manager:LoadingManager):Loader
        {
            this.manager = manager != null ? manager : Loader.DefaultLoadingManager;
            return this;
        }

        // No `load` declaration here on purpose (D26). three.js keeps every
        // loader's `load` on the Loader base and lets each subclass narrow the
        // signature; AS3 cannot: TextureLoader returns a Texture while the
        // others return void, and no base return type is a supertype of both
        // (`void` is not a subtype of `*` either, so a `*` base does not help --
        // mxmlc reports "incompatible override" for each). Dropping the base
        // declaration makes every loader's `load` independent, which is exactly
        // the shape three.js relies on at run time. as-aot accepted the old form
        // silently; AIR is the baseline.

        public function setCrossOrigin(value:String):Loader
        {
            this.crossOrigin = value;
            return this;
        }

        public function setWithCredentials(value:Boolean):Loader
        {
            this.withCredentials = value;
            return this;
        }

        public function setPath(value:String):Loader
        {
            this.path = value;
            return this;
        }

        public function setResourcePath(value:String):Loader
        {
            this.resourcePath = value;
            return this;
        }
    }
}
