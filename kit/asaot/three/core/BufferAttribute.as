// asaot.three.core.BufferAttribute -- per-vertex attribute buffer, three.js style.
//
// Borrows the design of three.js src/core/BufferAttribute.js (r187): an `array`
// holding itemSize * count scalar values, with getX/setXYZ-style component accessors
// and a `version` bump driven by a `needsUpdate` setter (the seam layer watches this
// to decide when to re-upload to the GPU).
//
// DIVERGENCES (three-api-design.md §8):
//   D-array  three.js holds a TypedArray (Float32Array/Uint8Array/...); we hold a
//            Vector.<Number> (AS3 Number = double). CPU-side data is ALWAYS float
//            semantics, so `normalized` is retained as a field but no GL-style
//            normalization round-trip is needed on read -- normalization belongs to
//            the GPU upload layer (seam), not the CPU buffer. (Not a silent downgrade:
//            our array is already float, three.js only normalizes because its array
//            may be Uint8/Int16.)
//   D-index  the index buffer is ALSO a Vector.<Number> with itemSize=1. three.js
//            splits Uint16BufferAttribute vs Uint32BufferAttribute by vertex count;
//            that precision choice is a GPU-upload concern (seam layer), not a CPU
//            buffer concern, so M1 keeps a single Number-backed attribute.
//   D9-clone clone() returns BufferAttribute (no this.constructor reflection in AS3).
package asaot.three.core
{
    public class BufferAttribute
    {
        public var array:Vector.<Number>;
        public var itemSize:int;
        public var normalized:Boolean;
        public var name:String = "";

        // Bumped every time `needsUpdate` is set true; the seam layer caches this to
        // detect when the GPU buffer is stale.
        public var version:int = 0;
        private var _needsUpdate:Boolean = false;

        public function BufferAttribute(array:Vector.<Number>, itemSize:int, normalized:Boolean = false)
        {
            this.array = array;
            this.itemSize = itemSize;
            this.normalized = normalized;
        }

        // Number of vertices (array.length / itemSize). Computed on demand so it stays
        // correct if `array` is mutated after construction (three.js freezes it at
        // construction; we make it a getter -- same read shape, safer).
        public function get count():int
        {
            return this.array.length / this.itemSize;
        }

        // Dirty flag: setting true bumps `version` (three.js BufferAttribute.js:155).
        public function set needsUpdate(value:Boolean):void
        {
            if (value == true) this.version++;
            this._needsUpdate = value;
        }

        public function get needsUpdate():Boolean
        {
            return this._needsUpdate;
        }

        // ---- component accessors (three.js BufferAttribute.js:429-654) ----
        public function getX(index:int):Number
        {
            return this.array[index * this.itemSize];
        }

        public function setX(index:int, x:Number):BufferAttribute
        {
            this.array[index * this.itemSize] = x;
            return this;
        }

        public function getY(index:int):Number
        {
            return this.array[index * this.itemSize + 1];
        }

        public function setY(index:int, y:Number):BufferAttribute
        {
            this.array[index * this.itemSize + 1] = y;
            return this;
        }

        public function getZ(index:int):Number
        {
            return this.array[index * this.itemSize + 2];
        }

        public function setZ(index:int, z:Number):BufferAttribute
        {
            this.array[index * this.itemSize + 2] = z;
            return this;
        }

        public function getW(index:int):Number
        {
            return this.array[index * this.itemSize + 3];
        }

        public function setW(index:int, w:Number):BufferAttribute
        {
            this.array[index * this.itemSize + 3] = w;
            return this;
        }

        public function setXY(index:int, x:Number, y:Number):BufferAttribute
        {
            index = index * this.itemSize;
            this.array[index + 0] = x;
            this.array[index + 1] = y;
            return this;
        }

        public function setXYZ(index:int, x:Number, y:Number, z:Number):BufferAttribute
        {
            index = index * this.itemSize;
            this.array[index + 0] = x;
            this.array[index + 1] = y;
            this.array[index + 2] = z;
            return this;
        }

        public function setXYZW(index:int, x:Number, y:Number, z:Number, w:Number):BufferAttribute
        {
            index = index * this.itemSize;
            this.array[index + 0] = x;
            this.array[index + 1] = y;
            this.array[index + 2] = z;
            this.array[index + 3] = w;
            return this;
        }

        // Copy the metadata + a fresh copy of the data array from `source`.
        public function copy(source:BufferAttribute):BufferAttribute
        {
            var copy:Vector.<Number> = new Vector.<Number>();
            var i:int = 0;
            while (i < source.array.length)
            {
                copy.push(source.array[i]);
                i++;
            }
            this.array = copy;
            this.itemSize = source.itemSize;
            this.normalized = source.normalized;
            this.name = source.name;
            return this;
        }

        // D9-clone: no this.constructor reflection, return a BufferAttribute copy.
        public function clone():BufferAttribute
        {
            return new BufferAttribute(new Vector.<Number>(), this.itemSize, this.normalized).copy(this);
        }
    }
}
