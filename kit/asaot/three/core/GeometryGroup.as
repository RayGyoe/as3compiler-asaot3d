// asaot.three.core.GeometryGroup -- one draw-call group in a BufferGeometry.
//
// three.js stores groups as bare JS object literals {start,count,materialIndex}
// (BufferGeometry.js:335). AS3 has no object literals (three-api-design.md D5),
// so we use this small struct class instead -- strongly typed, no boxing.
package asaot.three.core
{
    public class GeometryGroup
    {
        public var start:int;
        public var count:int;
        public var materialIndex:int;

        public function GeometryGroup(start:int = 0, count:int = 0, materialIndex:int = 0)
        {
            this.start = start;
            this.count = count;
            this.materialIndex = materialIndex;
        }
    }
}
