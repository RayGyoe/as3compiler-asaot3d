// RenderStateM19.as -- M19 acceptance demo: the render-state fields really do
// something.
//
// Before M19 five Material fields and one Object3D field existed but nothing
// read them: the renderer wrote ONE culling / depth / blend state for a whole
// pass, and no sort key. The visible consequence was `Material.side`: a
// double-sided thin plate (what GLTFLoader sets for `doubleSided: true`) drew
// single-sided and vanished when seen from behind.
//
// Each panel is a minimal A/B probe of one field. The trace states the exact
// Stage3D call the renderer maps the field to, and the picture shows the
// consequence, so a screenshot is evidence instead of decoration.
//
//   A  plate turned away, MeshBasicMaterial(FrontSide)   -> back faces culled,
//                                                          only the backdrop
//   B  the same plate, DoubleSide                        -> plate visible
//   C  near red + far green, depthTest = false           -> GREEN (no test)
//   D  near red (depthWrite = false) + far green         -> GREEN (no write)
//      (with depth writing on, the near quad keeps depth and the far quad is
//       rejected, leaving RED -- that is the pre-M19 picture for both C and D)
//   E  three strips of the same quad over one backdrop:
//        NormalBlending (0.4) / AdditiveBlending (0.4) / NoBlending (0.4)
//   F  two coplanar quads, traversal order red-then-green with depthTest off
//        red.renderOrder = 1, green.renderOrder = -1  -> RED (green first)
//      (ignoring renderOrder leaves the traversal order, i.e. GREEN)
//   G  smooth sphere      H  the same sphere with flatShading = true
//   I  a wireframe sphere: `wireframe` draws the triangle edges (three.js
//      switches the rasterizer to LINES; Stage3D has none, so the edges are
//      expanded into screen-space quads -- see AGALRenderer._renderWireframe)
package
{
    import flash.display.BitmapData;

    import asaot.three.AGALRenderer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.Material;
    import asaot.three.materials.MeshBasicMaterial;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class RenderStateM19 extends Stage3DApp
    {
        private static const BACKDROP:uint = 0x303030;

        override protected function createScene():void
        {
            _scene = new Scene();
            _scene.background = new Color(0x101418);
            _camera = new PerspectiveCamera(55, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 11);

            var sun:DirectionalLight = new DirectionalLight(0xffffff, 2.0);
            sun.position.set(0.4, 0.5, 1);
            _scene.add(sun);
            _scene.add(new AmbientLight(0xffffff, 0.45));

            this._buildSidePanels();
            this._buildDepthPanels();
            this._buildBlendingPanel();
            this._buildRenderOrderPanel();
            this._buildShadingPanels();

            logLine("M19 side: FrontSide -> culling \"" + AGALRenderer.cullingFor(Material.FrontSide) + "\""
                + ", BackSide -> \"" + AGALRenderer.cullingFor(Material.BackSide) + "\""
                + ", DoubleSide -> \"" + AGALRenderer.cullingFor(Material.DoubleSide) + "\"");
            logLine("M19 depth: (test,write)=(true,true) -> setDepthTest("
                    + AGALRenderer.depthMaskFor(true, true) + ", \""
                    + AGALRenderer.depthCompareFor(true) + "\")"
                + "; (true,false) -> setDepthTest(" + AGALRenderer.depthMaskFor(true, false)
                    + ", \"" + AGALRenderer.depthCompareFor(true) + "\")"
                + "; (false,*) -> setDepthTest(" + AGALRenderer.depthMaskFor(false, true)
                    + ", \"" + AGALRenderer.depthCompareFor(false) + "\")");
            logLine("M19 blending: Normal -> (\"" + AGALRenderer.blendSrcFor(Material.NormalBlending)
                + "\", \"" + AGALRenderer.blendDstFor(Material.NormalBlending) + "\")"
                + "; Additive -> (\"" + AGALRenderer.blendSrcFor(Material.AdditiveBlending)
                + "\", \"" + AGALRenderer.blendDstFor(Material.AdditiveBlending) + "\")"
                + "; Multiply -> (\"" + AGALRenderer.blendSrcFor(Material.MultiplyBlending)
                + "\", \"" + AGALRenderer.blendDstFor(Material.MultiplyBlending) + "\")"
                + "; No -> (\"" + AGALRenderer.blendSrcFor(Material.NoBlending)
                + "\", \"" + AGALRenderer.blendDstFor(Material.NoBlending) + "\")");
        }

        // ------------------------------------------------------------------
        // A / B: Material.side on a plate that faces AWAY from the camera.
        // ------------------------------------------------------------------
        private function _buildSidePanels():void
        {
            this._backdrop(-6.2, 3.4);

            var front:Mesh = this._plate(-6.2, 3.4, Material.FrontSide, 0x40c0ff);
            _scene.add(front);
            logLine("M19 A: plate turned 180deg about Y with side=FrontSide (culling \""
                + AGALRenderer.cullingFor(front.material.side) + "\") -- only the backdrop shows");

            this._backdrop(0, 3.4);

            var both:Mesh = this._plate(0, 3.4, Material.DoubleSide, 0x40c0ff);
            _scene.add(both);
            logLine("M19 B: the same plate with side=DoubleSide (culling \""
                + AGALRenderer.cullingFor(both.material.side) + "\") -- the plate shows");
        }

        // A plate whose back faces the camera (rotated PI about Y).
        private function _plate(x:Number, y:Number, side:int, hex:uint):Mesh
        {
            var mat:MeshBasicMaterial = new MeshBasicMaterial();
            mat.color.setHex(hex);
            mat.side = side;
            var mesh:Mesh = new Mesh(new PlaneGeometry(2.2, 2.2, 1, 1), mat);
            mesh.position.set(x, y, 0.2);
            mesh.rotation.y = Math.PI;
            return mesh;
        }

        // ------------------------------------------------------------------
        // C / D: depth test and depth write.
        //
        // Both panels draw a NEAR red quad first and a FAR green quad second.
        // Whatever is on top in the picture is what the depth buffer allowed:
        //   default state        -> red wins (green rejected by lessEqual)
        //   depthTest = false    -> green wins (no test at all)
        //   depthWrite = false   -> green wins (the red quad left no depth)
        // ------------------------------------------------------------------
        private function _buildDepthPanels():void
        {
            var nearC:Mesh = this._flat(-6.2, 0.0, 0.30, 0xf03030);
            nearC.material.depthTest = false;
            _scene.add(nearC);
            _scene.add(this._flat(-6.2, 0.0, -0.20, 0x30e060));
            logLine("M19 C: depthTest=false on the near quad -> setDepthTest("
                + AGALRenderer.depthMaskFor(false, true) + ", \""
                + AGALRenderer.depthCompareFor(false) + "\") -> the far quad paints over it");

            var nearD:Mesh = this._flat(0.0, 0.0, 0.30, 0xf03030);
            nearD.material.depthWrite = false;
            _scene.add(nearD);
            _scene.add(this._flat(0.0, 0.0, -0.20, 0x30e060));
            logLine("M19 D: depthWrite=false on the near quad -> setDepthTest("
                + AGALRenderer.depthMaskFor(true, false) + ", \""
                + AGALRenderer.depthCompareFor(true) + "\") -> the far quad still passes");
        }

        // ------------------------------------------------------------------
        // E: Material.blending, three strips of the same quad over one backdrop.
        // ------------------------------------------------------------------
        private function _buildBlendingPanel():void
        {
            this._backdrop(6.2, 0.0);

            // Left strip: NormalBlending (the default) at 40% opacity.
            _scene.add(this._strip(6.2 - 0.72, 0.0, Material.NormalBlending));
            // Middle strip: AdditiveBlending -- adds its light instead of
            // replacing, so the backdrop gets BRIGHTER than the normal strip.
            _scene.add(this._strip(6.2, 0.0, Material.AdditiveBlending));
            // Right strip: NoBlending -- alpha is ignored entirely, so the strip
            // is fully opaque even at opacity 0.4.
            _scene.add(this._strip(6.2 + 0.72, 0.0, Material.NoBlending));

            logLine("M19 E: strips at opacity 0.4 -- normal blends, additive brightens, "
                + "NoBlending ignores alpha (opaque)");
        }

        private function _strip(x:Number, y:Number, blending:int):Mesh
        {
            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(0xff40c0);
            mat.roughness = 1.0;
            mat.metalness = 0.0;
            mat.opacity = 0.4;
            mat.transparent = true;
            mat.blending = blending;
            // Every strip keeps the default depth state: the panel is about
            // blending only, so the strips must not occlude each other by depth.
            mat.depthWrite = false;
            var mesh:Mesh = new Mesh(new PlaneGeometry(0.7, 2.2, 1, 1), mat);
            mesh.position.set(x, y, 0.2);
            return mesh;
        }

        // ------------------------------------------------------------------
        // F: Object3D.renderOrder.
        //
        // The red quad is added FIRST but declares renderOrder = 1, so the
        // renderer must sort it after the green one (renderOrder = -1) and the
        // red paints last. Depth test is off so only order decides the picture:
        // RED means ordering worked, GREEN means the traversal order leaked
        // through (the pre-M19 behaviour).
        // ------------------------------------------------------------------
        private function _buildRenderOrderPanel():void
        {
            var red:Mesh = this._flat(-6.2, -3.4, 0.0, 0xf03030);
            red.material.depthTest = false;
            red.renderOrder = 1;
            _scene.add(red);

            var green:Mesh = this._flat(-6.2, -3.4, 0.0, 0x30e060);
            green.material.depthTest = false;
            green.renderOrder = -1;
            _scene.add(green);

            logLine("M19 F: red added first with renderOrder=1, green second with "
                + "renderOrder=-1 (opaque sort key = " + AGALRenderer.renderOrderOf(red)
                + " vs " + AGALRenderer.renderOrderOf(green) + ") -> red ends on top");
        }

        // ------------------------------------------------------------------
        // G / H / I: flatShading and wireframe.
        // ------------------------------------------------------------------
        private function _buildShadingPanels():void
        {
            _scene.add(this._litSphere(0.0, -3.4, false));
            _scene.add(this._litSphere(6.2 - 2.4, -3.4, true));

            var wireMat:MeshBasicMaterial = new MeshBasicMaterial();
            wireMat.color.setHex(0x9fd8ff);
            wireMat.wireframe = true;
            wireMat.wireframeLinewidth = 1;
            var wire:Mesh = new Mesh(new SphereGeometry(1.15, 12, 8), wireMat);
            wire.position.set(6.2, -3.4, 0.0);
            _scene.add(wire);

            logLine("M19 G/H: sphere 12x8 -- left flatShading=false (" + AGALRenderer.flatShadingOf(this._sphereMat(false))
                + "), right flatShading=true (" + AGALRenderer.flatShadingOf(this._sphereMat(true)) + ")");
            logLine("M19 I: wireframe sphere: " + (wire.geometry.index.count / 3) + " triangles -> "
                + (wire.geometry.index.count) + " edge quads, half width "
                + AGALRenderer.wireframeHalfWidth(wireMat) + "px");
        }

        private var _smoothMat:MeshStandardMaterial;
        private var _flatMat:MeshStandardMaterial;

        private function _sphereMat(flat:Boolean):MeshStandardMaterial
        {
            if (flat) return this._flatMat;
            return this._smoothMat;
        }

        private function _litSphere(x:Number, y:Number, flat:Boolean):Mesh
        {
            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(0xdfe8f2);
            mat.roughness = 0.55;
            mat.metalness = 0.0;
            mat.flatShading = flat;
            if (flat) this._flatMat = mat;
            else this._smoothMat = mat;
            var mesh:Mesh = new Mesh(new SphereGeometry(1.15, 12, 8), mat);
            mesh.position.set(x, y, 0.0);
            return mesh;
        }

        // ------------------------------------------------------------------
        // helpers
        // ------------------------------------------------------------------

        private function _flat(x:Number, y:Number, z:Number, hex:uint):Mesh
        {
            var mat:MeshBasicMaterial = new MeshBasicMaterial();
            mat.color.setHex(hex);
            var mesh:Mesh = new Mesh(new PlaneGeometry(2.2, 2.2, 1, 1), mat);
            mesh.position.set(x, y, z);
            return mesh;
        }

        private function _backdrop(x:Number, y:Number):void
        {
            var mat:MeshBasicMaterial = new MeshBasicMaterial();
            mat.color.setHex(BACKDROP);
            var mesh:Mesh = new Mesh(new PlaneGeometry(2.4, 2.4, 1, 1), mat);
            mesh.position.set(x, y, -0.6);
            _scene.add(mesh);
        }
    }
}