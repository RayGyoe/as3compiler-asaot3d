// asaot.three.geometries.EdgeRecord -- one pending edge while EdgesGeometry scans.
//
// Stands in for the `{ index0, index1, normal }` object literal three.js stores in
// its edge Map (EdgesGeometry.js:100). AS3 does not use object initializers in
// this engine, so the record is a named type (divergence D-object), and it also
// carries the `consumed` flag that replaces three.js's `Map.set(key, null)`
// bookkeeping (D62).
package asaot.three.geometries
{
    import asaot.three.math.Vector3;

    public class EdgeRecord
    {
        public var index0:int = 0;
        public var index1:int = 0;
        public var normal:Vector3 = new Vector3();
        public var consumed:Boolean = false;
    }
}
