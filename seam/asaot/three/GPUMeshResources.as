// GPUMeshResources.as -- per-mesh Stage3D buffer cache for AGALRenderer.
//
// One class per file, on purpose: the flex compiler rejects a second
// package-level definition in the same file ("意外发现一个具有名称 ... 的外部可见
// 定义"), and a class placed *outside* the package block cannot see the package
// imports at all, so its VertexBuffer3D/IndexBuffer3D fields fail to resolve and
// the AIR build dies. A separate internal class in the same package is the shape
// that compiles on both as-aot and mxmlc.
package asaot.three
{
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.VertexBuffer3D;

    // A mesh's position/normal/uv/index buffers are rebuilt only when the
    // attribute version changes, so the per-frame render never allocates a fresh
    // GPU buffer for a static mesh.
    public class GPUMeshResources
    {
        public var vertexBuffer:VertexBuffer3D = null;
        public var normalBuffer:VertexBuffer3D = null;
        public var uvBuffer:VertexBuffer3D = null;
        public var indexBuffer:IndexBuffer3D = null;
        public var positionVersion:int = -1;
        public var normalVersion:int = -1;
        public var uvVersion:int = -1;
        public var indexVersion:int = -1;

        // M19 wireframe: the same CPU-expanded quad buffers the M11 LineSegments
        // path uses, built from this geometry's triangles. Rebuilt when the
        // position or index version changes; `wireframeEdges` is 3 per triangle.
        public var wireframeBuffer:VertexBuffer3D = null;
        public var wireframeOtherBuffer:VertexBuffer3D = null;
        public var wireframeSideBuffer:VertexBuffer3D = null;
        public var wireframeIndexBuffer:IndexBuffer3D = null;
        public var wireframePositionVersion:int = -1;
        public var wireframeIndexVersion:int = -2;
        public var wireframeEdges:int = 0;
    }
}