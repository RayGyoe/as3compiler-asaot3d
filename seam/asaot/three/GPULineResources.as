// GPULineResources.as -- per-line-geometry Stage3D buffer cache for AGALRenderer (M11).
//
// Line segments are expanded on the CPU into screen-space quads, so the cache is
// keyed by segment count and the versions of the attributes it reads (position,
// and since M26 the optional per-vertex colour).
//
// The scratch Vectors live here too: a geometry that updates every frame
// (SkeletonHelper) refills them in place and re-uploads, instead of allocating a
// fresh set of doubles per frame (AGENTS.md memory red-line).
package asaot.three
{
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.VertexBuffer3D;

    public class GPULineResources
    {
        public var positionBuffer:VertexBuffer3D = null;
        public var otherBuffer:VertexBuffer3D = null;
        public var sideBuffer:VertexBuffer3D = null;
        // M26: per-vertex colour (null until a geometry with a `color` attribute
        // and a material with vertexColors is drawn).
        public var colorBuffer:VertexBuffer3D = null;
        public var indexBuffer:IndexBuffer3D = null;
        public var segmentCount:int = 0;
        public var positionVersion:int = -1;
        public var colorVersion:int = -1;
        // Segment count the current buffers were sized for; a change reallocates.
        public var allocatedSegments:int = -1;

        // Scratch buffers, sized for `allocatedSegments` and refilled in place.
        public var posData:Vector.<Number> = null;
        public var otherData:Vector.<Number> = null;
        public var sideData:Vector.<Number> = null;
        public var colorData:Vector.<Number> = null;
    }
}