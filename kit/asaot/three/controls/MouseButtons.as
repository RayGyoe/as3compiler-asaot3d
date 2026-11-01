// asaot.three.controls.MouseButtons -- which action each mouse button triggers.
//
// three.js writes this as an object literal on the control
// (`this.mouseButtons = { LEFT: MOUSE.ROTATE, MIDDLE: MOUSE.DOLLY, RIGHT: MOUSE.PAN }`).
// AS3 has no literals, so the same three slots live on a tiny class (D96), with
// the action values taken from OrbitControls' own constants (ROTATE/DOLLY/PAN).
package asaot.three.controls
{
    public class MouseButtons
    {
        public var left:int = OrbitControls.ROTATE;
        public var middle:int = OrbitControls.DOLLY;
        public var right:int = OrbitControls.PAN;

        public function MouseButtons()
        {
        }
    }
}