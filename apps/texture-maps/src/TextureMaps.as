// TextureMaps.as -- M4 acceptance demo: the PBR texture map family on-screen.
//
// Three rotating cubes, all MeshStandardMaterial:
//   * Left  : normalMap (procedural bead bumps) -- proves the R8 derivative
//             tangent-frame normal mapping path.
//   * Middle: roughnessMap (alternating stripes) -- proves roughnessFactor *=
//             texel.g (roughnessmap_fragment.glsl.js:9) modulates GGX gloss.
//   * Right : metalnessMap (metal disc on dielectric) -- proves metalnessFactor
//             *= texel.b (metalnessmap_fragment.glsl.js:9).
//
// All textures are procedurally generated BitmapData (no runtime image decode
// needed -- that lands in M5), uploaded through the Texture version seam.
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

    public class TextureMaps extends Stage3DApp
    {
        private var _cubeNormal:Mesh;
        private var _cubeRough:Mesh;
        private var _cubeMetal:Mesh;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 9);

            // Left: blue cube with a procedural bead normal map. normalScale is
            // bumped to 3.0 so the bumps read clearly against the flat faces.
            var matNormal:MeshStandardMaterial = new MeshStandardMaterial();
            matNormal.color.setHex(0x3366ff);
            matNormal.roughness = 0.35;
            matNormal.metalness = 0.0;
            matNormal.normalMap = new Texture(this._makeNormalMap(256, 256));
            matNormal.normalScale.set(3.0, 3.0);
            _cubeNormal = new Mesh(new BoxGeometry(2, 2, 2), matNormal);
            _cubeNormal.position.set(-3, 0, 0);
            _scene.add(_cubeNormal);

            // Middle: white cube whose gloss alternates between matte and shiny
            // stripes (roughness 0.05 vs 1.0 sampled from the G channel).
            var matRough:MeshStandardMaterial = new MeshStandardMaterial();
            matRough.color.setHex(0xffffff);
            matRough.roughness = 1.0;
            matRough.metalness = 0.0;
            matRough.roughnessMap = new Texture(this._makeStripes(256, 256, 64));
            _cubeRough = new Mesh(new BoxGeometry(2, 2, 2), matRough);
            _cubeRough.position.set(0, 0, 0);
            _scene.add(_cubeRough);

            // Right: blue cube with a metal disc. three.js semantics: the map
            // ATTENUATES the material value (metalnessFactor = metalness *
            // texel.b), so the base metalness is 1.0 and the disc's texel.b = 0
            // outside the circle turns the surroundings dielectric (diffuse
            // blue), leaving a mirror-blue metal disc inside.
            var matMetal:MeshStandardMaterial = new MeshStandardMaterial();
            matMetal.color.setHex(0x3366ff);
            matMetal.roughness = 0.15;
            matMetal.metalness = 1.0;
            matMetal.metalnessMap = new Texture(this._makeMetalDisc(256, 256));
            _cubeMetal = new Mesh(new BoxGeometry(2, 2, 2), matMetal);
            _cubeMetal.position.set(3, 0, 0);
            _scene.add(_cubeMetal);

            // Light from above-front (0,0.5,4) so the camera-facing faces are
            // lit and the specular streak lands on the front face centre, where
            // it crosses the middle cube's vertical roughness stripes (matte
            // stripes cut the streak, glossy stripes carry it).
            var sun:DirectionalLight = new DirectionalLight(0xffffff, 1.5);
            sun.position.set(0, 0.5, 4);
            _scene.add(sun);
            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.05);
            _scene.add(ambient);
        }

        // Procedural bead normal map: a grid of raised domes. Per-pixel central
        // differences of the height field give the surface gradient; the stored
        // texel is (n.x*0.5+0.5, n.y*0.5+0.5, n.z*0.5+0.5) -- the fragment
        // shader decodes it back with texel*2-1. The flat background stores
        // (0.5, 0.5, 1.0), the identity normal.
        private function _makeNormalMap(w:int, h:int):BitmapData
        {
            var bmp:BitmapData = new BitmapData(w, h, false, 0xFF8080FF);
            var cells:int = 4;
            var cellSize:Number = w / cells;
            var domeRadius:Number = cellSize * 0.32;
            var strength:Number = 3.0;

            // Bead centers on a 4x4 grid.
            var centers:Vector.<Number> = new Vector.<Number>();
            for (var cy:int = 0; cy < cells; cy++)
            {
                for (var cx:int = 0; cx < cells; cx++)
                {
                    centers.push((cx + 0.5) * cellSize);
                    centers.push((cy + 0.5) * cellSize);
                }
            }

            for (var y:int = 0; y < h; y++)
            {
                for (var x:int = 0; x < w; x++)
                {
                    // Sum the gaussian domes (height + analytic gradient).
                    var gx:Number = 0;
                    var gy:Number = 0;
                    var i:int;
                    for (i = 0; i < centers.length; i += 2)
                    {
                        var dx:Number = x - centers[i];
                        var dy:Number = y - centers[i + 1];
                        var d2:Number = dx * dx + dy * dy;
                        var g:Number = Math.exp(-d2 / (domeRadius * domeRadius));
                        gx += g * (-2 * dx / (domeRadius * domeRadius)) * strength;
                        gy += g * (-2 * dy / (domeRadius * domeRadius)) * strength;
                    }
                    // normal = normalize(-gx, -gy, 1)
                    var len:Number = Math.sqrt(gx * gx + gy * gy + 1);
                    var nx:Number = -gx / len;
                    var ny:Number = -gy / len;
                    var nz:Number = 1.0 / len;
                    var r:int = int((nx * 0.5 + 0.5) * 255);
                    var gg:int = int((ny * 0.5 + 0.5) * 255);
                    var b:int = int((nz * 0.5 + 0.5) * 255);
                    bmp.setPixel(x, y, (0xFF << 24) | (r << 16) | (gg << 8) | b);
                }
            }
            return bmp;
        }

        // Vertical stripes: G channel alternates 0.05 (light) and 1.0 (dark),
        // so roughnessFactor *= texel.g modulates the GGX gloss visibly. The
        // stripes run VERTICALLY (vary with x) so the horizontal specular
        // streak from the (0,0.5,4) key light crosses several of them.
        private function _makeStripes(w:int, h:int, cell:int):BitmapData
        {
            var bmp:BitmapData = new BitmapData(w, h, false, 0xFFFFFFFF);
            var cols:int = w / cell;
            for (var col:int = 0; col < cols; col++)
            {
                var bright:Boolean = (col & 1) == 0;
                var v:int = bright ? 13 : 255; // 0.05 / 1.0 in G
                var color:uint = (0xFF << 24) | (v << 16) | (v << 8) | v;
                bmp.fillRect(new Rectangle(col * cell, 0, cell, h), color);
            }
            return bmp;
        }

        // Metal disc: B channel is 1.0 inside the disc (metalness 1), 0 outside.
        private function _makeMetalDisc(w:int, h:int):BitmapData
        {
            var bmp:BitmapData = new BitmapData(w, h, false, 0xFF000000);
            var r:int = w * 2 / 5;
            var cx:Number = w / 2;
            var cy:Number = h / 2;
            for (var y:int = 0; y < h; y++)
            {
                for (var x:int = 0; x < w; x++)
                {
                    var dx:Number = x - cx;
                    var dy:Number = y - cy;
                    if (dx * dx + dy * dy < r * r)
                    {
                        bmp.setPixel(x, y, 0xFF0000FF);
                    }
                }
            }
            return bmp;
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _cubeNormal.rotation.x += 0.004;
            _cubeNormal.rotation.y += 0.008;
            // The middle cube stays fixed: its roughness stripes are only
            // visible when the specular streak from the (0,0.5,4) key light
            // lands on the camera-facing face, which a stable orientation
            // guarantees (the streak cuts across the vertical stripes).
            _cubeMetal.rotation.x += 0.004;
            _cubeMetal.rotation.y += 0.008;
        }
    }
}
