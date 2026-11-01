// asaot.three.core.Box3 -- axis-aligned bounding box, three.js style.
//
// Borrows the design of three.js src/math/Box3.js (r187): min/max Vector3 pair,
// makeEmpty() using +/-Infinity sentinels, expandByPoint, getCenter/getSize.
// Placed in core/ (not math/) because setFromBufferAttribute needs the BufferAttribute
// type -- putting it in math/ would create a math->core reverse package dependency.
package asaot.three.core
{
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector3;
    import asaot.three.objects.Mesh;

    public class Box3
    {
        public var min:Vector3;
        public var max:Vector3;

        public function Box3(min:Vector3 = null, max:Vector3 = null)
        {
            this.min = (min != null) ? min : new Vector3(Infinity, Infinity, Infinity);
            this.max = (max != null) ? max : new Vector3(-Infinity, -Infinity, -Infinity);
        }

        // Copy the boundaries from the given vectors (three.js Box3.js:49).
        public function set(min:Vector3, max:Vector3):Box3
        {
            this.min.copy(min);
            this.max.copy(max);
            return this;
        }

        // Empty = encloses zero points (three.js Box3.js:194).
        public function makeEmpty():Box3
        {
            this.min.x = Infinity; this.min.y = Infinity; this.min.z = Infinity;
            this.max.x = -Infinity; this.max.y = -Infinity; this.max.z = -Infinity;
            return this;
        }

        // three.js Box3.js:210 -- robust empty check (max.x < min.x OR ...).
        public function isEmpty():Boolean
        {
            return (this.max.x < this.min.x) || (this.max.y < this.min.y) || (this.max.z < this.min.z);
        }

        // Enclose every position in the attribute (three.js Box3.js:86).
        public function setFromBufferAttribute(attribute:BufferAttribute):Box3
        {
            this.makeEmpty();
            var i:int = 0;
            var p:Vector3 = new Vector3();
            while (i < attribute.count)
            {
                p.set(attribute.getX(i), attribute.getY(i), attribute.getZ(i));
                this.expandByPoint(p);
                i++;
            }
            return this;
        }

        // Expand the box to include the point (three.js Box3.js:248).
        public function expandByPoint(point:Vector3):Box3
        {
            this.min.min(point);
            this.max.max(point);
            return this;
        }

        // Center into `target` (three.js Box3.js:224).
        public function getCenter(target:Vector3):Vector3
        {
            if (this.isEmpty()) return target.set(0, 0, 0);
            return target.addVectors(this.min, this.max).multiplyScalar(0.5);
        }

        // Dimensions into `target` (three.js Box3.js:236).
        public function getSize(target:Vector3):Vector3
        {
            if (this.isEmpty()) return target.set(0, 0, 0);
            return target.subVectors(this.max, this.min);
        }

        // Grow to enclose `box` (three.js Box3.js:263).
        public function union(box:Box3):Box3
        {
            this.min.min(box.min);
            this.max.max(box.max);
            return this;
        }

        // Transform by an affine matrix: transform all EIGHT corners and re-fit
        // the axis-aligned box (three.js Box3.js:365). Anything cheaper would be
        // wrong for a rotation, which turns an AABB into a non-axis-aligned box.
        public function applyMatrix4(matrix:Matrix4):Box3
        {
            if (this.isEmpty()) return this;

            var te:Vector.<Number> = matrix.elements;
            var p:Vector3 = new Vector3();
            var newBox:Box3 = new Box3();

            var xi:int = 0;
            var yi:int = 0;
            var zi:int = 0;
            while (xi < 2)
            {
                yi = 0;
                while (yi < 2)
                {
                    zi = 0;
                    while (zi < 2)
                    {
                        p.set((xi == 0) ? this.min.x : this.max.x,
                              (yi == 0) ? this.min.y : this.max.y,
                              (zi == 0) ? this.min.z : this.max.z);
                        p.applyMatrix4(matrix);
                        newBox.expandByPoint(p);
                        zi++;
                    }
                    yi++;
                }
                xi++;
            }

            return this.copy(newBox);
        }

        // three.js Box3.js:47.
        public function copy(box:Box3):Box3
        {
            this.min.copy(box.min);
            this.max.copy(box.max);
            return this;
        }

        // Enclose every Mesh's world-space geometry bounds under `object`
        // (three.js Box3.js:470 expandByObject + setFromObject).
        public function setFromObject(object:Object3D):Box3
        {
            this.makeEmpty();
            return this.expandByObject(object);
        }

        public function expandByObject(object:Object3D):Box3
        {
            if (object is Mesh)
            {
                var mesh:Mesh = Mesh(object);
                var geometry:BufferGeometry = mesh.geometry;
                if (geometry != null)
                {
                    if (geometry.boundingBox == null) geometry.computeBoundingBox();
                    _objectBox.copy(geometry.boundingBox);
                    _objectBox.applyMatrix4(mesh.matrixWorld);
                    this.union(_objectBox);
                }
            }

            var children:Vector.<Object3D> = object.children;
            var n:int = children.length;
            for (var i:int = 0; i < n; i++)
            {
                this.expandByObject(children[i]);
            }
            return this;
        }

        // three.js Box3.js:303.
        public function containsPoint(point:Vector3):Boolean
        {
            if (point.x < this.min.x || point.x > this.max.x ||
                point.y < this.min.y || point.y > this.max.y ||
                point.z < this.min.z || point.z > this.max.z) return false;
            return true;
        }

        // three.js Box3.js:436 -- bounding sphere around the box's center/radius.
        public function getBoundingSphere(target:Sphere):Sphere
        {
            if (this.isEmpty())
            {
                target.makeEmpty();
                return target;
            }

            this.getCenter(target.center);
            target.radius = this.getSize(_objectSize).length() * 0.5;
            return target;
        }

        private static var _objectBox:Box3 = new Box3();
        private static var _objectSize:Vector3 = new Vector3();
    }
}
