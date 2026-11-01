// PBRCube.as -- M2 first-frame demo: a Stage3D context renders two rotating PBR
// cubes through AGALRenderer using MeshStandardMaterial (GGX micro-facet specular
// + Lambert diffuse), lit by one directional light + one ambient light.
//
// The left cube is an untextured blue standard material (proving the GGX lit
// path), the right cube carries a checkerboard `map` texture (proving the base
// color sampling path). The checkerboard is mirror-symmetric, so the deferred
// flipY question does not affect this acceptance.
package
{
    import flash.display.BitmapData;
    import flash.geom.Rectangle;

    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class PBRCube extends Stage3DApp
    {
        private var _cubeA:Mesh;
        private var _cubeB:Mesh;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(75, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 6);

            // Left cube: untextured blue GGX standard material.
            var materialA:MeshStandardMaterial = new MeshStandardMaterial();
            materialA.color.setHex(0x3366ff);
            materialA.roughness = 0.3;
            materialA.metalness = 0.1;
            _cubeA = new Mesh(new BoxGeometry(2, 2, 2), materialA);
            _cubeA.position.set(-1.7, 0, 0);
            _scene.add(_cubeA);

            // Right cube: checkerboard base-color map.
            var materialB:MeshStandardMaterial = new MeshStandardMaterial();
            materialB.color.setHex(0xffffff);
            materialB.roughness = 0.4;
            materialB.metalness = 0.0;
            materialB.map = new Texture(this._makeCheckerboard(256, 256, 32));
            _cubeB = new Mesh(new BoxGeometry(2, 2, 2), materialB);
            _cubeB.position.set(1.7, 0, 0);
            _scene.add(_cubeB);

            // One directional light (default position (0,1,0) -> shines from
            // above toward the origin) + one dim ambient fill.
            var sun:DirectionalLight = new DirectionalLight(0xffffff, 1.0);
            _scene.add(sun);
            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.15);
            _scene.add(ambient);
        }

        private function _makeCheckerboard(w:int, h:int, cell:int):BitmapData
        {
            var bmp:BitmapData = new BitmapData(w, h, false, 0xffffff);
            var cols:int = w / cell;
            var rows:int = h / cell;
            for (var row:int = 0; row < rows; row++)
            {
                for (var col:int = 0; col < cols; col++)
                {
                    var white:Boolean = ((row + col) & 1) == 0;
                    var color:uint = white ? 0xffffff : 0x202020;
                    bmp.fillRect(new Rectangle(col * cell, row * cell, cell, cell), color);
                }
            }
            return bmp;
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _cubeA.rotation.x += 0.01;
            _cubeA.rotation.y += 0.02;
            _cubeB.rotation.x += 0.01;
            _cubeB.rotation.y += 0.02;
        }
    }
}
