// asaot.three.loaders.ObjectLoader -- JSON scene-graph deserializer.
//
// Borrows the SHAPE of three.js src/loaders/ObjectLoader.js (r187): the JSON
// Object/Scene format 4 envelope `{ metadata, geometries, materials, object }`,
// where geometries/materials are UUID-keyed arrays and `object` is a recursive
// `{ type, uuid, name, matrix/position/rotation/scale, children, ... }` tree.
// Geometry/material references inside the tree are UUID strings resolved against
// the two arrays (three.js ObjectLoader.js:parseObject getGeometry/getMaterial).
//
// M3 SUPPORTED SUBSET (three-api-design.md §12): BufferGeometry (position/normal/
// uv attributes + index), MeshStandardMaterial + MeshBasicMaterial, and the
// object kinds Scene/Group/Mesh/PerspectiveCamera/AmbientLight/DirectionalLight.
// SkinnedMesh/InstancedMesh/LOD/Points/Line/Sprite, animations, shapes,
// skeletons, images and texture deserialization are NOT in this milestone.
//
// DIVERGENCES (three-api-design.md §12):
//   D26  three.js `load` uses FileLoader (XHR); as-aot reads a local file through
//        URLLoader/URLRequest (the Stage3D-era equivalent), then JSON.parse ->
//        parse. No Promise/loadAsync (D24).
//   D27  `parse` takes an `Object` (AS3's dynamic root class). JSON.parse returns
//        an `any` box, so `parse(JSON.parse(text))` unboxes the top-level object;
//        inside, every member/index read goes through as_dyn_get/as_any_get.
//   D28  Attribute arrays in three.js JSON are `{ itemSize, type, array }` with a
//        TypedArray; the `array` here is `Vector.<Number>(json.array)` -- the
//        JSON number array coerced to our CPU-side float buffer (D-array). The
//        `type` string ("Float32Array") is ignored (our buffer is always float).
//   D29  three.js walks `for (key in attributes)` to rebuild any attribute; M3
//        hard-codes the three the renderer consumes (position/normal/uv), since
//        AGALRenderer only reads those three. A missing attribute is simply left
//        absent (getAttribute returns null, same convention as D-miss).
package asaot.three.loaders
{
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.net.URLLoader;
    import flash.net.URLRequest;
    import flash.utils.Dictionary;

    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Object3D;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.Material;
    import asaot.three.materials.MeshBasicMaterial;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class ObjectLoader extends Loader
    {
        // uuid -> BufferGeometry / Material, populated per parse call.
        private var _geometries:Dictionary;
        private var _materials:Dictionary;

        public function ObjectLoader()
        {
            super();
            this._geometries = new Dictionary();
            this._materials = new Dictionary();
        }

        // Load a local JSON scene file through URLLoader, then JSON.parse -> parse.
        // onLoad receives the parsed root Object3D; onError receives the event.
        public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):void
        {
            var self:ObjectLoader = this;
            var loader:URLLoader = new URLLoader();
            loader.addEventListener(Event.COMPLETE, function(e:Event):void
            {
                var json:Object = JSON.parse(String(loader.data));
                var object:Object3D = self.parse(json);
                if (onLoad != null) onLoad(object);
            });
            loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void
            {
                if (onError != null) onError(e);
            });
            loader.load(new URLRequest(url));
        }

        // Deserialize the JSON Object/Scene format 4 envelope into a scene graph.
        // Returns the root Object3D (typically the Scene).
        public function parse(json:Object):Object3D
        {
            this._geometries = new Dictionary();
            this._materials = new Dictionary();

            this._parseGeometries(json["geometries"]);
            this._parseMaterials(json["materials"]);
            return this._parseObject(json["object"]);
        }

        // ------------------------------------------------------------------
        // Geometries: UUID -> BufferGeometry.
        // ------------------------------------------------------------------

        // Public entry for a bare BufferGeometry JSON (three.js
        // BufferGeometryLoader.parse, BufferGeometryLoader.js:90) -- the shape
        // three.js examples/models/json/*.json files use. No type check:
        // BufferGeometryLoader trusts its caller, and the io_three format
        // keeps the type in metadata.type, not at the top level.
        public function parseGeometry(json:Object):BufferGeometry
        {
            if (json == null) return null;
            return this._parseOneGeometry(json, String(json["uuid"]));
        }

        private function _parseGeometries(geoms:Object):void
        {
            if (geoms == null) return;
            var n:int = geoms.length;
            for (var i:int = 0; i < n; i++)
            {
                var data:Object = geoms[i];
                if (data["type"] != "BufferGeometry") continue;

                var geometry:BufferGeometry = this._parseOneGeometry(data, String(data["uuid"]));
                this._geometries[geometry.uuid] = geometry;
            }
        }

        private function _parseOneGeometry(data:Object, wantUuid:String):BufferGeometry
        {
            var geometry:BufferGeometry = new BufferGeometry();

            var attributes:Object = data["data"]["attributes"];
            if (attributes != null)
            {
                this._setAttribute(geometry, attributes, "position");
                this._setAttribute(geometry, attributes, "normal");
                this._setAttribute(geometry, attributes, "uv");
            }

            var indexData:Object = data["data"]["index"];
            if (indexData != null)
            {
                geometry.setIndex(new BufferAttribute(Vector.<Number>(indexData["array"]), 1));
            }

            if (data["name"] != null) geometry.name = String(data["name"]);
            // Keep the constructor-generated uuid when the JSON entry has none
            // (bare BufferGeometry files like three.js examples/models/json/*).
            // r187 BufferGeometryLoader.parse never overwrites uuid from JSON
            // (BufferGeometryLoader.js:118); ObjectLoader.js:389 writes it only
            // because Scene.toJSON envelopes always carry one.
            if (wantUuid != null && wantUuid != "null" && wantUuid.length > 0) geometry.uuid = wantUuid;
            return geometry;
        }

        // Rebuild one attribute (position/normal/uv) from the JSON array. The
        // `type` string is ignored -- our CPU buffer is always float (D28).
        private function _setAttribute(geometry:BufferGeometry, attributes:Object, name:String):void
        {
            var attr:Object = attributes[name];
            if (attr == null) return;
            var itemSize:int = int(attr["itemSize"]);
            var array:Vector.<Number> = Vector.<Number>(attr["array"]);
            geometry.setAttribute(name, new BufferAttribute(array, itemSize));
        }

        // ------------------------------------------------------------------
        // Materials: UUID -> Material.
        // ------------------------------------------------------------------

        private function _parseMaterials(mats:Object):void
        {
            if (mats == null) return;
            var n:int = mats.length;
            for (var i:int = 0; i < n; i++)
            {
                var data:Object = mats[i];
                var type:String = String(data["type"]);
                var material:Material = this._createMaterial(type);

                material.name = data["name"] != null ? String(data["name"]) : "";
                if (data["uuid"] != null) material.uuid = String(data["uuid"]);
                if (data["color"] != null && material is MeshBasicMaterial)
                {
                    MeshBasicMaterial(material).color.setHex(int(data["color"]));
                }
                else if (data["color"] != null && material is MeshStandardMaterial)
                {
                    MeshStandardMaterial(material).color.setHex(int(data["color"]));
                }
                if (material is MeshBasicMaterial)
                {
                    var basic:MeshBasicMaterial = MeshBasicMaterial(material);
                    if (data["wireframe"] != null) basic.wireframe = Boolean(data["wireframe"]);
                }
                else if (material is MeshStandardMaterial)
                {
                    var std:MeshStandardMaterial = MeshStandardMaterial(material);
                    if (data["roughness"] != null) std.roughness = Number(data["roughness"]);
                    if (data["metalness"] != null) std.metalness = Number(data["metalness"]);
                    if (data["emissive"] != null) std.emissive.setHex(int(data["emissive"]));
                    if (data["emissiveIntensity"] != null) std.emissiveIntensity = Number(data["emissiveIntensity"]);
                    if (data["wireframe"] != null) std.wireframe = Boolean(data["wireframe"]);
                    if (data["flatShading"] != null) std.flatShading = Boolean(data["flatShading"]);
                }

                this._materials[material.uuid] = material;
            }
        }

        // Material type dispatch (three.js MaterialLoader.createMaterialFromType,
        // narrowed to the two kinds M1/M2 landed). Unknown -> MeshBasicMaterial
        // fallback (same warn-and-fallback spirit as three.js's `new Material()`).
        private function _createMaterial(type:String):Material
        {
            if (type == "MeshStandardMaterial") return new MeshStandardMaterial();
            if (type == "MeshBasicMaterial") return new MeshBasicMaterial();
            return new MeshBasicMaterial();
        }

        // ------------------------------------------------------------------
        // Object tree: recursive `{ type, uuid, name, children, ... }`.
        // ------------------------------------------------------------------

        private function _parseObject(data:Object):Object3D
        {
            var type:String = String(data["type"]);
            var object:Object3D = this._createObject(data, type);

            object.uuid = String(data["uuid"]);
            if (data["name"] != null) object.name = String(data["name"]);

            this._applyTransform(object, data);

            var children:Object = data["children"];
            if (children != null)
            {
                var n:int = children.length;
                for (var i:int = 0; i < n; i++)
                {
                    object.add(this._parseObject(children[i]));
                }
            }

            return object;
        }

        // Construct the right Object3D subclass for the JSON `type` and apply the
        // type-specific payload (three.js ObjectLoader.js:parseObject switch).
        private function _createObject(data:Object, type:String):Object3D
        {
            if (type == "Scene") return new Scene();

            if (type == "Group") return new Group();

            if (type == "Mesh")
            {
                var geometry:BufferGeometry = BufferGeometry(this._geometries[String(data["geometry"])]);
                var material:Material = Material(this._materials[String(data["material"])]);
                return new Mesh(geometry, material);
            }

            if (type == "PerspectiveCamera")
            {
                return new PerspectiveCamera(
                    Number(data["fov"]), Number(data["aspect"]),
                    Number(data["near"]), Number(data["far"]));
            }

            if (type == "AmbientLight")
            {
                return new AmbientLight(int(data["color"]), Number(data["intensity"]));
            }

            if (type == "DirectionalLight")
            {
                return new DirectionalLight(int(data["color"]), Number(data["intensity"]));
            }

            // Unknown kind: a plain node (three.js falls back to `new Object3D`).
            return new Object3D();
        }

        // Apply matrix OR position/rotation/scale (three.js ObjectLoader.js:1470+
        // prefers `matrix`, else falls back to the decomposed trio).
        private function _applyTransform(object:Object3D, data:Object):void
        {
            var matrix:Object = data["matrix"];
            if (matrix != null)
            {
                object.matrix.fromArray(Vector.<Number>(matrix));
                if (data["matrixAutoUpdate"] != null)
                {
                    object.matrixAutoUpdate = Boolean(data["matrixAutoUpdate"]);
                }
                if (object.matrixAutoUpdate)
                {
                    object.matrix.decompose(object.position, object.quaternion, object.scale);
                }
                return;
            }

            if (data["position"] != null) object.position.fromArray(Vector.<Number>(data["position"]));
            if (data["rotation"] != null) object.rotation.fromArray(Vector.<Number>(data["rotation"]));
            if (data["quaternion"] != null) object.quaternion.fromArray(Vector.<Number>(data["quaternion"]));
            if (data["scale"] != null) object.scale.fromArray(Vector.<Number>(data["scale"]));
        }
    }
}
