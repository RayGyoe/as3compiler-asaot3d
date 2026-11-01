// asaot.three.core.Object3D -- scene-graph node base class, three.js style.
//
// Borrows the design of three.js src/core/Object3D.js (r187): the position /
// rotation / quaternion / scale transform quartet, the local `matrix` vs world
// `matrixWorld` split with lazy update flags, and the parent/children hierarchy.
//
// rotation<->quaternion TWO-WAY SYNC: three.js wires `rotation._onChange` and
// `quaternion._onChange` callbacks in the constructor using module-local scratch
// objects. We do the same with constructor-local variables captured by closures,
// so `obj.rotation.x += 0.01` AND `obj.quaternion.set(...)` both stay in sync
// (D6). This replaces the earlier (flawed) plan of syncing in Object3D's own
// rotation getter/setter, which would have missed field-level writes.
//
// DIVERGENCES (three-api-design.md §8):
//   D1  userData is a Dictionary (arbitrary keys), not a JS {}.
//   D2  add/remove use AS3 `...rest` varargs (single-object fast path kept).
//   D6  rotation/quaternion sync via _onChange (as above).
//   D8  `pivot` (r187) is NOT borrowed this milestone.
package asaot.three.core
{
    import flash.utils.Dictionary;

    import asaot.three.math.Euler;
    import asaot.three.math.MathUtils;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;

    public class Object3D
    {
        // ---- identity / naming ----
        public var id:int;
        public var uuid:String;
        public var name:String = "";

        // ---- user data (D1: Dictionary, arbitrary keys) ----
        public var userData:Dictionary = new Dictionary();

        // ---- hierarchy ----
        public var parent:Object3D = null;
        public var children:Vector.<Object3D> = new Vector.<Object3D>();

        // ---- transform quartet ----
        public var position:Vector3;
        public var rotation:Euler;
        public var quaternion:Quaternion;
        public var scale:Vector3;
        public var up:Vector3;

        // ---- matrices ----
        public var matrix:Matrix4;
        public var matrixWorld:Matrix4;
        public var matrixAutoUpdate:Boolean = true;
        public var matrixWorldNeedsUpdate:Boolean = false;

        // ---- visibility / render flags ----
        public var visible:Boolean = true;
        public var castShadow:Boolean = false;
        public var receiveShadow:Boolean = false;
        public var frustumCulled:Boolean = true;
        public var renderOrder:int = 0;

        // ---- type-test flags (used by lookAt to orient cameras/lights outward) ----
        public var isObject3D:Boolean = true;
        public var isCamera:Boolean = false;
        public var isLight:Boolean = false;
        // M26: SkeletonHelper asks every node it walks, so the flag has to exist on
        // the BASE class (three.js reads `object.isBone`, which is simply undefined
        // on a non-Bone -- AS3 has no undefined, so the base declares it false).
        // Bone flips it true in its constructor.
        public var isBone:Boolean = false;

        // ---- monotonic instance id (three.js uses a module counter) ----
        private static var _object3DId:int = 0;

        public function Object3D()
        {
            this.id = Object3D._object3DId;
            Object3D._object3DId++;
            this.uuid = MathUtils.generateUUID();

            var position:Vector3 = new Vector3();
            var rotation:Euler = new Euler();
            var quaternion:Quaternion = new Quaternion();
            var scale:Vector3 = new Vector3(1, 1, 1);

            // Two-way sync: a field write on either side updates the other.
            // `false` suppresses the paired onChange so the two callbacks can't
            // recurse into each other (three.js passes update=false for the same
            // reason).
            rotation._onChange(function():void { quaternion.setFromEuler(rotation, false); });
            quaternion._onChange(function():void { rotation.setFromQuaternion(quaternion, null, false); });

            this.position = position;
            this.rotation = rotation;
            this.quaternion = quaternion;
            this.scale = scale;
            this.up = new Vector3(0, 1, 0);

            this.matrix = new Matrix4();
            this.matrixWorld = new Matrix4();
        }

        // ---- add / remove (D2: AS3 rest varargs) ----
        public function add(object:Object3D):Object3D
        {
            if (object == this) return this;
            if (object == null) return this;

            if (object.parent != null) object.removeFromParent();
            object.parent = this;
            this.children.push(object);
            return this;
        }

        public function remove(object:Object3D):Object3D
        {
            var idx:int = this.children.indexOf(object);
            if (idx != -1)
            {
                object.parent = null;
                this.children.splice(idx, 1);
            }
            return this;
        }

        public function removeFromParent():Object3D
        {
            if (this.parent != null) this.parent.remove(this);
            return this;
        }

        public function clear():Object3D
        {
            while (this.children.length > 0)
            {
                this.remove(this.children[this.children.length - 1]);
            }
            return this;
        }

        // ---- traversal ----
        public function traverse(callback:Function):void
        {
            callback(this);
            var i:int = 0;
            while (i < this.children.length)
            {
                this.children[i].traverse(callback);
                i++;
            }
        }

        public function traverseVisible(callback:Function):void
        {
            if (!this.visible) return;
            callback(this);
            var i:int = 0;
            while (i < this.children.length)
            {
                this.children[i].traverseVisible(callback);
                i++;
            }
        }

        public function traverseAncestors(callback:Function):void
        {
            if (this.parent != null)
            {
                callback(this.parent);
                this.parent.traverseAncestors(callback);
            }
        }

        // ---- search ----
        public function getObjectByName(name:String):Object3D
        {
            if (this.name == name) return this;
            var i:int = 0;
            while (i < this.children.length)
            {
                var found:Object3D = this.children[i].getObjectByName(name);
                if (found != null) return found;
                i++;
            }
            return null;
        }

        // ---- matrix updates ----
        public function updateMatrix():void
        {
            this.matrix.compose(this.position, this.quaternion, this.scale);
            this.matrixWorldNeedsUpdate = true;
        }

        // Lazy world-matrix update: recompute self then recurse into children.
        public function updateMatrixWorld(force:Boolean = false):void
        {
            if (this.matrixAutoUpdate) this.updateMatrix();

            if (this.matrixWorldNeedsUpdate || force)
            {
                if (this.parent == null) this.matrixWorld.copy(this.matrix);
                else this.matrixWorld.multiplyMatrices(this.parent.matrixWorld, this.matrix);
                this.matrixWorldNeedsUpdate = false;
                force = true;
            }

            var i:int = 0;
            while (i < this.children.length)
            {
                this.children[i].updateMatrixWorld(force);
                i++;
            }
        }

        // ---- picking (M14) ----
        // Every Object3D is a picking target in principle; only Mesh has geometry,
        // so the base answer is "checked, nothing hit". Returning FALSE prunes the
        // subtree (r187 Raycaster.intersect reads the return value); a plain
        // Object3D has no reason to prune, so true (propagate) is the base answer.
        public function raycast(raycaster:Raycaster, intersects:Vector.<Intersection>):Boolean
        {
            return true;
        }

        // ---- world-space queries ----
        public function getWorldPosition(target:Vector3):Vector3
        {
            this.updateMatrixWorld(true);
            return target.setFromMatrixPosition(this.matrixWorld);
        }

        public function getWorldDirection(target:Vector3):Vector3
        {
            this.updateMatrixWorld(true);
            var e:Vector.<Number> = this.matrixWorld.elements;
            target.set(e[8], e[9], e[10]).normalize();
            return target;
        }

        public function localToWorld(v:Vector3):Vector3
        {
            this.updateMatrixWorld(true);
            return v.applyMatrix4(this.matrixWorld);
        }

        public function worldToLocal(v:Vector3):Vector3
        {
            this.updateMatrixWorld(true);
            var inv:Matrix4 = new Matrix4().copy(this.matrixWorld).invert();
            return v.applyMatrix4(inv);
        }

        // ---- rotation helpers (all operate on quaternion, staying in sync) ----
        public function rotateOnAxis(axis:Vector3, angle:Number):Object3D
        {
            var q:Quaternion = new Quaternion().setFromAxisAngle(axis, angle);
            this.quaternion.multiply(q);
            return this;
        }

        public function rotateOnWorldAxis(axis:Vector3, angle:Number):Object3D
        {
            var q:Quaternion = new Quaternion().setFromAxisAngle(axis, angle);
            this.quaternion.premultiply(q);
            return this;
        }

        public function rotateX(angle:Number):Object3D
        {
            return this.rotateOnAxis(new Vector3(1, 0, 0), angle);
        }

        public function rotateY(angle:Number):Object3D
        {
            return this.rotateOnAxis(new Vector3(0, 1, 0), angle);
        }

        public function rotateZ(angle:Number):Object3D
        {
            return this.rotateOnAxis(new Vector3(0, 0, 1), angle);
        }

        public function translateOnAxis(axis:Vector3, distance:Number):Object3D
        {
            var v:Vector3 = new Vector3().copy(axis).applyQuaternion(this.quaternion);
            this.position.add(v.multiplyScalar(distance));
            return this;
        }

        public function translateX(distance:Number):Object3D
        {
            return this.translateOnAxis(new Vector3(1, 0, 0), distance);
        }

        public function translateY(distance:Number):Object3D
        {
            return this.translateOnAxis(new Vector3(0, 1, 0), distance);
        }

        public function translateZ(distance:Number):Object3D
        {
            return this.translateOnAxis(new Vector3(0, 0, 1), distance);
        }

        // Apply a matrix to position/rotation/scale via decompose.
        public function applyMatrix4(m:Matrix4):void
        {
            if (this.matrixAutoUpdate) this.updateMatrix();
            this.matrix.premultiply(m);
            this.matrix.decompose(this.position, this.quaternion, this.scale);
        }

        // Rotate to face a world-space point. Cameras/lights look outward.
        public function lookAt(x:Number, y:Number, z:Number):void
        {
            var target:Vector3 = new Vector3(x, y, z);
            var position:Vector3 = new Vector3();

            this.updateMatrixWorld(true);
            position.setFromMatrixPosition(this.matrixWorld);

            var m:Matrix4 = new Matrix4();
            if (this.isCamera || this.isLight) m.lookAt(position, target, this.up);
            else m.lookAt(target, position, this.up);

            this.quaternion.setFromRotationMatrix(m);

            if (this.parent != null)
            {
                var parentRot:Matrix4 = new Matrix4().extractRotation(this.parent.matrixWorld);
                var parentQ:Quaternion = new Quaternion().setFromRotationMatrix(parentRot);
                this.quaternion.premultiply(parentQ.invert());
            }
        }

        // ---- clone / copy ----
        public function copy(source:Object3D, recursive:Boolean = true):Object3D
        {
            this.name = source.name;
            this.up.copy(source.up);
            this.position.copy(source.position);
            this.rotation.copy(source.rotation);
            this.quaternion.copy(source.quaternion);
            this.scale.copy(source.scale);
            this.matrix.copy(source.matrix);
            this.matrixWorld.copy(source.matrixWorld);
            this.matrixAutoUpdate = source.matrixAutoUpdate;
            this.matrixWorldNeedsUpdate = source.matrixWorldNeedsUpdate;
            this.visible = source.visible;
            this.castShadow = source.castShadow;
            this.receiveShadow = source.receiveShadow;
            this.frustumCulled = source.frustumCulled;
            this.renderOrder = source.renderOrder;

            if (recursive)
            {
                var i:int = 0;
                while (i < source.children.length)
                {
                    var childClone:Object3D = source.children[i].clone();
                    this.add(childClone);
                    i++;
                }
            }
            return this;
        }

        public function clone(recursive:Boolean = true):Object3D
        {
            return new Object3D().copy(this, recursive);
        }
    }
}
