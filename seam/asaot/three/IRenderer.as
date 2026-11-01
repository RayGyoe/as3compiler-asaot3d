// asaot.three.IRenderer -- narrow renderer seam the engine layer depends on.
//
// The renderer is a replaceable backend (three-api-design.md §9): AGALRenderer
// is the default; a future NativeShaderRenderer (E6, opt-in) will implement the
// same interface. The engine never talks to Context3D directly.
package asaot.three
{
    import asaot.three.cameras.Camera;
    import asaot.three.scenes.Scene;

    public interface IRenderer
    {
        function render(scene:Scene, camera:Camera):void;
        function setSize(width:int, height:int):void;
    }
}
