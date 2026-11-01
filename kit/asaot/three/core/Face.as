// asaot.three.core.Face -- the triangle a picking ray hit.
//
// three.js builds this as a plain object literal inside Mesh.js:
// checkGeometryIntersection (`{ a, b, c, normal: new Vector3(), materialIndex: 0 }`).
// AS3 has no object literals, so the same four fields live on a small class
// (D96). The field NAMES and MEANINGS are unchanged: a/b/c are the three vertex
// INDICES of the hit triangle (indexed-buffer semantics), normal is the
// geometric face normal in the object's local space, materialIndex is the draw
// group's material slot.
package asaot.three.core
{
    import asaot.three.math.Vector3;

    public class Face
    {
        public var a:int;
        public var b:int;
        public var c:int;
        public var normal:Vector3;
        public var materialIndex:int;

        public function Face(a:int = 0, b:int = 0, c:int = 0)
        {
            this.a = a;
            this.b = b;
            this.c = c;
            this.normal = new Vector3();
            this.materialIndex = 0;
        }
    }
}