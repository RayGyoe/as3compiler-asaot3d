// asaot.three.animation.PropertyBinding -- the link between a track name and a
// real property on a scene-graph object.
//
// Borrows src/animation/PropertyBinding.js (r187):
//   * parseTrackName()  -- the `nodeName.objectName[index].propertyName[index]`
//     grammar, including the objectName allowlist ('material', 'materials',
//     'bones', 'map') that disambiguates `foo.bar.baz`;
//   * findNode()        -- name / uuid / skeleton-bone / recursive-subtree search;
//   * bind()            -- node -> object -> property resolution and the
//     BindingType / Versioning selection;
//   * getValue / setValue for the four binding types.
//
// DIVERGENCES:
//   D73  No `Composite` binding: it only exists to fan a track out over an
//        AnimationObjectGroup, which this kit does not borrow.
//   D74  `bindingType` / `versioning` are plain ints switched on inside
//        getValue/setValue instead of three.js's per-instance function-pointer
//        tables (same reason as D70: no per-instance method re-pointing).
//   D75  A failed bind is reported through `bindingType = INVALID` (the track is
//        skipped and the mixer raises once) instead of three.js's silent
//        "no-op binding" function shadowing -- a typo in a track name must not
//        look like a working animation.
package asaot.three.animation
{
    import asaot.three.core.Object3D;
    import asaot.three.materials.Material;
    import asaot.three.math.Color;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;
    import asaot.three.math.Vector4;
    import asaot.three.objects.Mesh;
    import asaot.three.objects.SkinnedMesh;

    public class PropertyBinding
    {
        // BindingType (PropertyBinding.js:BindingType)
        public static const Direct:int = 0;
        public static const EntireArray:int = 1;
        public static const ArrayElement:int = 2;
        public static const HasFromToArray:int = 3;
        public static const INVALID:int = -1;

        // Versioning (PropertyBinding.js:Versioning)
        public static const VersionNone:int = 0;
        public static const VersionNeedsUpdate:int = 1;
        public static const VersionMatrixWorldNeedsUpdate:int = 2;

        public var rootNode:Object3D;
        public var path:String;
        public var parsedPath:Object;

        public var node:Object3D = null;
        public var targetObject:Object = null;
        public var resolvedProperty:* = null;
        public var propertyName:String = "";
        public var propertyIndex:* = null;
        public var bindingType:int = INVALID;
        public var versioning:int = VersionNone;

        public function PropertyBinding(rootNode:Object3D, path:String, parsedPath:Object = null)
        {
            this.rootNode = rootNode;
            this.path = path;
            this.parsedPath = (parsedPath != null) ? parsedPath : PropertyBinding.parseTrackName(path);
        }

        // ------------------------------------------------------------------
        // Static helpers
        // ------------------------------------------------------------------

        public static function isSupportedObjectName(name:String):Boolean
        {
            return name == "material" || name == "materials" || name == "bones" || name == "map";
        }

        // PropertyBinding.js:sanitizeNodeName -- spaces become '_' and the
        // reserved track-syntax characters [] . : / are dropped.
        public static function sanitizeNodeName(name:String):String
        {
            var out:String = "";
            var n:int = name.length;
            for (var i:int = 0; i < n; i++)
            {
                var c:String = name.charAt(i);
                if (c == " " || c == "\t" || c == "\n") out += "_";
                else if (c == "[" || c == "]" || c == "." || c == ":" || c == "/") continue;
                else out += c;
            }
            return out;
        }

        // PropertyBinding.js:parseTrackName, hand-parsed (the project has no
        // backtracking regex engine in the AOT runtime -- see three-api-design
        // §17.8). Grammar accepted:
        //   [directory/]nodeName[.objectName[objectIndex]].propertyName[propertyIndex]
        //   [directory/].objectName[objectIndex].propertyName[propertyIndex]
        public static function parseTrackName(trackName:String):Object
        {
            var s:String = trackName;
            // The directory prefix (parentName/nodeName) is unused by three.js too;
            // it is only matched so the rest parses.
            var slash:int = s.lastIndexOf("/");
            var colon:int = s.lastIndexOf(":");
            var dir:int = (slash > colon) ? slash : colon;
            if (dir >= 0) s = s.substring(dir + 1);

            var lastDot:int = s.lastIndexOf(".");
            if (lastDot < 0)
            {
                throw new Error("THREE.PropertyBinding: Cannot parse trackName: " + trackName);
            }

            var head:String = s.substring(0, lastDot);
            var propertyName:String = s.substring(lastDot + 1);
            var propertyIndex:* = null;

            var pBracket:int = propertyName.indexOf("[");
            if (pBracket >= 0)
            {
                var pEnd:int = propertyName.lastIndexOf("]");
                propertyIndex = propertyName.substring(pBracket + 1, (pEnd >= 0) ? pEnd : propertyName.length);
                propertyName = propertyName.substring(0, pBracket);
            }

            var objectName:String = null;
            var objectIndex:* = null;
            var nodeName:String = head;

            var objDot:int = head.lastIndexOf(".");
            if (objDot >= 0)
            {
                var tail:String = head.substring(objDot + 1);
                var tailName:String = tail;
                var tailIndex:* = null;

                var tBracket:int = tail.indexOf("[");
                if (tBracket >= 0)
                {
                    var tEnd:int = tail.lastIndexOf("]");
                    tailIndex = tail.substring(tBracket + 1, (tEnd >= 0) ? tEnd : tail.length);
                    tailName = tail.substring(0, tBracket);
                }

                if (isSupportedObjectName(tailName))
                {
                    nodeName = head.substring(0, objDot);
                    objectName = tailName;
                    objectIndex = tailIndex;
                }
            }

            if (propertyName.length == 0)
            {
                throw new Error("THREE.PropertyBinding: can not parse propertyName from trackName: " + trackName);
            }

            return {
                nodeName: nodeName,
                objectName: objectName,
                objectIndex: objectIndex,
                propertyName: propertyName,
                propertyIndex: propertyIndex
            };
        }

        // PropertyBinding.js:findNode.
        public static function findNode(root:Object3D, nodeName:String):Object3D
        {
            if (root == null) return null;
            if (nodeName == null || nodeName == "" || nodeName == "." || nodeName == root.name || nodeName == root.uuid)
            {
                return root;
            }

            // search into skeleton bones (track names emitted by glTF for joints)
            if (root is SkinnedMesh)
            {
                var skeleton:* = SkinnedMesh(root).skeleton;
                if (skeleton != null)
                {
                    var bone:Object3D = skeleton.getBoneByName(nodeName);
                    if (bone != null) return bone;
                }
            }

            return findNodeInChildren(root, nodeName);
        }

        private static function findNodeInChildren(parent:Object3D, nodeName:String):Object3D
        {
            var children:Vector.<Object3D> = parent.children;
            var n:int = children.length;
            for (var i:int = 0; i < n; i++)
            {
                var child:Object3D = children[i];
                if (child.name == nodeName || child.uuid == nodeName) return child;
                var result:Object3D = findNodeInChildren(child, nodeName);
                if (result != null) return result;
            }
            return null;
        }

        public static function create(root:Object3D, path:String, parsedPath:Object = null):PropertyBinding
        {
            var binding:PropertyBinding = new PropertyBinding(root, path, parsedPath);
            binding.bind();
            return binding;
        }

        // ------------------------------------------------------------------
        // Resolution
        // ------------------------------------------------------------------

        public function bind():void
        {
            var parsed:Object = this.parsedPath;
            var nodeName:String = parsed["nodeName"];
            var objectName:* = parsed["objectName"];
            var objectIndex:* = parsed["objectIndex"];
            var propertyName:String = parsed["propertyName"];
            var propertyIndex:* = parsed["propertyIndex"];

            var node:Object3D = PropertyBinding.findNode(this.rootNode, nodeName);
            if (node == null)
            {
                this.bindingType = INVALID;
                return;
            }

            this.node = node;

            var target:* = node;

            if (objectName != null)
            {
                switch (String(objectName))
                {
                    case "bones":
                        if (!(node is SkinnedMesh) || SkinnedMesh(node).skeleton == null)
                        {
                            this.bindingType = INVALID;
                            return;
                        }
                        target = SkinnedMesh(node).skeleton.bones;
                        // resolve a bone name into its index
                        if (objectIndex != null)
                        {
                            var boneCount:int = int(target.length);
                            for (var b:int = 0; b < boneCount; b++)
                            {
                                if (target[b].name == String(objectIndex))
                                {
                                    objectIndex = b;
                                    break;
                                }
                            }
                        }
                        break;

                    default:
                        target = target[String(objectName)];
                        break;
                }

                if (target == null)
                {
                    this.bindingType = INVALID;
                    return;
                }

                if (objectIndex != null)
                {
                    target = target[objectIndex];
                    if (target == null)
                    {
                        this.bindingType = INVALID;
                        return;
                    }
                }
            }

            var nodeProperty:* = target[propertyName];
            if (nodeProperty == null)
            {
                this.bindingType = INVALID;
                return;
            }

            this.targetObject = target;

            if (target is Material) this.versioning = VersionNeedsUpdate;
            else if (target is Object3D) this.versioning = VersionMatrixWorldNeedsUpdate;
            else this.versioning = VersionNone;

            if (propertyIndex != null)
            {
                // sub-element of an array property
                if (propertyName == "morphTargetInfluences")
                {
                    if (!(node is Mesh))
                    {
                        this.bindingType = INVALID;
                        return;
                    }
                    var mesh:Mesh = Mesh(node);
                    if (mesh.morphTargetDictionary != null &&
                        mesh.morphTargetDictionary[String(propertyIndex)] != null)
                    {
                        propertyIndex = int(mesh.morphTargetDictionary[String(propertyIndex)]);
                    }
                }

                this.bindingType = ArrayElement;
                this.resolvedProperty = nodeProperty;
                this.propertyIndex = toIndex(propertyIndex);
                this.propertyName = propertyName;
                return;
            }

            if (nodeProperty is Vector3 || nodeProperty is Vector2 || nodeProperty is Vector4 ||
                nodeProperty is Quaternion || nodeProperty is Color)
            {
                this.bindingType = HasFromToArray;
                this.resolvedProperty = nodeProperty;
                return;
            }

            if (AnimationUtils.isArrayLike(nodeProperty))
            {
                this.bindingType = EntireArray;
                this.resolvedProperty = nodeProperty;
                return;
            }

            this.bindingType = Direct;
            this.propertyName = propertyName;
        }

        private static function toIndex(value:*):int
        {
            if (value is String)
            {
                return int(String(value));
            }
            return int(value);
        }

        public function unbind():void
        {
            this.node = null;
            this.bindingType = INVALID;
        }

        // ------------------------------------------------------------------
        // Value transfer
        // ------------------------------------------------------------------

        public function getValue(buffer:Vector.<Number>, offset:int):void
        {
            var i:int;
            switch (this.bindingType)
            {
                case Direct:
                    buffer[offset] = Number(this.targetObject[this.propertyName]);
                    break;

                case EntireArray:
                    var source:* = this.resolvedProperty;
                    var n:int = int(source.length);
                    for (i = 0; i < n; i++) buffer[offset + i] = Number(source[i]);
                    break;

                case ArrayElement:
                    buffer[offset] = Number(this.resolvedProperty[this.propertyIndex]);
                    break;

                case HasFromToArray:
                    this.resolvedProperty.toArray(buffer, offset);
                    break;

                default:
                    break;
            }
        }

        public function setValue(buffer:Vector.<Number>, offset:int):void
        {
            var i:int;
            switch (this.bindingType)
            {
                case Direct:
                    var value:Number = buffer[offset];
                    // `visible` (and other booleans) round-trip through the numeric
                    // buffer; write the boolean shape back so the scene graph does
                    // not end up with 0/1 where a Boolean is expected.
                    if (this.targetObject[this.propertyName] is Boolean)
                    {
                        this.targetObject[this.propertyName] = (value != 0);
                    }
                    else
                    {
                        this.targetObject[this.propertyName] = value;
                    }
                    this._noteChange();
                    break;

                case EntireArray:
                    var dest:* = this.resolvedProperty;
                    var n:int = int(dest.length);
                    for (i = 0; i < n; i++) dest[i] = buffer[offset + i];
                    this._noteChange();
                    break;

                case ArrayElement:
                    this.resolvedProperty[this.propertyIndex] = buffer[offset];
                    this._noteChange();
                    break;

                case HasFromToArray:
                    this.resolvedProperty.fromArray(buffer, offset);
                    this._noteChange();
                    break;

                default:
                    break;
            }
        }

        private function _noteChange():void
        {
            var target:Object = this.targetObject;
            if (this.versioning == VersionNeedsUpdate)
            {
                // material writes do not need a recompile here: the renderer
                // re-reads the scalar factors every draw (see AGALRenderer
                // _fillStandardConstants), so only the version bump remains.
                if (target is Material) Material(target).needsUpdate = true;
            }
            else if (this.versioning == VersionMatrixWorldNeedsUpdate)
            {
                if (target is Object3D) Object3D(target).matrixWorldNeedsUpdate = true;
            }
        }
    }
}