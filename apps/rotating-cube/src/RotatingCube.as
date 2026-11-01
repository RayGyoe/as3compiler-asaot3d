// RotatingCube.as -- M1 first-frame demo: a Stage3D context renders a rotating
// red cube through AGALRenderer (the whole scene-graph -> upload -> draw path).
//
// The Stage3D wiring (requestContext3D -> CONTEXT3D_CREATE -> context3D), the
// per-frame render/present, the display-rate sync and the window-resize handling
// all live in Stage3DApp; a demo only declares its scene and its animation.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.materials.MeshBasicMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class RotatingCube extends Stage3DApp
    {
        private var _cube:Mesh;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(75, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 5);

            var material:MeshBasicMaterial = new MeshBasicMaterial();
            material.color.setHex(0xff2222); // red cube

            _cube = new Mesh(new BoxGeometry(2, 2, 2), material);
            _scene.add(_cube);
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _cube.rotation.x += 0.01;
            _cube.rotation.y += 0.02;
        }
    }
}