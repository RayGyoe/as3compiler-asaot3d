// SceneM20.as -- M20 acceptance demo: four P1 divergences plus scene fog and a
// textured scene background.
//
// M20 fixed four places where the field existed but the draw path ignored it,
// and made two inert Scene fields real:
//
//   P1#1 blending gate  -- three.js only applies NormalBlending when the
//        material is `transparent`; an opaque material always renders opaque.
//        Panels D/E are the SAME quad at opacity 0.45 over the same bar:
//          D transparent = false -> the bar is hidden (opaque, pre-M20 it was
//                                   translucent because the blend state was
//                                   installed unconditionally)
//          E transparent = true  -> the bar shows through
//   P1#2 shadow pruning -- an invisible subtree casts no shadow
//        (WebGLShadowMap.js:522). Panel H hides a caster's Group: a shadow on
//        that wall would come from nothing.
//   P1#3 drawRange      -- start/count are index offsets, -1 = to the end (D7).
//        Panel F is a 10x10 plane whose range stops after a wedge, so the
//        background shows through the missing triangles.
//   P1#4 unlit map      -- MeshBasicMaterial.map samples fs0 (map_fragment:
//        `diffuseColor *= sampledDiffuseColor`), which is what lets an unlit
//        glTF material keep its baseColorTexture.
//        Panels A (map = stripes) / B (map = null) are the A/B.
//   fog                 -- Scene.fog mixes the LINEAR color toward the fog color
//        before tone mapping. Panels G: two identical bars marching into the
//        distance; the left one has material.fog = false and stays crisp, the
//        right one dissolves into the fog color.
//   background          -- Scene.background = Texture draws a full-screen
//        clip-space quad sampling with the texture's own uv matrix, so the
//        checker covers the clear color.
//
// Camera at (0, 0, 11) looking down -Z; panels sit at z = +1 (view depth 10),
// inside the fog's `near` so the panels themselves stay unfogged.
package
{
    import flash.display.BitmapData;

    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshBasicMaterial;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Fog;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class SceneM20 extends Stage3DApp
    {
        private static const PANEL:Number = 1.8;

        private var _stripes:Texture;
        private var _checker:Texture;
        private var _hidden:Group;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(55, stage.stageWidth / stage.stageHeight, 0.1, 200);
            _camera.position.set(0, 0, 11);

            this._stripes = this._makeTextured(this._makeStripes(), Texture.SRGBColorSpace);
            this._checker = this._makeTextured(this._makeChecker(), Texture.SRGBColorSpace);

            // P1#4 / background: a 2D texture background is a full-screen quad.
            _scene.background = this._checker;

            // M20 fog: linear, warm, tuned so the panels at depth 10 are unfogged
            // and the far end of the bars (depth ~30) is fully fogged.
            var fog:Fog = new Fog(0x7a4326, 12, 30);
            _scene.fog = fog;

            var sun:DirectionalLight = new DirectionalLight(0xfff2e0, 2.4);
            sun.position.set(2, 3, 4);
            _scene.add(sun);
            _scene.add(new AmbientLight(0xffffff, 0.35));

            this._buildUnlitPanels();
            this._buildDrawRangePanel();
            this._buildBlendPanels();
            this._buildFogPanels();
            this._buildShadowPanels(sun);

            logLine("M20 A/B: MeshBasicMaterial.map set -> stripes, null -> flat gray "
                + "(map=" + this._stripes.image.width + "x" + this._stripes.image.height
                + ", colorSpace=" + this._stripes.colorSpace + ")");
            logLine("M20 E: Material.fog defaults to " + new MeshBasicMaterial().fog
                + "; the left fog bar sets material.fog = false to stay crisp");
        }

        // ------------------------------------------------------------------
        // A / B: MeshBasicMaterial.map.
        // ------------------------------------------------------------------
        private function _buildUnlitPanels():void
        {
            var withMap:MeshBasicMaterial = new MeshBasicMaterial();
            withMap.color.setHex(0xffffff);
            withMap.map = this._stripes;
            this._panel(-4.0, 3.0, withMap);

            var noMap:MeshBasicMaterial = new MeshBasicMaterial();
            noMap.color.setHex(0x808080);
            this._panel(0.0, 3.0, noMap);
        }

        // ------------------------------------------------------------------
        // F: geometry.drawRange trims the DRAW, not just the raycast.
        //
        // A 10x10 plane is 600 indices (200 triangles). The range stops after
        // 450 indices, i.e. 150 triangles, so the last 50 triangles are not
        // drawn and the background shows through there. PlaneGeometry emits its
        // indices row-major, so the bite is the trailing rows: the bottom 2.5
        // bands disappear, the last band only half-width (a staircase). Before
        // M20 the whole 200 triangles were drawn and the field only affected
        // picking.
        // ------------------------------------------------------------------
        private function _buildDrawRangePanel():void
        {
            var mat:MeshBasicMaterial = new MeshBasicMaterial();
            mat.map = this._stripes;
            var geo:PlaneGeometry = new PlaneGeometry(PANEL, PANEL, 10, 10);
            geo.setDrawRange(0, 450);

            var mesh:Mesh = new Mesh(geo, mat);
            mesh.position.set(4.0, 3.0, 1.0);
            _scene.add(mesh);

            logLine("M20 F: drawRange (0,450) of " + geo.index.count + " indices -> "
                + (450 / 3) + " of " + (geo.index.count / 3) + " triangles drawn");
        }

        // ------------------------------------------------------------------
        // D / E: the blend gate.
        //
        // Both quads are opacity 0.45 over the same bright bar. Only E declares
        // `transparent`, so only E is blended; D must come out fully opaque.
        // ------------------------------------------------------------------
        private function _buildBlendPanels():void
        {
            this._blendPanel(-4.0, 0.0, false);
            this._blendPanel(0.0, 0.0, true);
        }

        private function _blendPanel(x:Number, y:Number, transparent:Boolean):void
        {
            // The bar behind the quad: an unlit, fully opaque green plate WIDER
            // than the quad, so an opaque quad leaves a green border and a
            // blended quad shows olive fill -- readable at a glance.
            var barMat:MeshBasicMaterial = new MeshBasicMaterial();
            barMat.color.setHex(0x30ff90);
            var bar:Mesh = new Mesh(new PlaneGeometry(PANEL + 0.45, PANEL), barMat);
            bar.position.set(x, y, 0.9);

            _scene.add(bar);

            var mat:MeshBasicMaterial = new MeshBasicMaterial();
            mat.color.setHex(0xff3070);
            mat.opacity = 0.45;
            mat.transparent = transparent;
            var q:Mesh = this._panel(x, y, mat, 1.0);

        }

        // ------------------------------------------------------------------
        // G: fog on / off, two identical bars marching to z = -23.
        // ------------------------------------------------------------------
        private function _buildFogPanels():void
        {
            // Top: material.fog = true (fades into the fog colour).
            // Bottom: material.fog = false (stays crisp all the way down).
            this._fogBar(0.55, true);
            this._fogBar(-0.55, false);
        }

        private function _fogBar(y:Number, fog:Boolean):void
        {
            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(0x60c8ff);
            mat.roughness = 0.9;
            mat.metalness = 0.0;
            // M20: per-material fog opt-out (three.js Material.fog).
            mat.fog = fog;

            var mesh:Mesh = new Mesh(new BoxGeometry(0.45, 0.45, 24), mat);
            mesh.position.set(4.0, y, -11.0);
            _scene.add(mesh);
        }

        // ------------------------------------------------------------------
        // H: a hidden Group must not cast. Two identical wall+cube pairs; the
        // right cube lives in a Group with visible = false, so that wall must
        // stay clean. A shadow there is a phantom.
        // ------------------------------------------------------------------
        private function _buildShadowPanels(light:DirectionalLight):void
        {
            // Ortho box wide enough for both walls (the default is +-5).
            light.castShadow = true;
            light.shadow.camera.left = -8;
            light.shadow.camera.right = 8;
            light.shadow.camera.top = 8;
            light.shadow.camera.bottom = -8;
            light.shadow.normalBias = 0.02;
            light.shadow.bias = -0.0005;
            light.shadow.radius = 2;

            this._shadowPair(-1.6, true);
            this._shadowPair(1.6, false);
        }

        private function _shadowPair(x:Number, visible:Boolean):void
        {
            var wallMat:MeshStandardMaterial = new MeshStandardMaterial();
            wallMat.color.setHex(0xd8d8d8);
            wallMat.roughness = 1.0;
            wallMat.metalness = 0.0;
            var wall:Mesh = new Mesh(new PlaneGeometry(2.4, 2.0), wallMat);
            wall.position.set(x, -3.0, -0.2);
            wall.receiveShadow = true;
            _scene.add(wall);

            var cubeMat:MeshStandardMaterial = new MeshStandardMaterial();
            cubeMat.color.setHex(0xffc040);
            cubeMat.roughness = 0.7;
            cubeMat.metalness = 0.0;
            var cube:Mesh = new Mesh(new BoxGeometry(0.5, 0.5, 0.5), cubeMat);
            cube.position.set(x, -2.7, 0.7);
            cube.castShadow = true;
            cube.receiveShadow = true;

            if (visible)
            {
                _scene.add(cube);
            }
            else
            {
                // The caster is present and castShadow = true, but its parent is
                // invisible: the whole subtree leaves the shadow pass too.
                this._hidden = new Group();
                this._hidden.visible = false;
                this._hidden.add(cube);
                _scene.add(this._hidden);
                logLine("M20 H: the right caster sits in a Group with visible=false "
                    + "(cube.castShadow=" + cube.castShadow + ") -- its wall must stay clean");
            }
        }

        // ------------------------------------------------------------------
        // helpers
        // ------------------------------------------------------------------
        private function _panel(x:Number, y:Number, mat:MeshBasicMaterial, z:Number = 1.0):Mesh
        {
            var mesh:Mesh = new Mesh(new PlaneGeometry(PANEL, PANEL), mat);
            mesh.position.set(x, y, z);
            _scene.add(mesh);
            return mesh;
        }

        private function _makeTextured(bmp:BitmapData, space:String):Texture
        {
            var t:Texture = new Texture(bmp);
            t.colorSpace = space;
            return t;
        }

        // Vertical stripes: an obvious difference from a flat color.
        private function _makeStripes():BitmapData
        {
            var size:int = 64;
            var bmp:BitmapData = new BitmapData(size, size, false, 0xFF000000);
            var x:int;
            var y:int;
            for (y = 0; y < size; y++)
            {
                for (x = 0; x < size; x++)
                {
                    bmp.setPixel(x, y, ((x >> 3) & 1) == 0 ? 0xFFF0F0F0 : 0xFF2080C0);
                }
            }
            return bmp;
        }

        // 8x8 checker, the scene background.
        private function _makeChecker():BitmapData
        {
            var size:int = 64;
            var bmp:BitmapData = new BitmapData(size, size, false, 0xFF000000);
            var x:int;
            var y:int;
            for (y = 0; y < size; y++)
            {
                for (x = 0; x < size; x++)
                {
                    bmp.setPixel(x, y, (((x >> 3) + (y >> 3)) & 1) == 0 ? 0xFF14161C : 0xFF2A2F3A);
                }
            }
            return bmp;
        }
    }
}