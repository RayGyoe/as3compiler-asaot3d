// asaot.three.extras.core.FrenetFrames -- tangent/normal/binormal triple bundle.
//
// three.js's Curve.computeFrenetFrames returns a plain object literal
// `{ tangents, normals, binormals }` (Curve.js:449). AS3 object initializers are
// not used anywhere in this engine (D-object), so the triple gets a named value
// type instead -- divergence D59 in three-api-design.md §16.
package asaot.three.extras.core
{
    import asaot.three.math.Vector3;

    public class FrenetFrames
    {
        // One entry per sample; `segments + 1` long.
        public var tangents:Vector.<Vector3>;
        public var normals:Vector.<Vector3>;
        public var binormals:Vector.<Vector3>;

        public function FrenetFrames(tangents:Vector.<Vector3>, normals:Vector.<Vector3>,
                                     binormals:Vector.<Vector3>)
        {
            this.tangents = tangents;
            this.normals = normals;
            this.binormals = binormals;
        }
    }
}