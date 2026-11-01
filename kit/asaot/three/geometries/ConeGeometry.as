// asaot.three.geometries.ConeGeometry -- cone = zero-radius-top cylinder.
//
// Borrows src/geometries/ConeGeometry.js (r187): it is nothing but
// CylinderGeometry(0, radius, height, ...). The apex triangles and the missing
// top cap fall out of CylinderGeometry's radiusTop==0 guards, so no geometry
// code is duplicated here.
package asaot.three.geometries
{
    public class ConeGeometry extends CylinderGeometry
    {
        public function ConeGeometry(radius:Number = 1, height:Number = 1, radialSegments:int = 32,
                                     heightSegments:int = 1, openEnded:Boolean = false,
                                     thetaStart:Number = 0, thetaLength:Number = Math.PI * 2)
        {
            super(0, radius, height, radialSegments, heightSegments, openEnded, thetaStart, thetaLength);
        }
    }
}