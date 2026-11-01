// asaot.three.objects.Group -- pure grouping node, three.js style.
//
// Borrows src/objects/Group.js (r187): an Object3D with no geometry/material,
// used to group children and apply a shared transform.
package asaot.three.objects
{
    import asaot.three.core.Object3D;

    public class Group extends Object3D
    {
        public function Group()
        {
            super();
        }
    }
}
