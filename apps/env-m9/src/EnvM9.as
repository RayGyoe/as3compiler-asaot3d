// EnvM9.as -- M9 acceptance demo: image-based lighting (cube environment map).
//
// A roughness sweep of metallic spheres lit ONLY by a cube environment map
// (plus a dim ambient/directional pair so the direct-lighting path stays
// exercised). Everything else is unchanged: the same AGALRenderer, the same
// MeshStandardMaterial. The environment arrives through
// asaot.three.loaders.CubeTextureLoader (six JPEG faces) and is installed on
// scene.environment, which every material without its own envMap picks up.
//
// What to look for: the leftmost sphere (roughness 0.05) mirrors the castle
// environment; moving right, the reflection fades toward the environment's flat
// irradiance instead of staying a sharp mirror, because this backend has no
// PMREM prefilter chain (D48). With scene.environment removed the row goes
// near-black -- that A/B is the acceptance shot for M9.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.Object3D;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.loaders.CubeTextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.CubeTexture;

    public class EnvM9 extends Stage3DApp
    {
        // Roughness sweep, left to right: mirror -> fully rough metal.
        private static const ROUGHNESS:Array = [0.05, 0.2, 0.45, 0.7, 1.0];

        override protected function createScene():void
        {
            _scene = new Scene();
            // Fixed, head-on: the acceptance shot is a frontal roughness sweep,
            // and a fixed camera makes the A/B (env on/off) pixel-comparable.
            // A narrow vertical FOV plus the 2:1 window puts the row across the
            // whole frame (a sphere is ~1.4 units in a 3.7-unit-tall view).
            _camera = new PerspectiveCamera(26, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0.2, 8.0);
            _camera.lookAt(0, 0, 0);

            // No directional light: the row must be lit by the environment
            // ALONE, otherwise a specular highlight from the key light would be
            // mistaken for a reflection. A trace of ambient just keeps the
            // darkest normals off pure black.
            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.05);
            _scene.add(ambient);

            var sphere:SphereGeometry = new SphereGeometry(0.7, 64, 48);
            var i:int;
            for (i = 0; i < 5; i++)
            {
                var mat:MeshStandardMaterial = new MeshStandardMaterial();
                mat.color.setHex(0xffffff);
                mat.metalness = 1.0;
                mat.roughness = ROUGHNESS[i] as Number;
                var mesh:Mesh = new Mesh(sphere, mat);
                mesh.position.set(-2.9 + i * 1.45, 0, 0);
                _scene.add(mesh);
            }

            // M9: the six face JPEGs of three.js's SwedishRoyalCastle cube map,
            // in +X,-X,+Y,-Y,+Z,-Z order.
            var urls:Vector.<String> = new Vector.<String>();
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/px.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/nx.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/py.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/ny.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/pz.jpg");
            urls.push("app:/assets/textures/cube/SwedishRoyalCastle/nz.jpg");

            var cubeLoader:CubeTextureLoader = new CubeTextureLoader();
            cubeLoader.load(urls, onEnvLoaded, null, onEnvError);
        }

        private function onEnvLoaded(cube:CubeTexture):void
        {
            _scene.environment = cube;
            logLine("environment loaded: face " + cube.faceSize() + "px, version " + cube.version);
        }

        private function onEnvError(e:Object):void
        {
            logLine("cube load error: " + e);
        }

        private var _frameCount:int = 0;

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frameCount++;
            if (_frameCount == 1)
            {
                logLine("frame 1 env=" + (_scene.environment != null));
            }
        }
    }
}