// asaot.three.materials.LineBasicMaterial -- unlit line colour.
//
// Borrows src/materials/LineBasicMaterial.js (r187): `color`, `linewidth`,
// `linecap`/`linejoin`, plus the transparent/opacity/depth flags inherited from
// Material. Only `color`, `linewidth` and the inherited flags are used by the
// asaot3d line program -- linecap/linejoin have no meaning for a Stage3D backend
// that expands segments in the vertex shader (see three-api-design.md §16).
//
// M26: `vertexColors` reads the geometry's per-vertex `color` attribute (three.js
// declares the flag on Material; here it lives on the one material the line
// program implements it for, so asking a MESH material for vertex colours is a
// compile-time error instead of a silently ignored field).
package asaot.three.materials
{
    import asaot.three.math.Color;

    public class LineBasicMaterial extends Material
    {
        // three.js default line colour is white.
        public var color:Color;
        // Rendered width in DEVICE pixels. three.js only honours >1 on some
        // platforms; ours honours it everywhere by construction (the vertex
        // shader offsets in screen space), so this is an enhancement, documented
        // in §16 as E-linewidth.
        public var linewidth:Number;

        // M26: multiply the material colour by the geometry's `color` attribute
        // (three.js `diffuseColor *= vColor`). The attribute is optional: with the
        // flag set but no attribute the draw stays flat-coloured, which is what
        // three.js does too (no USE_COLOR define when the attribute is absent).
        public var vertexColors:Boolean;

        public function LineBasicMaterial(color:uint = 0xffffff)
        {
            super();
            this.color = new Color(color);
            this.linewidth = 1;
            this.vertexColors = false;
        }
    }
}