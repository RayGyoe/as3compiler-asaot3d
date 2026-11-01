// AssetLoad.as -- M5 acceptance demo: a scene loaded from DISK, not embedded.
//
//   * FileLoader reads assets/models/suzanne-scene.json (the three.js r187
//     examples/models/json suzanne BufferGeometry wrapped into an ObjectLoader
//     scene envelope by tools/make-suzanne-scene.js);
//   * ObjectLoader.parse rebuilds the scene graph;
//   * computeVertexNormals() derives normals (suzanne ships position+index
//     only -- the canonical three.js JSON test-model shape);
//   * TextureLoader decodes assets/textures/checker.png through the
//     URLLoader(BINARY) -> Loader.loadBytes -> Skia chain and textures a box.
//
// The renderer is the shared AGALRenderer; nothing in the seam changes for
// loaded assets -- deserialized BufferGeometry/Texture feed the same GPU
// uploads the procedural demos used.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.loaders.FileLoader;
    import asaot.three.loaders.ObjectLoader;
    import asaot.three.loaders.TextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.core.Object3D;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class AssetLoad extends Stage3DApp
    {
        private var _suzanne:Mesh;
        private var _textureBox:Mesh;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0.6, 5);

            var sun:DirectionalLight = new DirectionalLight(0xffffff, 1.5);
            sun.position.set(0, 1, 3);
            _scene.add(sun);
            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.25);
            _scene.add(ambient);

            // 1. Load the scene JSON from disk, then start the texture load
            //    (the render loop runs from ENTER_FRAME either way; meshes
            //    appear as their loads complete).
            var sceneLoader:FileLoader = new FileLoader();
            sceneLoader.load("app:/assets/models/suzanne-scene.json", onSceneText, null, onLoadError);

            var texLoader:TextureLoader = new TextureLoader();
            texLoader.load("app:/assets/textures/checker.png", onTexture, null, onLoadError);
        }

        private function onLoadError(e:Object):void
        {
            logLine("asset load error: " + e);
        }

        // 2. Deserialize the scene graph, derive normals, wire the mesh in.
        private function onSceneText(data:Object):void
        {
            var text:String = String(data);
            var loaded:Scene = new ObjectLoader().parse(JSON.parse(text));

            // The envelope is {root Group -> Mesh}; grab the mesh and its
            // geometry. computeVertexNormals fills the normal attribute the
            // renderer needs (suzanne ships position + index only).
            // Static types all the way: dynamic access through `Object` would
            // hit the props reflection table, not the struct field.
            if (loaded.children.length > 0)
            {
                var holder:Object3D = loaded.children[0];
                var kids:Vector.<Object3D> = holder.children;
                logLine("parsed root children=" + loaded.children.length + " holder=" + holder + " kids=" + kids.length);
                if (kids.length > 0)
                {
                    _suzanne = kids[0] as Mesh;
                    _suzanne.geometry.computeVertexNormals();
                }
            }

            if (_suzanne != null) _scene.add(_suzanne);
            logLine("scene loaded: suzanne mesh=" + (_suzanne != null));
        }

        // 3. Texture decode completes: texture a box with the checker pattern.
        private function onTexture(tex:Texture):void
        {
            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(0xffffff);
            mat.roughness = 0.6;
            mat.metalness = 0.0;
            mat.map = tex;
            _textureBox = new Mesh(new BoxGeometry(1.1, 1.1, 1.1), mat);
            _textureBox.position.set(-2.4, 0.7, -0.5);
            _scene.add(_textureBox);
            logLine("texture loaded: checker on box");
        }

        private var _frameCount:int = 0;

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frameCount++;
            if (_frameCount <= 3) logLine("frame " + _frameCount + " suz=" + (_suzanne != null) + " box=" + (_textureBox != null));
            if (_suzanne != null) _suzanne.rotation.y += 0.012;
            if (_textureBox != null)
            {
                _textureBox.rotation.x += 0.01;
                _textureBox.rotation.y += 0.02;
            }
        }
    }
}
