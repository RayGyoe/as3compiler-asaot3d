// asaot.three.objects.LineSegments -- independent line segment pairs.
//
// Borrows src/objects/LineSegments.js (r187): a geometry whose `position`
// attribute is a flat list of vertex PAIRS (0-1, 2-3, 4-5, ...) plus a line
// material. three.js's `Line` (strip) variant is not ported: EdgesGeometry --
// the producer this exists for -- emits pairs.
//
// Stage3D has no line primitive, so the renderer expands every segment into a
// screen-space quad in the vertex shader (see AGALRenderer._buildLineProgram and
// three-api-design.md §16).
package asaot.three.objects
{
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Object3D;
    import asaot.three.materials.Material;

    public class LineSegments extends Object3D
    {
        public var geometry:BufferGeometry = null;
        public var material:Material = null;
        public var isLineSegments:Boolean = true;

        public function LineSegments(geometry:BufferGeometry = null, material:Material = null)
        {
            super();
            this.geometry = geometry;
            this.material = material;
        }
    }
}