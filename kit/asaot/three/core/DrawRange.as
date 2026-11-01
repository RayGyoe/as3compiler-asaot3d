// asaot.three.core.DrawRange -- start/count pair for partial rendering.
//
// three.js uses a bare {start,count} object literal with count defaulting to
// Infinity (BufferGeometry.js:363). AS3 has no object literals and no Infinity
// default convention (three-api-design.md D5/D7); this struct class carries the
// pair, with `count = -1` meaning "render to the end" (a sentinel, not JS Infinity).
package asaot.three.core
{
    public class DrawRange
    {
        public var start:int;
        public var count:int;

        public function DrawRange(start:int = 0, count:int = -1)
        {
            this.start = start;
            this.count = count;
        }
    }
}
