// asaot.three.core.Pointer -- Stage3D pointer -> NDC bridge (M14).
//
// three.js never needs this: the DOM hands PointerEvent.clientX/Y to the control,
// which divides by getBoundingClientRect(). AIR hands MouseEvent.stageX/stageY
// (top-left origin, y DOWN, pixels) to a listener on the Stage, so the conversion
// has to exist somewhere in the engine. Putting it in ONE static helper is what
// keeps picking and orbiting in agreement: a click highlight and a drag start on
// the same pixel must map to the same NDC point, or the object under the cursor
// jumps when the drag begins.
//
// THREE CONVENTIONS THAT MUST NOT BE CONFUSED:
//   * AIR stage coordinates: origin top-left, y DOWN, pixels.
//   * NDC: origin centre, y UP, [-1, 1] on both axes (three.js Raycaster coords).
//   * Texture UV: origin bottom-left, y UP, [0, 1]. Not used here -- listed
//     because `y = 1 - 2*y/h` and `v = 1 - y/h` are one division apart and mixing
//     them up flips picking vertically.
package asaot.three.core
{
    import asaot.three.math.Vector2;

    public class Pointer
    {
        // Pointer.js: (x, y) in pixels from the top-left corner -> NDC.
        // A degenerate viewport (0 or negative size, which a window can report for
        // one frame while it is being resized) would divide by zero and hand a NaN
        // ray to the raycaster; clamping the divisor to 1 keeps every coordinate
        // finite instead of letting a NaN propagate into ray/triangle tests, where
        // NaN comparisons silently report "no hit".
        public static function toNDC(x:Number, y:Number, width:Number, height:Number,
                                     out:Vector2):Vector2
        {
            var w:Number = (width > 0) ? width : 1;
            var h:Number = (height > 0) ? height : 1;
            out.x = (x / w) * 2 - 1;
            out.y = -(y / h) * 2 + 1;
            return out;
        }

        // Is the pointer inside the viewport? Used to ignore drags that wander off
        // the window: AIR keeps delivering MOUSE_MOVE to the Stage while a button
        // is held, so without this an orbit started inside the view would keep
        // spinning while the cursor is over the desktop.
        public static function isInside(x:Number, y:Number, width:Number, height:Number):Boolean
        {
            return x >= 0 && y >= 0 && x < width && y < height;
        }
    }
}