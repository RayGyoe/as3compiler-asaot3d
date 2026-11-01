// asaot.three.loaders.GLTFLoader -- glTF 2.0 (.gltf / .glb) scene loader.
//
// Borrows the STRUCTURE of three.js r187 examples/jsm/loaders/GLTFLoader.js
// (5006 lines): the `GLTFLoader.parse` envelope (string | ArrayBuffer | parsed
// object), the GLB container (GLTFBinaryExtension, GLTFLoader.js:1924), the
// JSON->scene pipeline of GLTFParser (buffers -> bufferViews -> accessors ->
// primitives -> meshes -> nodes -> scene) and the metallic-roughness material
// mapping (`loadMaterial`, GLTFLoader.js:3677). Per-file/line citations are in
// three-borrow-map.md §M8.
//
// SCOPE (three-api-design.md §13): GLB envelope, buffer/bufferView/accessor
// (all six component types, normalized, interleaved de-stride, sparse),
// TRIANGLES/TRIANGLE_STRIP/TRIANGLE_FAN primitives, pbrMetallicRoughness ->
// MeshStandardMaterial (baseColor/metallicRoughness/normal/emissive factor +
// emissiveTexture/occlusionTexture, the latter two added in the M8 follow-up),
// KHR_materials_unlit -> MeshBasicMaterial, textures/images (bufferView,
// data URI, external file; Skia decode via flash.display.Loader), samplers,
// node TRS/matrix, PerspectiveCamera/OrthographicCamera, scenes,
// KHR_texture_transform (L3) and third-party extension plugins (L12).
// NOT in this milestone (registered in TODO): Draco/meshopt/basisu compression,
// skins, animations, morph targets.
//
// DIVERGENCES (three-api-design.md §13):
//   D40  three.js is Promise-based (GLTFParser.getDependency). AS3 has no
//        Promise, so the graph is built SYNCHRONOUSLY once every `buffers`
//        entry is resolved; only the buffer fetches are asynchronous and they
//        are counted down before `_buildScene` runs. Images are asynchronous
//        too, but they do not block: a Texture object is created up-front and
//        its bitmap is attached when the decode lands (the renderer re-uploads
//        on the next `version` bump). onLoad therefore fires as soon as the
//        scene graph exists -- textures may still be decoding. See §13 D40.
//   D41  GLB parsing reads the ByteArray directly with little-endian reads.
//        as-aot's ByteArray.readFloat ignores `endian` and always reads
//        BIG-endian (measured; see as3compiler TODO), so float32 components go
//        through `_readFloatLE`, which byte-swaps through a scratch ByteArray.
//        Every other read (u8/i8/u16/i16/u32) honours `endian`.
//   D42  Accessor data is ALWAYS Vector.<Number> (our float CPU buffer, same
//        as D-array in BufferAttribute). Integer component types are widened on
//        read and `normalized` is applied on the CPU (three.js stores the raw
//        integer TypedArray and divides on the GPU).
//   D43  Interleaved bufferViews are de-interleaved at parse time instead of
//        using three.js's InterleavedBuffer/InterleavedBufferAttribute pair:
//        AGAL's setVertexBufferAt takes a single interleave offset, and our
//        BufferAttribute has no stride, so de-striding into a packed buffer is
//        the only shape the seam can upload.
//   D44  Only the attributes the AGAL renderer consumes are wired
//        (POSITION/NORMAL/TEXCOORD_0/TANGENT); COLOR_0, JOINTS_0, WEIGHTS_0 and
//        every TEXCOORD_n beyond 0 are skipped (same narrowing as D29).
//   D45  Node-level KHR_lights_punctual is honoured (directional/point/spot ->
//        M6 lights). A light node's DirectionalLight/SpotLight `target` is
//        added as a CHILD at (0,0,-1), matching three.js's GLTFLightsExtension
//        so the light points down its local -Z axis.
package asaot.three.loaders
{
    import flash.display.Bitmap;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.net.URLLoader;
    import flash.net.URLLoaderDataFormat;
    import flash.net.URLRequest;
    import flash.utils.ByteArray;
    import flash.utils.Dictionary;
    import flash.utils.Endian;

    import asaot.three.animation.AnimationClip;
    import asaot.three.animation.AnimationUtils;
    import asaot.three.animation.KeyframeTrack;
    import asaot.three.animation.NumberKeyframeTrack;
    import asaot.three.animation.PropertyBinding;
    import asaot.three.animation.QuaternionKeyframeTrack;
    import asaot.three.animation.VectorKeyframeTrack;
    import asaot.three.cameras.OrthographicCamera;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Object3D;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.lights.PointLight;
    import asaot.three.lights.SpotLight;
    import asaot.three.materials.Material;
    import asaot.three.materials.MeshBasicMaterial;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector2;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.objects.Skeleton;
    import asaot.three.objects.SkinnedMesh;
    import asaot.three.textures.Texture;

    public class GLTFLoader extends Loader
    {
        // ---- glTF component types (spec 2.0 §5.1.1) ----
        private static const BYTE:int = 5120;
        private static const UNSIGNED_BYTE:int = 5121;
        private static const SHORT:int = 5122;
        private static const UNSIGNED_SHORT:int = 5123;
        private static const UNSIGNED_INT:int = 5125;
        private static const FLOAT:int = 5126;

        // ---- samplers (spec 2.0 §5.3.3) ----
        private static const WRAP_REPEAT:int = 10497;
        private static const WRAP_CLAMP:int = 33071;
        private static const WRAP_MIRROR:int = 33648;

        private static const FILTER_NEAREST:int = 9728;
        private static const FILTER_LINEAR:int = 9729;
        private static const FILTER_NEAREST_MIPMAP_NEAREST:int = 9984;
        private static const FILTER_LINEAR_MIPMAP_NEAREST:int = 9985;
        private static const FILTER_NEAREST_MIPMAP_LINEAR:int = 9986;
        private static const FILTER_LINEAR_MIPMAP_LINEAR:int = 9987;

        // ---- base64 alphabet for data: URIs ----
        private static const B64:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        // Parsed JSON root (`any` box from JSON.parse) and the directory that
        // relative buffer/image URIs resolve against.
        private var _json:Object;
        private var _baseDir:String;

        // Resolved buffers (D40): GLB BIN chunk, data: URIs decoded inline, and
        // external .bin files fetched asynchronously.
        private var _buffers:Vector.<ByteArray>;
        private var _glbBody:ByteArray;
        private var _bufferPending:int;
        private var _failed:Boolean;

        private var _onLoadCb:Function;
        private var _onErrorCb:Function;

        // Per-parse caches, keyed by the glTF index (D: Dictionary int keys).
        private var _accessorCache:Dictionary;
        private var _materialCache:Dictionary;
        private var _textureCache:Dictionary;
        private var _meshCache:Dictionary;
        private var _nodeCache:Dictionary;
        private var _cameraCache:Dictionary;
        private var _lightCache:Dictionary;
        // M12: skins are bound in a second pass (after the whole node graph is
        // cached) so a joint can never re-enter _loadNode mid-build.
        private var _skinForNodeIndex:Dictionary;
        private var _skinnedNodeIndices:Vector.<int>;
        // glTF node names must be unique for PropertyBinding.findNode; the first
        // node to claim a sanitised name keeps it and later ones get _1, _2 ...
        private var _nodeNamesUsed:Dictionary;

        // M12: parsed AnimationClips (three.js exposes `gltf.animations`).
        public var animations:Vector.<AnimationClip>;

        // Decoders must stay referenced while loadBytes is in flight.
        private var _decoders:Vector.<Object>;

        // Element-scratch for the little-endian float read (D41).
        private var _floatScratch:ByteArray;

        private var _defaultMat:MeshStandardMaterial;

        // L12: third-party extension factories registered by register().
        // three.js keeps `pluginCallbacks` (factories) + `plugins` (instances,
        // keyed by name) -- GLTFLoader.js:301/:3684.
        private var _pluginCallbacks:Vector.<Function>;
        private var _plugins:Dictionary;

        public function GLTFLoader(manager:LoadingManager = null)
        {
            super(manager);
            this._json = null;
            this._baseDir = "";
            this._buffers = new Vector.<ByteArray>();
            this._glbBody = null;
            this._bufferPending = 0;
            this._failed = false;
            this._onLoadCb = null;
            this._onErrorCb = null;
            this._decoders = new Vector.<Object>();
            this._floatScratch = new ByteArray();
            this._floatScratch.endian = Endian.BIG_ENDIAN;
            this._defaultMat = null;
            this._plugins = new Dictionary();
        }

        // ------------------------------------------------------------------
        // L12 extension registration (D165)
        // ------------------------------------------------------------------

        // Registers a third-party glTF extension factory. The callback receives
        // THIS loader as its "parser" (three.js hands over a GLTFParser object;
        // every parse entry point lives on the loader here) and must return an
        // object whose `name` matches the glTF extension it handles.
        //
        // Recognised hooks (all optional, all SYNCHRONOUS -- AS3 has no Promise,
        // D24):
        //   getMaterialType(materialIndex)               -> Material instance | null
        //   extendMaterial(materialIndex, material, def) -> void, mutate in place
        //   createNodeMesh(nodeIndex, nodeDef)           -> Object3D | null
        //   afterRoot(root)                              -> void
        //
        // D165: three.js's hooks are async and speak a `materialParams` dict;
        // ours are synchronous and receive the material/def instances directly.
        // The TRIGGER surface is the same (the extension name appears in a
        // material's or node's `extensions` map), so a ported plugin only
        // changes how it writes, not when it runs.
        public function register(callback:Function):GLTFLoader
        {
            if (callback == null) throw new Error("GLTFLoader.register expects a callback");
            if (this._pluginCallbacks == null) this._pluginCallbacks = new Vector.<Function>();
            this._pluginCallbacks.push(callback);
            return this;
        }

        // The parser surface handed to plugins: the three.js GLTFParser slots
        // that are meaningful in this kit.
        public function get json():Object
        {
            return this._json;
        }

        public function materialAt(index:int):Material
        {
            return this._loadMaterial(index);
        }

        public function meshAt(index:int):Object3D
        {
            return this._loadMesh(index);
        }

        private function _buildPlugins():void
        {
            this._plugins = new Dictionary();
            if (this._pluginCallbacks == null) return;
            var n:int = this._pluginCallbacks.length;
            var i:int;
            for (i = 0; i < n; i++)
            {
                var plugin:Object = this._pluginCallbacks[i](this);
                if (plugin == null || plugin["name"] == null)
                    throw new Error("GLTFLoader: plugin callback must return an object with a name");
                this._plugins[String(plugin["name"])] = plugin;
            }
        }

        // First non-null hook result, in registration order (three.js _invokeOne).
        //
        // Arity is per HOOK, not per function: AS3 (like AIR) throws #1063 when a
        // closure is called with more arguments than it declares, so the call
        // site must match the documented signature exactly. `createNodeMesh`
        // takes (nodeIndex, nodeDef); `getMaterialType` takes (materialIndex).
        private function _invokeOne(hook:String, a1:Object, a2:Object = null):Object
        {
            if (this._plugins == null) return null;
            for (var name:String in this._plugins)
            {
                var plugin:Object = this._plugins[name];
                var fn:Function = plugin[hook] as Function;
                if (fn == null) continue;
                var r:Object = (hook == "createNodeMesh") ? fn(a1, a2) : fn(a1);
                if (r != null) return r;
            }
            return null;
        }

        // `extendMaterial(materialIndex, material, def)` and `afterRoot(root)`.
        private function _invokeAll(hook:String, a1:Object, a2:Object = null, a3:Object = null):void
        {
            if (this._plugins == null) return;
            for (var name:String in this._plugins)
            {
                var plugin:Object = this._plugins[name];
                var fn:Function = plugin[hook] as Function;
                if (fn == null) continue;
                if (hook == "afterRoot") fn(a1);
                else fn(a1, a2, a3);
            }
        }

        // ------------------------------------------------------------------
        // Entry points
        // ------------------------------------------------------------------

        // Read the file (binary, so both .glb and .gltf work), then parse.
        // onLoad receives the root Group (three.js also returns a Group, not a
        // Scene -- GLTFLoader.js:4574).
        public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):void
        {
            if (url == null) url = "";

            // Relative buffer/image URIs resolve against the glTF's own folder,
            // not the process CWD (three.js LoaderUtils.resolveURL does the same
            // with options.path).
            var dir:String = this._dirOf(url);
            var base:String = (this.path != null && this.path.length > 0) ? this.path : "";
            this._baseDir = base + dir;

            var full:String = base + url;
            var self:GLTFLoader = this;
            var fl:FileLoader = new FileLoader(this.manager);
            fl.responseType = "arraybuffer";
            fl.load(full,
                function(data:Object):void { self.parse(data, null, onLoad, onError); },
                onProgress,
                function(e:Object):void { if (onError != null) onError(e); });
        }

        // data: a String (JSON text), a ByteArray (.glb bytes or JSON bytes), or
        // an already-parsed Object (the `else` branch of GLTFLoader.js:parse).
        public function parse(data:*, path:String = null, onLoad:Function = null, onError:Function = null):void
        {
            this._onLoadCb = onLoad;
            this._onErrorCb = onError;
            this._failed = false;
            if (path != null) this._baseDir = path;

            try
            {
                this._readJson(data);
                if (this._json == null) throw new Error("GLTFLoader: no JSON content");
                this._checkAsset();
                this._resetCaches();
                // L12: instantiate registered extension plugins before anything
                // that can invoke them (materials/nodes/images).
                this._buildPlugins();
                this._resolveBuffers();
            }
            catch (err:Error)
            {
                this._fail(err.message);
            }
        }

        // ------------------------------------------------------------------
        // Envelope: identify .glb vs .gltf and decode the JSON text
        // ------------------------------------------------------------------

        private function _readJson(data:*):void
        {
            this._glbBody = null;

            if (data is String)
            {
                this._json = JSON.parse(String(data));
                return;
            }

            if (data is ByteArray)
            {
                var bytes:ByteArray = ByteArray(data);
                if (this._isGLB(bytes))
                {
                    var text:String = this._parseGLB(bytes);
                    this._json = JSON.parse(text);
                    return;
                }

                // Plain JSON bytes: read the whole buffer as UTF-8.
                bytes.position = 0;
                this._json = JSON.parse(bytes.readUTFBytes(bytes.length));
                return;
            }

            // Already-parsed object (GLTFLoader.js:parse `else` branch).
            this._json = data;
        }

        private function _isGLB(bytes:ByteArray):Boolean
        {
            if (bytes.length < 4) return false;
            bytes.position = 0;
            var m0:int = bytes.readUnsignedByte();
            var m1:int = bytes.readUnsignedByte();
            var m2:int = bytes.readUnsignedByte();
            var m3:int = bytes.readUnsignedByte();
            // 'g' 'l' 'T' 'F'
            return m0 == 0x67 && m1 == 0x6C && m2 == 0x54 && m3 == 0x46;
        }

        // GLB container (GLTFLoader.js:GLTFBinaryExtension). Header is
        // magic/version/length, then a chunk stream of (length, type, payload);
        // chunk type 0x4E4F534A is JSON, 0x004E4942 is the BIN body.
        private function _parseGLB(bytes:ByteArray):String
        {
            bytes.endian = Endian.LITTLE_ENDIAN;
            bytes.position = 0;

            var magic:uint = bytes.readUnsignedInt();
            if (magic != 0x46546C67) throw new Error("GLTFLoader: unsupported glTF-Binary header");
            var version:uint = bytes.readUnsignedInt();
            if (version < 2) throw new Error("GLTFLoader: legacy binary file (glTF 1.0)");
            var total:uint = bytes.readUnsignedInt();

            var jsonText:String = null;
            while (bytes.bytesAvailable >= 8)
            {
                var chunkLength:int = int(bytes.readUnsignedInt());
                var chunkType:uint = bytes.readUnsignedInt();

                if (chunkType == 0x4E4F534A)
                {
                    jsonText = bytes.readUTFBytes(chunkLength);
                }
                else if (chunkType == 0x004E4942)
                {
                    var bin:ByteArray = new ByteArray();
                    bin.endian = Endian.LITTLE_ENDIAN;
                    bytes.readBytes(bin, 0, chunkLength);
                    this._glbBody = bin;
                }
                else
                {
                    // Unknown chunk: skipped (spec requires clients to ignore).
                    bytes.position = bytes.position + chunkLength;
                }
            }

            if (jsonText == null) throw new Error("GLTFLoader: GLB contains no JSON chunk");
            return jsonText;
        }

        // glTF 1.0 has no asset.version >= 2; three.js rejects it the same way.
        private function _checkAsset():void
        {
            var asset:Object = this._json["asset"];
            if (asset == null) throw new Error("GLTFLoader: unsupported asset (no asset.version)");
            var version:String = asset["version"] != null ? String(asset["version"]) : "";
            if (version.length == 0 || int(version.charAt(0)) < 2)
            {
                throw new Error("GLTFLoader: unsupported asset version '" + version + "' (need >= 2.0)");
            }
        }

        private function _resetCaches():void
        {
            this._accessorCache = new Dictionary();
            this._materialCache = new Dictionary();
            this._textureCache = new Dictionary();
            this._meshCache = new Dictionary();
            this._nodeCache = new Dictionary();
            this._cameraCache = new Dictionary();
            this._lightCache = new Dictionary();
            this._skinForNodeIndex = new Dictionary();
            this._skinnedNodeIndices = new Vector.<int>();
            this._nodeNamesUsed = new Dictionary();
            this.animations = null;
            this._defaultMat = null;
        }

        // ------------------------------------------------------------------
        // buffers: GLB body / data: URI / external file (D40)
        // ------------------------------------------------------------------

        private function _resolveBuffers():void
        {
            var defs:Object = this._json["buffers"];
            var n:int = defs == null ? 0 : int(defs.length);

            this._buffers = new Vector.<ByteArray>();
            this._bufferPending = 0;

            for (var i:int = 0; i < n; i++)
            {
                this._buffers.push(null);
                var def:Object = defs[i];
                var uri:String = def["uri"] != null ? String(def["uri"]) : null;

                if (uri == null)
                {
                    // Per spec the GLB BIN chunk is buffer 0 and has no uri.
                    if (i == 0) this._buffers[i] = this._glbBody;
                    continue;
                }

                if (uri.indexOf("data:") == 0)
                {
                    this._buffers[i] = this._decodeBase64(this._afterComma(uri));
                    continue;
                }

                this._fetchBuffer(i, uri);
            }

            if (this._bufferPending == 0) this._buildScene();
        }

        // External .bin: indexed by a holder object because AS3 closures capture
        // the loop variable, not a per-iteration copy.
        private function _fetchBuffer(index:int, uri:String):void
        {
            var self:GLTFLoader = this;
            var holder:Object = {};
            holder["index"] = index;

            this._bufferPending++;
            var fl:FileLoader = new FileLoader(this.manager);
            fl.responseType = "arraybuffer";
            fl.load(this._baseDir + uri,
                function(data:Object):void
                {
                    self._buffers[int(holder["index"])] = ByteArray(data);
                    self._bufferPending--;
                    if (self._bufferPending == 0 && !self._failed) self._buildScene();
                },
                null,
                function(e:Object):void { self._fail("GLTFLoader: failed to load buffer '" + uri + "'"); });
        }

        private function _fail(message:String):void
        {
            if (this._failed) return;
            this._failed = true;
            trace(message);
            if (this._onErrorCb != null) this._onErrorCb(new Error(message));
        }

        // ------------------------------------------------------------------
        // Scene assembly
        // ------------------------------------------------------------------

        private function _buildScene():void
        {
            try
            {
                var root:Group = new Group();
                var scenes:Object = this._json["scenes"];

                if (scenes != null && int(scenes.length) > 0)
                {
                    var sceneIndex:int = this._json["scene"] != null ? int(this._json["scene"]) : 0;
                    if (sceneIndex < 0 || sceneIndex >= int(scenes.length)) sceneIndex = 0;
                    var sceneDef:Object = scenes[sceneIndex];
                    if (sceneDef["name"] != null) root.name = String(sceneDef["name"]);

                    var nodes:Object = sceneDef["nodes"];
                    if (nodes != null)
                    {
                        for (var i:int = 0; i < int(nodes.length); i++)
                        {
                            var node:Object3D = this._loadNode(int(nodes[i]));
                            if (node != null) root.add(node);
                        }
                    }
                }
                else
                {
                    // No scenes array: glTF still defines nodes; treat the
                    // scene's node list as empty rather than inventing a root
                    // (three.js GLTFParser.parse does the same and returns an
                    // empty Group).
                    root.name = "gltf";
                }

                // M12: skins bind after the graph exists, and animations parse
                // last so every target node is already cached by index.
                if (this._skinnedNodeIndices.length > 0) this._attachSkins();
                this._loadAnimations();

                // L12: afterRoot lets a plugin attach scene-level content.
                this._invokeAll("afterRoot", root);
                if (this._onLoadCb != null) this._onLoadCb(root);
            }
            catch (err:Error)
            {
                this._fail(err.message);
            }
        }

        private function _nodes():Object
        {
            return this._json["nodes"];
        }

        // One node: mesh/camera/light payload(s), transform, then children
        // (GLTFLoader.js:_loadNodeShallow + loadNode).
        private function _loadNode(index:int):Object3D
        {
            var cached:Object3D = Object3D(this._nodeCache[index]);
            if (cached != null) return cached;

            var nodes:Object = this._nodes();
            if (nodes == null || index < 0 || index >= int(nodes.length)) return null;
            var def:Object = nodes[index];

            var parts:Vector.<Object3D> = new Vector.<Object3D>();

            var nodeIsSkinned:Boolean = (def["skin"] != null);

            // L12: a registered extension may own this node's content entirely
            // (three.js: `ext.createNodeMesh && ext.createNodeMesh(nodeIndex)`).
            var pluginNode:Object3D = this._invokeOne("createNodeMesh", index, def) as Object3D;
            if (pluginNode != null) parts.push(pluginNode);

            if (def["mesh"] != null && pluginNode == null)
            {
                var mesh:Object3D = this._loadMesh(int(def["mesh"]), nodeIsSkinned);
                if (mesh != null) parts.push(mesh);
            }
            if (def["camera"] != null)
            {
                var cam:Object3D = this._loadCamera(int(def["camera"]));
                if (cam != null) parts.push(cam);
            }

            // KHR_lights_punctual attach (GLTFLightsExtension.createNodeAttachment).
            var ext:Object = def["extensions"];
            if (ext != null && ext["KHR_lights_punctual"] != null)
            {
                var lightExt:Object = ext["KHR_lights_punctual"];
                if (lightExt["light"] != null)
                {
                    var light:Object3D = this._loadLight(int(lightExt["light"]));
                    if (light != null) parts.push(light);
                }
            }

            var node:Object3D;
            if (parts.length == 1)
            {
                node = parts[0];
            }
            else if (parts.length == 0)
            {
                node = new Object3D();
            }
            else
            {
                // three.js wraps multiple attachments in a Group (and, when the
                // node has its own transform, the Group carries it).
                var group:Group = new Group();
                for (var p:int = 0; p < parts.length; p++) group.add(parts[p]);
                node = group;
            }

            // M12: PropertyBinding resolves a track's node by name, so names go
            // through the same sanitise+dedupe step three.js's createUniqueName
            // applies (GLTFLoader.js:3838).
            node.name = (def["name"] != null) ? this._createUniqueName(String(def["name"])) : "";

            if (nodeIsSkinned)
            {
                this._skinForNodeIndex[index] = int(def["skin"]);
                this._skinnedNodeIndices.push(index);
            }

            this._applyNodeTransform(node, def);

            // Cache before recursing into children so a malformed cyclic graph
            // terminates instead of overflowing the stack.
            this._nodeCache[index] = node;

            var children:Object = def["children"];
            if (children != null)
            {
                for (var c:int = 0; c < int(children.length); c++)
                {
                    var child:Object3D = this._loadNode(int(children[c]));
                    if (child != null) node.add(child);
                }
            }

            return node;
        }

        // `matrix` wins over the TRS trio (glTF spec: they are exclusive, and
        // three.js applies matrix then skips TRS -- GLTFLoader.js:4494).
        private function _applyNodeTransform(node:Object3D, def:Object):void
        {
            if (def["matrix"] != null)
            {
                var m:Matrix4 = new Matrix4().fromArray(Vector.<Number>(def["matrix"]));
                node.applyMatrix4(m);
                return;
            }
            if (def["translation"] != null) node.position.fromArray(Vector.<Number>(def["translation"]));
            if (def["rotation"] != null) node.quaternion.fromArray(Vector.<Number>(def["rotation"]));
            if (def["scale"] != null) node.scale.fromArray(Vector.<Number>(def["scale"]));
        }

        // ------------------------------------------------------------------
        // Meshes / primitives
        // ------------------------------------------------------------------

        // M12: `asSkinned` comes from the *node* (glTF puts `skin` on the node),
        // so a skinned node gets its own SkinnedMesh instance and bypasses the
        // mesh cache -- two nodes may share a mesh but never a skeleton.
        private function _loadMesh(meshIndex:int, asSkinned:Boolean = false):Object3D
        {
            if (!asSkinned)
            {
                var cached:Object3D = Object3D(this._meshCache[meshIndex]);
                if (cached != null) return cached;
            }

            var meshes:Object = this._json["meshes"];
            if (meshes == null || meshIndex < 0 || meshIndex >= int(meshes.length)) return null;
            var def:Object = meshes[meshIndex];
            var primitives:Object = def["primitives"];
            if (primitives == null) return null;

            var built:Vector.<Object3D> = new Vector.<Object3D>();
            for (var i:int = 0; i < int(primitives.length); i++)
            {
                var prim:Object = primitives[i];
                var geometry:BufferGeometry = this._loadPrimitive(prim);
                if (geometry == null) continue;

                var material:Material;
                if (prim["material"] != null) material = this._loadMaterial(int(prim["material"]));
                else material = this._defaultMaterial();

                var mesh:Mesh = asSkinned
                    ? new SkinnedMesh(geometry, material)
                    : new Mesh(geometry, material);
                mesh.name = def["name"] != null ? String(def["name"]) : ("mesh_" + meshIndex);

                // M12 morph targets: build the influence vector + name dictionary,
                // then seed the mesh's default weights (glTF `mesh.weights`).
                if (geometry.morphAttributes["position"] != null)
                {
                    mesh.updateMorphTargets();
                    var defaultWeights:Object = def["weights"];
                    if (defaultWeights != null && mesh.morphTargetInfluences != null)
                    {
                        var wCount:int = int(defaultWeights.length);
                        if (wCount > mesh.morphTargetInfluences.length) wCount = mesh.morphTargetInfluences.length;
                        for (var wi:int = 0; wi < wCount; wi++)
                        {
                            mesh.morphTargetInfluences[wi] = Number(defaultWeights[wi]);
                        }
                    }
                }

                built.push(mesh);
            }

            var result:Object3D;
            if (built.length == 1)
            {
                result = built[0];
            }
            else
            {
                // Multiple primitives -> one Group (GLTFLoader.js:4050-4090).
                var group:Group = new Group();
                group.name = def["name"] != null ? String(def["name"]) : ("mesh_" + meshIndex);
                for (var j:int = 0; j < built.length; j++) group.add(built[j]);
                result = group;
            }

            if (!asSkinned) this._meshCache[meshIndex] = result;
            return result;
        }

        // Build one BufferGeometry from a primitive (GLTFLoader.js:
        // addPrimitiveAttributes, 4933).
        private function _loadPrimitive(prim:Object):BufferGeometry
        {
            var mode:int = prim["mode"] != null ? int(prim["mode"]) : 4; // 4 = TRIANGLES
            if (mode != 4 && mode != 5 && mode != 6)
            {
                // 0..3 (POINTS/LINES/LINE_LOOP/LINE_STRIP) need draw modes the
                // seam has no program for; skip the primitive loudly instead of
                // drawing garbage (spec: unknown modes are an error, this is a
                // supported-shape gap -- see three-api-design.md §13).
                trace("GLTFLoader: primitive mode " + mode + " unsupported, skipped");
                return null;
            }

            var geometry:BufferGeometry = new BufferGeometry();
            var attributes:Object = prim["attributes"];
            if (attributes == null) return null;

            // D44: only the attributes AGAL consumes. glTF -1..0 coordinate
            // suffix mapping only affects names we do not read (TEXCOORD_1+).
            this._assignAttribute(geometry, attributes, "POSITION", "position");
            this._assignAttribute(geometry, attributes, "NORMAL", "normal");
            this._assignAttribute(geometry, attributes, "TEXCOORD_0", "uv");
            this._assignAttribute(geometry, attributes, "TANGENT", "tangent");
            // M12: JOINTS_0 / WEIGHTS_0 feed the CPU skinning path (D84).
            this._assignAttribute(geometry, attributes, "JOINTS_0", "skinIndex");
            this._assignAttribute(geometry, attributes, "WEIGHTS_0", "skinWeight");

            this._loadMorphTargets(geometry, prim["targets"]);

            if (prim["indices"] != null)
            {
                var index:BufferAttribute = this._loadAccessor(int(prim["indices"]));
                if (index != null) geometry.setIndex(index);
            }

            // Missing normals: three.js computes them only when the material
            // wants lighting; the seam's R9 fallback would otherwise flatten the
            // model to a constant (0,0,1). Compute them here when the primitive
            // has indices/positions, which is what three.js does for glTF
            // (GLTFLoader requests flat shading only for explicit flat materials).
            if (geometry.getAttribute("normal") == null && geometry.getAttribute("position") != null)
            {
                geometry.computeVertexNormals();
            }

            if (mode == 5) this._stripToTriangles(geometry);
            else if (mode == 6) this._fanToTriangles(geometry);

            if (prim["name"] != null) geometry.name = String(prim["name"]);
            return geometry;
        }

        // ------------------------------------------------------------------
        // M12: morph targets / skins / animations
        // ------------------------------------------------------------------

        // glTF primitive `targets`: [ { POSITION: acc, NORMAL: acc, ... }, ... ].
        // The accessors hold DELTAS (glTF spec: "morph targets are displacements"),
        // which is exactly three.js's morphTargetsRelative convention, so the CPU
        // morph path adds them weighted (Mesh.writeMorphedAttributes).
        private function _loadMorphTargets(geometry:BufferGeometry, targets:Object):void
        {
            if (targets == null || int(targets.length) == 0) return;

            var positions:Vector.<BufferAttribute> = new Vector.<BufferAttribute>();
            var normals:Vector.<BufferAttribute> = new Vector.<BufferAttribute>();

            for (var i:int = 0; i < int(targets.length); i++)
            {
                var target:Object = targets[i];
                var posAttr:BufferAttribute = null;
                var nrmAttr:BufferAttribute = null;

                if (target["POSITION"] != null) posAttr = this._loadAccessor(int(target["POSITION"]));
                if (target["NORMAL"] != null) nrmAttr = this._loadAccessor(int(target["NORMAL"]));

                // Keep the arrays index-aligned with the target list: a missing
                // channel gets a zero-filled attribute so target N always means the
                // same weight slot.
                if (posAttr == null) posAttr = this._zeroAttributeLike(geometry, 3);
                positions.push(posAttr);
                if (nrmAttr != null) normals.push(nrmAttr);
                else normals.push(this._zeroAttributeLike(geometry, 3));
            }

            geometry.morphAttributes["position"] = positions;
            geometry.morphAttributes["normal"] = normals;
            geometry.morphTargetsRelative = true;
        }

        private function _zeroAttributeLike(geometry:BufferGeometry, itemSize:int):BufferAttribute
        {
            var position:BufferAttribute = geometry.getAttribute("position");
            var count:int = (position != null) ? position.count : 0;
            return new BufferAttribute(new Vector.<Number>(count * itemSize, true), itemSize);
        }

        // GLTFLoader.js:3838 createUniqueName.
        private function _createUniqueName(originalName:String):String
        {
            var sanitized:String = PropertyBinding.sanitizeNodeName(originalName != null ? originalName : "");
            var name:String = sanitized;
            var i:int = 1;
            while (this._nodeNamesUsed[name] != null)
            {
                name = sanitized + "_" + i;
                i++;
            }
            this._nodeNamesUsed[name] = true;
            return name;
        }

        // GLTFLoader.js:4133 loadSkin -> Skeleton(bones, boneInverses).
        private function _loadSkin(index:int):Skeleton
        {
            var skins:Object = this._json["skins"];
            if (skins == null || index < 0 || index >= int(skins.length)) return null;

            var def:Object = skins[index];
            var joints:Object = def["joints"];
            if (joints == null) return null;

            var inverseBindMatrices:BufferAttribute = null;
            if (def["inverseBindMatrices"] != null)
            {
                inverseBindMatrices = this._loadAccessor(int(def["inverseBindMatrices"]));
            }

            var bones:Vector.<Object3D> = new Vector.<Object3D>();
            var inverses:Vector.<Matrix4> = new Vector.<Matrix4>();

            for (var i:int = 0; i < int(joints.length); i++)
            {
                var jointNode:Object3D = this._loadNode(int(joints[i]));
                if (jointNode == null) continue;

                // M26/D151: glTF has no "this node is a bone" marker -- a node is a
                // joint purely by being listed in skins[].joints. three.js can swap
                // the class at creation time (GLTFLoader picks Bone for joints), but
                // this loader has already built the node graph by the time a skin is
                // parsed, and AS3 cannot change an object's class after construction.
                // The joint set therefore sets Object3D.isBone, which is the ONLY
                // thing Bone adds (src/objects/Bone.js). SkeletonHelper and any
                // isBone test then see the same thing three.js does.
                jointNode.isBone = true;

                bones.push(jointNode);

                var matrix:Matrix4 = new Matrix4();
                if (inverseBindMatrices != null)
                {
                    matrix.fromArray(inverseBindMatrices.array, i * 16);
                }
                inverses.push(matrix);
            }

            return new Skeleton(bones, inverses);
        }

        // Second pass: bind every skinned node now that the graph is complete.
        // three.js binds with the IDENTITY matrix (GLTFLoader.js _loadNodeShallow:
        // `mesh.bind( skeleton, _identityMatrix )`), so bindMatrixInverse starts as
        // identity and SkinnedMesh.updateMatrixWorld keeps it in sync in
        // AttachedBindMode.
        private function _attachSkins():void
        {
            for (var i:int = 0; i < this._skinnedNodeIndices.length; i++)
            {
                var nodeIndex:int = this._skinnedNodeIndices[i];
                var node:Object3D = Object3D(this._nodeCache[nodeIndex]);
                if (node == null) continue;

                var skinned:SkinnedMesh = this._findSkinnedMesh(node);
                if (skinned == null) continue;

                var skeleton:Skeleton = this._loadSkin(int(this._skinForNodeIndex[nodeIndex]));
                if (skeleton == null) continue;

                skinned.bind(skeleton, new Matrix4());
                skinned.normalizeSkinWeights();
            }
        }

        private function _findSkinnedMesh(node:Object3D):SkinnedMesh
        {
            if (node is SkinnedMesh) return SkinnedMesh(node);

            var children:Vector.<Object3D> = node.children;
            for (var i:int = 0; i < children.length; i++)
            {
                var found:SkinnedMesh = this._findSkinnedMesh(children[i]);
                if (found != null) return found;
            }
            return null;
        }

        // GLTFLoader.js:4205 loadAnimation + _createAnimationTracks (4630).
        private function _loadAnimations():void
        {
            var defs:Object = this._json["animations"];
            if (defs == null || int(defs.length) == 0) return;

            var clips:Vector.<AnimationClip> = new Vector.<AnimationClip>();

            for (var a:int = 0; a < int(defs.length); a++)
            {
                var def:Object = defs[a];
                var name:String = (def["name"] != null) ? String(def["name"]) : ("animation_" + a);

                var channels:Object = def["channels"];
                var samplers:Object = def["samplers"];
                if (channels == null || samplers == null) continue;

                var tracks:Vector.<KeyframeTrack> = new Vector.<KeyframeTrack>();

                for (var c:int = 0; c < int(channels.length); c++)
                {
                    var channel:Object = channels[c];
                    var target:Object = channel["target"];
                    if (target == null || target["node"] == null) continue;

                    var sampler:Object = samplers[int(channel["sampler"])];
                    if (sampler == null) continue;

                    var node:Object3D = this._loadNode(int(target["node"]));
                    if (node == null) continue;

                    this._createAnimationTracks(node, sampler, String(target["path"]), tracks);
                }

                clips.push(new AnimationClip(name, -1, tracks));
            }

            this.animations = clips;
        }

        private function _createAnimationTracks(node:Object3D, sampler:Object, path:String,
                                                tracks:Vector.<KeyframeTrack>):void
        {
            var input:BufferAttribute = this._loadAccessor(int(sampler["input"]));
            var output:BufferAttribute = this._loadAccessor(int(sampler["output"]));
            if (input == null || output == null) return;

            var interpolation:String = (sampler["interpolation"] != null) ? String(sampler["interpolation"]) : "LINEAR";
            var interp:int = KeyframeTrack.InterpolateLinear;
            if (interpolation == "STEP") interp = KeyframeTrack.InterpolateDiscrete;
            else if (interpolation == "CUBICSPLINE") interp = KeyframeTrack.InterpolateCubicSpline;

            var times:Vector.<Number> = input.array;
            var values:Vector.<Number> = output.array;

            if (path == "weights")
            {
                // Weights belong to the *mesh* carrying morph targets; a node with
                // several primitives is a Group, so fan the track out over every
                // morphing child (GLTFLoader.js:4678 collectMorphTargets).
                var targets:Vector.<Mesh> = new Vector.<Mesh>();
                this._collectMorphMeshes(node, targets);
                for (var t:int = 0; t < targets.length; t++)
                {
                    var targetName:String = this._nodeUuidName(targets[t]);
                    tracks.push(new NumberKeyframeTrack(targetName + ".morphTargetInfluences",
                        times, values, interp));
                }
                return;
            }

            var nodeName:String = this._nodeUuidName(node);

            if (path == "translation")
            {
                tracks.push(new VectorKeyframeTrack(nodeName + ".position", times, values, interp));
            }
            else if (path == "rotation")
            {
                tracks.push(new QuaternionKeyframeTrack(nodeName + ".quaternion", times, values, interp));
            }
            else if (path == "scale")
            {
                tracks.push(new VectorKeyframeTrack(nodeName + ".scale", times, values, interp));
            }
            else
            {
                // Unknown channel: skip loudly rather than bind to a random property.
                trace("GLTFLoader: animation path '" + path + "' unsupported, skipped");
            }
        }

        private function _nodeUuidName(object:Object3D):String
        {
            return (object.name != null && object.name.length > 0) ? object.name : object.uuid;
        }

        private function _collectMorphMeshes(object:Object3D, out:Vector.<Mesh>):void
        {
            if (object is Mesh)
            {
                var mesh:Mesh = Mesh(object);
                if (mesh.morphTargetInfluences != null) out.push(mesh);
            }

            var children:Vector.<Object3D> = object.children;
            for (var i:int = 0; i < children.length; i++)
            {
                this._collectMorphMeshes(children[i], out);
            }
        }

        private function _assignAttribute(geometry:BufferGeometry, attributes:Object, gltfName:String, threeName:String):void
        {
            if (attributes[gltfName] == null) return;
            var accessor:BufferAttribute = this._loadAccessor(int(attributes[gltfName]));
            if (accessor != null) geometry.setAttribute(threeName, accessor);
        }

        // TRIANGLE_STRIP -> triangle list. three.js routes this through
        // toTrianglesDrawMode; the winding alternates every other triangle.
        private function _stripToTriangles(geometry:BufferGeometry):void
        {
            var src:BufferAttribute = geometry.index;
            var count:int = src != null ? src.count : geometry.getAttribute("position").count;
            var out:Vector.<Number> = new Vector.<Number>();
            for (var i:int = 0; i + 2 < count; i++)
            {
                var a:int = src != null ? int(src.getX(i)) : i;
                var b:int = src != null ? int(src.getX(i + 1)) : (i + 1);
                var c:int = src != null ? int(src.getX(i + 2)) : (i + 2);
                if ((i & 1) == 0)
                {
                    out.push(a); out.push(b); out.push(c);
                }
                else
                {
                    out.push(b); out.push(a); out.push(c);
                }
            }
            geometry.setIndex(new BufferAttribute(out, 1));
        }

        // TRIANGLE_FAN -> triangle list (first vertex is the hub).
        private function _fanToTriangles(geometry:BufferGeometry):void
        {
            var src:BufferAttribute = geometry.index;
            var count:int = src != null ? src.count : geometry.getAttribute("position").count;
            var out:Vector.<Number> = new Vector.<Number>();
            for (var i:int = 1; i + 1 < count; i++)
            {
                var hub:int = src != null ? int(src.getX(0)) : 0;
                var b:int = src != null ? int(src.getX(i)) : i;
                var c:int = src != null ? int(src.getX(i + 1)) : (i + 1);
                out.push(hub); out.push(b); out.push(c);
            }
            geometry.setIndex(new BufferAttribute(out, 1));
        }

        // ------------------------------------------------------------------
        // Accessors (GLTFLoader.js:3185)
        // ------------------------------------------------------------------

        private function _loadAccessor(index:int):BufferAttribute
        {
            var cached:BufferAttribute = BufferAttribute(this._accessorCache[index]);
            if (cached != null) return cached;

            var accessors:Object = this._json["accessors"];
            if (accessors == null || index < 0 || index >= int(accessors.length)) return null;
            var def:Object = accessors[index];

            var itemSize:int = this._typeComponentCount(String(def["type"]));
            var componentType:int = int(def["componentType"]);
            var count:int = int(def["count"]);
            var normalized:Boolean = def["normalized"] == true;
            var elementBytes:int = this._componentSize(componentType);

            var data:Vector.<Number> = new Vector.<Number>(count * itemSize);

            if (def["bufferView"] != null)
            {
                var bvIndex:int = int(def["bufferView"]);
                var bufferViews:Object = this._json["bufferViews"];
                var bv:Object = bufferViews[bvIndex];

                var bufferIndex:int = int(bv["buffer"]);
                var bytes:ByteArray = this._buffers[bufferIndex];
                if (bytes == null) throw new Error("GLTFLoader: buffer " + bufferIndex + " is not resolved");

                var bvOffset:int = bv["byteOffset"] != null ? int(bv["byteOffset"]) : 0;
                var accessorOffset:int = def["byteOffset"] != null ? int(def["byteOffset"]) : 0;
                var base:int = bvOffset + accessorOffset;
                // D43: byteStride is the interleave pitch; absent means packed.
                var stride:int = bv["byteStride"] != null ? int(bv["byteStride"]) : (itemSize * elementBytes);

                this._readInto(bytes, base, stride, itemSize, elementBytes, componentType, count, data);
            }

            // Sparse accessors overwrite individual elements on top of the base
            // buffer (spec 2.0 §5.1.2). three.js supports the same and we keep
            // parity rather than silently zeroing them.
            if (def["sparse"] != null) this._applySparse(def, itemSize, componentType, data);

            if (normalized) this._normalizeVector(data, componentType);

            var attribute:BufferAttribute = new BufferAttribute(data, itemSize, normalized);
            this._accessorCache[index] = attribute;
            return attribute;
        }

        // Read `count` items of `itemSize` components into `out` as doubles.
        private function _readInto(bytes:ByteArray, base:int, stride:int, itemSize:int,
                                   elementBytes:int, componentType:int, count:int,
                                   out:Vector.<Number>):void
        {
            bytes.endian = Endian.LITTLE_ENDIAN;
            for (var i:int = 0; i < count; i++)
            {
                var pos:int = base + i * stride;
                for (var c:int = 0; c < itemSize; c++)
                {
                    bytes.position = pos + c * elementBytes;
                    out[i * itemSize + c] = this._readComponent(bytes, componentType);
                }
            }
        }

        private function _readComponent(bytes:ByteArray, componentType:int):Number
        {
            if (componentType == FLOAT) return this._readFloatLE(bytes);
            if (componentType == UNSIGNED_BYTE) return bytes.readUnsignedByte();
            if (componentType == BYTE) return bytes.readByte();
            if (componentType == UNSIGNED_SHORT) return bytes.readUnsignedShort();
            if (componentType == SHORT) return bytes.readShort();
            if (componentType == UNSIGNED_INT) return bytes.readUnsignedInt();
            throw new Error("GLTFLoader: unsupported componentType " + componentType);
        }

        // D41: ByteArray.readFloat ignores `endian` in as-aot and always reads
        // big-endian, so a float32 from a little-endian glTF buffer is fetched
        // as four bytes and replayed MSB-first through a scratch buffer.
        private function _readFloatLE(bytes:ByteArray):Number
        {
            var b0:int = bytes.readUnsignedByte();
            var b1:int = bytes.readUnsignedByte();
            var b2:int = bytes.readUnsignedByte();
            var b3:int = bytes.readUnsignedByte();
            var s:ByteArray = this._floatScratch;
            s.position = 0;
            s.writeByte(b3);
            s.writeByte(b2);
            s.writeByte(b1);
            s.writeByte(b0);
            s.position = 0;
            return s.readFloat();
        }

        private function _applySparse(def:Object, itemSize:int, componentType:int, out:Vector.<Number>):void
        {
            var sparse:Object = def["sparse"];
            var sparseCount:int = int(sparse["count"]);
            var indicesDef:Object = sparse["indices"];
            var valuesDef:Object = sparse["values"];
            var bufferViews:Object = this._json["bufferViews"];

            var idxBv:Object = bufferViews[int(indicesDef["bufferView"])];
            var idxBytes:ByteArray = this._buffers[int(idxBv["buffer"])];
            var idxOffset:int = int(idxBv["byteOffset"] != null ? idxBv["byteOffset"] : 0) + int(indicesDef["byteOffset"] != null ? indicesDef["byteOffset"] : 0);
            // indices are SCALAR (itemSize 1)
            var idxType:int = int(indicesDef["componentType"]);
            var idxSize:int = this._componentSize(idxType);
            var indices:Vector.<Number> = new Vector.<Number>(sparseCount);
            this._readInto(idxBytes, idxOffset, idxSize, 1, idxSize, idxType, sparseCount, indices);

            var valBv:Object = bufferViews[int(valuesDef["bufferView"])];
            var valBytes:ByteArray = this._buffers[int(valBv["buffer"])];
            var valOffset:int = int(valBv["byteOffset"] != null ? valBv["byteOffset"] : 0) + int(valuesDef["byteOffset"] != null ? valuesDef["byteOffset"] : 0);
            var valSize:int = this._componentSize(componentType);
            var values:Vector.<Number> = new Vector.<Number>(sparseCount * itemSize);
            this._readInto(valBytes, valOffset, valSize * itemSize, itemSize, valSize, componentType, sparseCount, values);

            for (var i:int = 0; i < sparseCount; i++)
            {
                var target:int = int(indices[i]);
                for (var c:int = 0; c < itemSize; c++)
                {
                    out[target * itemSize + c] = values[i * itemSize + c];
                }
            }
        }

        // normalized integer -> float (spec 2.0 §3.11: signed divides by
        // 127/32767 and is clamped at -1, unsigned divides by 255/65535).
        private function _normalizeVector(data:Vector.<Number>, componentType:int):void
        {
            if (componentType == FLOAT) return;
            var scale:Number = 0;
            var signed:Boolean = false;
            if (componentType == UNSIGNED_BYTE) scale = 1 / 255;
            else if (componentType == UNSIGNED_SHORT) scale = 1 / 65535;
            else if (componentType == BYTE) { scale = 1 / 127; signed = true; }
            else if (componentType == SHORT) { scale = 1 / 32767; signed = true; }
            else return; // UNSIGNED_INT is never normalized per spec

            for (var i:int = 0; i < data.length; i++)
            {
                var v:Number = data[i] * scale;
                if (signed && v < -1) v = -1;
                data[i] = v;
            }
        }

        private function _componentSize(componentType:int):int
        {
            if (componentType == BYTE || componentType == UNSIGNED_BYTE) return 1;
            if (componentType == SHORT || componentType == UNSIGNED_SHORT) return 2;
            if (componentType == FLOAT || componentType == UNSIGNED_INT) return 4;
            throw new Error("GLTFLoader: unsupported componentType " + componentType);
        }

        private function _typeComponentCount(type:String):int
        {
            if (type == "SCALAR") return 1;
            if (type == "VEC2") return 2;
            if (type == "VEC3") return 3;
            if (type == "VEC4") return 4;
            if (type == "MAT2") return 4;
            if (type == "MAT3") return 9;
            if (type == "MAT4") return 16;
            throw new Error("GLTFLoader: unsupported accessor type '" + type + "'");
        }

        // ------------------------------------------------------------------
        // Materials (GLTFLoader.js:3677)
        // ------------------------------------------------------------------

        private function _defaultMaterial():Material
        {
            // glTF's implicit material: white base color, metallic 1, roughness 1
            // (createDefaultMaterial, GLTFLoader.js:2370).
            if (this._defaultMat == null)
            {
                this._defaultMat = new MeshStandardMaterial();
                this._defaultMat.color.setRGB(1, 1, 1);
                this._defaultMat.metalness = 1;
                this._defaultMat.roughness = 1;
            }
            return this._defaultMat;
        }

        private function _loadMaterial(index:int):Material
        {
            var cached:Material = Material(this._materialCache[index]);
            if (cached != null) return cached;

            var defs:Object = this._json["materials"];
            if (defs == null || index < 0 || index >= int(defs.length)) return this._defaultMaterial();
            var def:Object = defs[index];

            var unlit:Boolean = this._hasExt(def, "KHR_materials_unlit");
            var material:Material;
            var pbr:Object = def["pbrMetallicRoughness"];

            // L12: a registered extension may supply the material itself
            // (three.js `getMaterialType`). It only picks the CLASS in three.js;
            // we cannot return a class value in AS3, so the hook returns an
            // INSTANCE that the common tail below (name/side/alphaMode) still
            // configures (D165).
            material = this._invokeOne("getMaterialType", index) as Material;

            if (material != null)
            {
                // plugin-owned material: skip the built-in PBR/unlit construction
            }
            else if (unlit)
            {
                var basic:MeshBasicMaterial = new MeshBasicMaterial();
                if (pbr != null && pbr["baseColorFactor"] != null)
                {
                    var bcf:Vector.<Number> = Vector.<Number>(pbr["baseColorFactor"]);
                    basic.color.setRGB(bcf[0], bcf[1], bcf[2]);
                    basic.opacity = bcf.length > 3 ? bcf[3] : 1;
                }
                if (pbr != null && pbr["baseColorTexture"] != null)
                {
                    // M20: MeshBasicMaterial now has a real map slot, so an
                    // unlit glTF material keeps its base-colour texture instead
                    // of collapsing to the flat baseColorFactor (M8 had to drop
                    // it -- three-api-design §25). Same sRGB flag as the PBR
                    // path: baseColorTexture is colour data.
                    basic.map = this._loadTextureIndexed(pbr["baseColorTexture"], true);
                }
                material = basic;
            }
            else
            {
                var std:MeshStandardMaterial = new MeshStandardMaterial();
                std.color.setRGB(1, 1, 1);
                std.opacity = 1;

                if (pbr != null)
                {
                    if (pbr["baseColorFactor"] != null)
                    {
                        var f:Vector.<Number> = Vector.<Number>(pbr["baseColorFactor"]);
                        std.color.setRGB(f[0], f[1], f[2]);
                        std.opacity = f.length > 3 ? f[3] : 1;
                    }
                    if (pbr["baseColorTexture"] != null) std.map = this._loadTextureIndexed(pbr["baseColorTexture"], true);
                    std.metalness = pbr["metallicFactor"] != null ? Number(pbr["metallicFactor"]) : 1;
                    std.roughness = pbr["roughnessFactor"] != null ? Number(pbr["roughnessFactor"]) : 1;
                    if (pbr["metallicRoughnessTexture"] != null)
                    {
                        // One image feeds both channels: G=roughness, B=metalness.
                        var mr:Texture = this._loadTextureIndexed(pbr["metallicRoughnessTexture"]);
                        std.roughnessMap = mr;
                        std.metalnessMap = mr;
                    }
                }

                if (def["normalTexture"] != null)
                {
                    std.normalMap = this._loadTextureIndexed(def["normalTexture"]);
                    var nt:Object = def["normalTexture"];
                    if (nt["scale"] != null)
                    {
                        var s:Number = Number(nt["scale"]);
                        std.normalScale.set(s, s);
                    }
                }

                // Emissive: three.js computes
                // emissive = emissiveFactor * emissiveIntensity * emissiveTexel
                // (emissivemap_fragment.glsl.js:6). The seam's standard program
                // samples the emissive texture at fs5 and multiplies by
                // fc7 = emissive*emissiveIntensity, so the factor goes in the
                // material and the texel is applied in the shader. Note glTF
                // defaults emissiveFactor to [0,0,0]: an emissiveTexture
                // without a factor is black in three.js too, so we stay faithful.
                if (def["emissiveFactor"] != null)
                {
                    var ef:Vector.<Number> = Vector.<Number>(def["emissiveFactor"]);
                    std.emissive.setRGB(ef[0], ef[1], ef[2]);
                }
                if (def["emissiveTexture"] != null)
                {
                    std.emissiveMap = this._loadTextureIndexed(def["emissiveTexture"], true);
                }

                // Occlusion: glTF occlusionTexture.strength is three.js's
                // aoMapIntensity (GLTFLoader.js:3762-3770).
                if (def["occlusionTexture"] != null)
                {
                    std.aoMap = this._loadTextureIndexed(def["occlusionTexture"]);
                    var occl:Object = def["occlusionTexture"];
                    if (occl["strength"] != null)
                    {
                        std.aoMapIntensity = Number(occl["strength"]);
                    }
                }

                material = std;
            }

            if (def["name"] != null) material.name = String(def["name"]);

            if (def["doubleSided"] == true) material.side = Material.DoubleSide;

            // alphaMode: OPAQUE / MASK / BLEND. M10 wires all three:
            //   BLEND -> transparent pass (back-to-front, alpha blend, no depth
            //            write); opacity stays as authored
            //   MASK  -> alphaTest = alphaCutoff (GLTFLoader.js:3762 maps
            //            `alphaCutoff` to material.alphaTest; opacity is 1)
            //   OPAQUE-> neither
            var alphaMode:String = def["alphaMode"] != null ? String(def["alphaMode"]) : "OPAQUE";
            if (alphaMode == "BLEND")
            {
                material.transparent = true;
                material.depthWrite = false;
            }
            else
            {
                material.transparent = false;
                if (alphaMode == "MASK")
                {
                    material.alphaTest = def["alphaCutoff"] != null ? Number(def["alphaCutoff"]) : 0.5;
                }
            }

            // L12: let extensions rewrite/extend the finished material.
            this._invokeAll("extendMaterial", index, material, def);

            this._materialCache[index] = material;
            return material;
        }

        private function _hasExt(def:Object, name:String):Boolean
        {
            var ext:Object = def["extensions"];
            if (ext == null) return false;
            return ext[name] != null;
        }

        // ------------------------------------------------------------------
        // Textures and images (GLTFLoader.js:3326 / 3401)
        // ------------------------------------------------------------------

        // A material's map reference: { index, texCoord } (assignTexture).
        //
        // M17: `isColor` is three.js's `assignTexture(..., colorSpace)`. The glTF
        // spec marks exactly two texture slots as sRGB-encoded color --
        // baseColorTexture and emissiveTexture -- while metallicRoughness, normal
        // and occlusion are linear data even though they are stored as images.
        // Before the renderer honoured Texture.colorSpace, every map entered the
        // lighting math as if linear and the output encode then applied the sRGB
        // curve a second time, so base-color textures rendered too bright. Like
        // three.js, the flag is written on the (index-cached) Texture, so the same
        // image used in both roles keeps whichever role loaded it first.
        private function _loadTextureIndexed(info:Object, isColor:Boolean = false):Texture
        {
            if (info == null || info["index"] == null) return null;
            if (info["texCoord"] != null && int(info["texCoord"]) > 0)
            {
                // Our AGAL programs sample TEXCOORD_0 only (D44); a second UV set
                // would need a second vertex attribute slot.
                trace("GLTFLoader: texCoord " + int(info["texCoord"]) + " unsupported, using uv0");
            }
            var texture:Texture = this._loadTexture(int(info["index"]));
            if (texture != null && isColor) texture.colorSpace = Texture.SRGBColorSpace;
            // L3: per-slot uv transform (KHR_texture_transform) rides on the
            // texture REFERENCE, so it must not mutate the index-cached texture.
            return this._applyTextureTransform(info, texture);
        }

        // KHR_texture_transform (GLTFTextureTransformExtension.extendTexture,
        // GLTFLoader.js:1241-1290): offset / rotation / scale become the
        // Texture's offset/rotation/repeat, i.e. exactly the M18 uv-transform
        // path the renderer already folds into `matrix`. A clone is made per
        // reference because two slots may transform the same image differently.
        private function _applyTextureTransform(info:Object, texture:Texture):Texture
        {
            if (texture == null || info == null) return texture;
            var ext:Object = info["extensions"];
            if (ext == null || ext["KHR_texture_transform"] == null) return texture;
            var tr:Object = ext["KHR_texture_transform"];

            var out:Texture = texture.clone();
            if (tr["offset"] != null)
            {
                var o:Object = tr["offset"];
                out.offset.set(Number(o[0]), Number(o[1]));
            }
            if (tr["rotation"] != null) out.rotation = Number(tr["rotation"]);
            if (tr["scale"] != null)
            {
                var sc:Object = tr["scale"];
                out.repeat.set(Number(sc[0]), Number(sc[1]));
            }
            if (tr["texCoord"] != null && int(tr["texCoord"]) > 0)
            {
                // Same limit as D44: only TEXCOORD_0 is sampled, so a transform
                // that names a second uv set cannot be honoured. Say so.
                trace("GLTFLoader: KHR_texture_transform.texCoord " + int(tr["texCoord"])
                      + " unsupported, transform applied to uv0");
            }
            out.updateMatrix();
            out.needsUpdate = true;
            return out;
        }

        private function _loadTexture(index:int):Texture
        {
            var cached:Texture = Texture(this._textureCache[index]);
            if (cached != null) return cached;

            var texDefs:Object = this._json["textures"];
            if (texDefs == null || index < 0 || index >= int(texDefs.length)) return null;
            var def:Object = texDefs[index];

            // Textures usually reference images[source]; extensions such as
            // KHR_texture_basisu carry their own source and are unsupported.
            if (def["source"] == null) return null;
            var sourceIndex:int = int(def["source"]);

            var texture:Texture = new Texture();
            // glTF images are stored top-left origin and Stage3D samples texture
            // data top-down without flipping, so flipY stays false (three.js
            // sets exactly this for glTF; its WebGL upload would otherwise flip).
            texture.flipY = false;

            if (def["name"] != null) texture.name = String(def["name"]);
            else
            {
                var images:Object = this._json["images"];
                if (images != null && sourceIndex >= 0 && sourceIndex < int(images.length))
                {
                    var imageDef:Object = images[sourceIndex];
                    if (imageDef["name"] != null) texture.name = String(imageDef["name"]);
                }
            }

            this._applySampler(texture, def["sampler"]);

            this._textureCache[index] = texture;
            this._loadImage(sourceIndex, texture);
            return texture;
        }

        private function _applySampler(texture:Texture, samplerIndex:*):void
        {
            var samplers:Object = this._json["samplers"];
            var sampler:Object = null;
            if (samplers != null && samplerIndex != null && int(samplerIndex) < int(samplers.length))
            {
                sampler = samplers[int(samplerIndex)];
            }

            // Defaults per glTF spec: REPEAT / REPEAT, LINEAR mag, auto min
            // filter (GLTFLoader maps that to LinearMipmapLinearFilter).
            texture.wrapS = this._mapWrap(sampler, "wrapS");
            texture.wrapT = this._mapWrap(sampler, "wrapT");
            texture.magFilter = this._mapFilter(sampler, "magFilter", Texture.LinearFilter);
            texture.minFilter = this._mapFilter(sampler, "minFilter", Texture.LinearMipmapLinearFilter);
            texture.generateMipmaps = texture.minFilter != Texture.NearestFilter && texture.minFilter != Texture.LinearFilter;
        }

        private function _mapWrap(sampler:Object, key:String):int
        {
            if (sampler == null || sampler[key] == null) return Texture.RepeatWrapping;
            var v:int = int(sampler[key]);
            if (v == WRAP_CLAMP) return Texture.ClampToEdgeWrapping;
            if (v == WRAP_MIRROR) return Texture.MirroredRepeatWrapping;
            if (v == WRAP_REPEAT) return Texture.RepeatWrapping;
            return Texture.RepeatWrapping;
        }

        private function _mapFilter(sampler:Object, key:String, fallback:int):int
        {
            if (sampler == null || sampler[key] == null) return fallback;
            var v:int = int(sampler[key]);
            if (v == FILTER_NEAREST) return Texture.NearestFilter;
            if (v == FILTER_LINEAR) return Texture.LinearFilter;
            if (v == FILTER_NEAREST_MIPMAP_NEAREST) return Texture.NearestMipmapNearestFilter;
            if (v == FILTER_LINEAR_MIPMAP_NEAREST) return Texture.LinearMipmapNearestFilter;
            if (v == FILTER_NEAREST_MIPMAP_LINEAR) return Texture.NearestMipmapLinearFilter;
            if (v == FILTER_LINEAR_MIPMAP_LINEAR) return Texture.LinearMipmapLinearFilter;
            return fallback;
        }

        // Resolve images[i] into encoded bytes and hand them to the decoder.
        // The Texture object already exists, so a late decode still lands in the
        // material (the renderer uploads on the next version bump).
        private function _loadImage(sourceIndex:int, texture:Texture):void
        {
            var images:Object = this._json["images"];
            if (images == null || sourceIndex < 0 || sourceIndex >= int(images.length))
            {
                trace("GLTFLoader: image " + sourceIndex + " missing");
                return;
            }
            var def:Object = images[sourceIndex];

            if (def["bufferView"] != null)
            {
                var bufferViews:Object = this._json["bufferViews"];
                var bv:Object = bufferViews[int(def["bufferView"])];
                var bytes:ByteArray = this._buffers[int(bv["buffer"])];
                if (bytes == null) return;
                var offset:int = bv["byteOffset"] != null ? int(bv["byteOffset"]) : 0;
                var length:int = bv["byteLength"] != null ? int(bv["byteLength"]) : 0;
                this._decodeImage(this._slice(bytes, offset, length), texture);
                return;
            }

            if (def["uri"] == null)
            {
                trace("GLTFLoader: image " + sourceIndex + " has neither uri nor bufferView");
                return;
            }

            var uri:String = String(def["uri"]);
            if (uri.indexOf("data:") == 0)
            {
                this._decodeImage(this._decodeBase64(this._afterComma(uri)), texture);
                return;
            }

            var self:GLTFLoader = this;
            var holder:Object = {};
            holder["texture"] = texture;
            var fl:FileLoader = new FileLoader(this.manager);
            fl.responseType = "arraybuffer";
            fl.load(this._baseDir + uri,
                function(data:Object):void
                {
                    self._decodeImage(ByteArray(data), Texture(holder["texture"]));
                },
                null,
                function(e:Object):void
                {
                    trace("GLTFLoader: failed to load image '" + uri + "'");
                });
        }

        // Decode PNG/JPEG bytes through flash.display.Loader (the same path
        // ImageLoader/TextureLoader use). Fully qualified because this package
        // owns a class named Loader.
        private function _decodeImage(bytes:ByteArray, texture:Texture):void
        {
            if (bytes == null) return;

            var ldr:flash.display.Loader = new flash.display.Loader();

            // The closure captures `ldr` and `texture` (D13-lift): the typed
            // local is the only handle on the decoded content, and AS3 has no
            // way to cast a dynamic holder back to the qualified Loader type.
            ldr.contentLoaderInfo.addEventListener(Event.COMPLETE,
                function(e:Event):void
                {
                    var bmp:Bitmap = ldr.content as Bitmap;
                    if (bmp == null || bmp.bitmapData == null) return;
                    texture.image = bmp.bitmapData;
                    texture.needsUpdate = true;
                });
            ldr.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR,
                function(e:IOErrorEvent):void { trace("GLTFLoader: image decode failed"); });

            this._decoders.push(ldr);
            ldr.loadBytes(bytes);
        }

        // ------------------------------------------------------------------
        // Cameras (GLTFLoader.js:4095)
        // ------------------------------------------------------------------

        private function _loadCamera(index:int):Object3D
        {
            var cached:Object3D = Object3D(this._cameraCache[index]);
            if (cached != null) return cached;

            var defs:Object = this._json["cameras"];
            if (defs == null || index < 0 || index >= int(defs.length)) return null;
            var def:Object = defs[index];
            var type:String = def["type"] != null ? String(def["type"]) : "";

            var camera:Object3D = null;
            if (type == "perspective")
            {
                var p:Object = def["perspective"];
                if (p != null)
                {
                    // glTF yfov is radians; PerspectiveCamera takes degrees.
                    var fovDeg:Number = Number(p["yfov"]) * 180 / Math.PI;
                    var aspect:Number = p["aspectRatio"] != null ? Number(p["aspectRatio"]) : 1;
                    var near:Number = p["znear"] != null ? Number(p["znear"]) : 1;
                    var far:Number = p["zfar"] != null ? Number(p["zfar"]) : 2000000;
                    camera = new PerspectiveCamera(fovDeg, aspect, near, far);
                }
            }
            else if (type == "orthographic")
            {
                var o:Object = def["orthographic"];
                if (o != null)
                {
                    var xmag:Number = Number(o["xmag"]);
                    var ymag:Number = Number(o["ymag"]);
                    camera = new OrthographicCamera(-xmag, xmag, ymag, -ymag, Number(o["znear"]), Number(o["zfar"]));
                }
            }

            if (camera == null)
            {
                trace("GLTFLoader: camera " + index + " type '" + type + "' unsupported");
                return null;
            }

            if (def["name"] != null) camera.name = String(def["name"]);
            camera.isCamera = true;

            this._cameraCache[index] = camera;
            return camera;
        }

        // ------------------------------------------------------------------
        // KHR_lights_punctual (GLTFLightsExtension._loadLight, GLTFLoader.js:708)
        // ------------------------------------------------------------------

        private function _loadLight(index:int):Object3D
        {
            var cached:Object3D = Object3D(this._lightCache[index]);
            if (cached != null) return cached;

            var ext:Object = this._json["extensions"];
            if (ext == null || ext["KHR_lights_punctual"] == null) return null;
            var lightsObj:Object = ext["KHR_lights_punctual"]["lights"];
            if (lightsObj == null || index < 0 || index >= int(lightsObj.length)) return null;
            var def:Object = lightsObj[index];

            var type:String = def["type"] != null ? String(def["type"]) : "";
            var range:Number = def["range"] != null ? Number(def["range"]) : 0;

            var light:Object3D;
            if (type == "directional")
            {
                var dir:DirectionalLight = new DirectionalLight(0xffffff, 1);
                dir.target.position.set(0, 0, -1);
                dir.add(dir.target);
                light = dir;
            }
            else if (type == "point")
            {
                var point:PointLight = new PointLight(0xffffff, 1);
                point.distance = range;
                light = point;
            }
            else if (type == "spot")
            {
                var spot:SpotLight = new SpotLight(0xffffff, 1);
                spot.distance = range;

                var spotDef:Object = def["spot"];
                var inner:Number = 0;
                var outer:Number = Math.PI / 4;
                if (spotDef != null)
                {
                    if (spotDef["innerConeAngle"] != null) inner = Number(spotDef["innerConeAngle"]);
                    if (spotDef["outerConeAngle"] != null) outer = Number(spotDef["outerConeAngle"]);
                }
                spot.angle = outer;
                spot.penumbra = outer > 0 ? 1 - inner / outer : 0;
                spot.target.position.set(0, 0, -1);
                spot.add(spot.target);
                light = spot;
            }
            else
            {
                trace("GLTFLoader: unexpected light type '" + type + "'");
                return null;
            }

            // Color is linear in glTF; Color.setRGB stores working-space values
            // as-is (the same asymmetry the rest of the kit relies on).
            if (def["color"] != null)
            {
                var col:Vector.<Number> = Vector.<Number>(def["color"]);
                if (light is DirectionalLight) DirectionalLight(light).color.setRGB(col[0], col[1], col[2]);
                else if (light is PointLight) PointLight(light).color.setRGB(col[0], col[1], col[2]);
                else if (light is SpotLight) SpotLight(light).color.setRGB(col[0], col[1], col[2]);
            }

            // glTF lights default to the origin; node-level TRS then overrides.
            light.position.set(0, 0, 0);
            if (def["intensity"] != null) this._setLightIntensity(light, Number(def["intensity"]));
            light.name = def["name"] != null ? String(def["name"]) : ("light_" + index);

            this._lightCache[index] = light;
            return light;
        }

        private function _setLightIntensity(light:Object3D, value:Number):void
        {
            if (light is DirectionalLight) DirectionalLight(light).intensity = value;
            else if (light is PointLight) PointLight(light).intensity = value;
            else if (light is SpotLight) SpotLight(light).intensity = value;
        }

        // ------------------------------------------------------------------
        // Byte helpers
        // ------------------------------------------------------------------

        // Directory portion of a URL ("models/a/b.gltf" -> "models/a/").
        private function _dirOf(url:String):String
        {
            var slash:int = url.lastIndexOf("/");
            if (slash < 0) return "";
            return url.substring(0, slash + 1);
        }

        private function _afterComma(uri:String):String
        {
            var comma:int = uri.indexOf(",");
            if (comma < 0) return "";
            return uri.substr(comma + 1);
        }

        // Copy a byte range out of a buffer (three.js ArrayBuffer.slice).
        private function _slice(source:ByteArray, offset:int, length:int):ByteArray
        {
            var out:ByteArray = new ByteArray();
            out.endian = Endian.LITTLE_ENDIAN;
            source.position = offset;
            source.readBytes(out, 0, length);
            return out;
        }

        // Minimal standard base64 decoder for data: URIs (the AIR SDK's
        // Base64Decoder lives in mx.utils, which this subset does not ship).
        private function _decodeBase64(text:String):ByteArray
        {
            var out:ByteArray = new ByteArray();
            var buf:int = 0;
            var bits:int = 0;
            var n:int = text.length;
            for (var i:int = 0; i < n; i++)
            {
                var ch:String = text.charAt(i);
                if (ch == "=") break;
                var v:int = B64.indexOf(ch);
                if (v < 0) continue; // CR/LF/space padding
                buf = (buf << 6) | v;
                bits += 6;
                if (bits >= 8)
                {
                    bits -= 8;
                    out.writeByte((buf >> bits) & 255);
                }
            }
            return out;
        }
    }
}