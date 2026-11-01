// asaot.three.core.Intersection -- one ray/pick hit, three.js style.
//
// three.js returns Raycaster hits as anonymous object literals (see the typedef in
// Raycaster.js). AS3 has no literals and no structural typing, so the same fields
// are declared on a class (D96). Field names follow r187 exactly so ported code
// reads the same:
//
//   distance   distance from the RAY ORIGIN (not from the camera plane) to `point`
//   point      hit position in WORLD space
//   object     the Object3D that was hit
//   face       the hit triangle (a/b/c indices + local face normal)
//   faceIndex  triangle number, in indexed-buffer semantics
//   uv         interpolated uv at the hit (null when the geometry has no uvs)
//   normal     interpolated NORMAL, flipped to face the ray (null without normals)
//   barycoord  barycentric weights (x,y,z) of `point` inside `face`
//
// `uv`/`normal`/`barycoord` are typed because the values are typed in three.js;
// null means "the geometry has no such attribute", which is why the checks in
// callers stay `!= null` rather than "isEmpty()".
package asaot.three.core
{
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;

    public class Intersection
    {
        public var distance:Number = 0;
        public var point:Vector3 = null;
        public var object:Object3D = null;
        public var face:Face = null;
        public var faceIndex:int = -1;
        public var uv:Vector2 = null;
        public var normal:Vector3 = null;
        public var barycoord:Vector3 = null;
    }
}