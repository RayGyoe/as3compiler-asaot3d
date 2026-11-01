// GLTFM8.as -- M8 acceptance demo: glTF 2.0 assets loaded from disk.
//
//   * Duck.glb          -- GLB container (JSON + BIN chunks), embedded PNG
//                          texture, node matrices (0.01 uniform scale);
//   * DamagedHelmet.gltf -- glTF text + external .bin + five external JPEGs
//                          (baseColor / metallicRoughness / normal / AO /
//                          emissive), the canonical metallic-roughness asset.
//
// Both go through asaot.three.loaders.GLTFLoader. The renderer is the shared
// AGALRenderer: loaded BufferGeometry/Texture feed exactly the same GPU
// uploads the procedural demos use, so nothing in the seam changes for glTF.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.Object3D;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.loaders.GLTFLoader;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class GLTFM8 extends Stage3DApp
    {
        private var _duck:Object3D;
        private var _helmet:Object3D;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(45, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0.35, 5.2);
            _camera.lookAt(0, 0, 0);

            // Key light plus a fill so the metallic helmet surfaces carry a
            // highlight instead of reading as a flat silhouette (there is no
            // IBL yet -- M9).
            var key:DirectionalLight = new DirectionalLight(0xffffff, 2.2);
            key.position.set(2.5, 3.5, 4.0);
            _scene.add(key);

            var fill:DirectionalLight = new DirectionalLight(0x8899bb, 0.9);
            fill.position.set(-3.0, -1.0, 2.0);
            _scene.add(fill);

            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.55);
            _scene.add(ambient);

            var duckLoader:GLTFLoader = new GLTFLoader();
            duckLoader.load("app:/assets/models/gltf/Duck.glb", onDuck, null, onLoadError);

            var helmetLoader:GLTFLoader = new GLTFLoader();
            helmetLoader.load("app:/assets/models/gltf/DamagedHelmet/DamagedHelmet.gltf",
                onHelmet, null, onLoadError);
        }

        private function onLoadError(e:Object):void
        {
            logLine("glTF load error: " + e);
        }

        // Duck.glb is authored in centimetres with a 0.01 root scale, so it
        // arrives ~1.6 units around the origin; just park it to the left.
        private function onDuck(root:Object3D):void
        {
            _duck = root;
            _duck.position.set(-1.35, -0.25, 0);
            _scene.add(_duck);
            logLine("duck loaded");
        }

        // DamagedHelmet is ~1.9 x 2.0 x 1.8; nudge it right and back a touch.
        private function onHelmet(root:Object3D):void
        {
            _helmet = root;
            _helmet.position.set(1.35, -0.1, 0.2);
            _scene.add(_helmet);
            logLine("helmet loaded");
        }

        private var _frameCount:int = 0;

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frameCount++;
            if (_frameCount <= 3) logLine("frame " + _frameCount +
                " duck=" + (_duck != null) + " helmet=" + (_helmet != null));

            if (_duck != null) _duck.rotation.y += 0.010;
            if (_helmet != null) _helmet.rotation.y += 0.006;
        }
    }
}