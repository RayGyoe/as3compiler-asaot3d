// AlphaM10.as -- M10 acceptance demo: tone mapping + alpha blending + alpha test.
//
// Four features in one frame, each with a visible failure mode:
//
//   1. ALPHA BLEND (right third). Three tinted glass boxes overlap in depth
//      (z = +0.6, 0.0, -0.6). They are `transparent = true` with opacity 0.35,
//      so the renderer draws them in its transparent pass, back-to-front, with
//      sourceAlpha/oneMinusSourceAlpha and no depth write. Drawn in the wrong
//      order the overlaps mix differently -- red-over-green is not
//      green-over-red -- so the acceptance shot pins the ordering.
//
//   2. ALPHA TEST (left). A cutout panel in front of the backdrop: a
//      procedurally generated ring/disc BitmapData with fully transparent
//      corners, `alphaTest = 0.5`. The discarded texels must show the backdrop
//      behind the panel, not a black or white quad.
//
//   3. TONE MAPPING (centre/left, and the whole frame). The key light is
//      deliberately over-driven (intensity 6) so the lit side of the sphere and
//      panel is far above 1.0 in linear space. With NoToneMapping those areas
//      clip to flat white; with ACESFilmicToneMapping they roll off and keep
//      gradient. A/B: flip TONE_MODE to 0 and rebuild.
//
//   4. MSAA (opt-in, no code change): launch with ASC_S3D_MSAA=4 and the
//      silhouette edges get 4 samples. Off by default, because AIR's Stage3D
//      has no such knob and the default must stay AIR-equivalent.
package
{
    import flash.display.BitmapData;

    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class AlphaM10 extends Stage3DApp
    {
        // 0 = NoToneMapping, 2 = ACESFilmicToneMapping. The A/B for the
        // acceptance shot is this single constant (rebuild between shots).
        private static const TONE_MODE:int = 2;

        override protected function createScene():void
        {
            // M10: the two knobs under test. `toneMapping` is baked into the
            // fragment programs, so it must be set BEFORE the first render
            // (the renderer rebuilds lazily, but a demo that never changes it
            // pays nothing either way).
            _renderer.toneMapping = TONE_MODE;
            _renderer.toneMappingExposure = 1.0;

            _scene = new Scene();

            // Fixed camera: the acceptance shot is compared pixel-to-pixel
            // between the two tone-mapping runs, so nothing may move.
            _camera = new PerspectiveCamera(38, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0.55, 7.2);
            _camera.lookAt(0, 0.45, 0);

            // Dim ambient so nothing is pure black, plus an over-driven key
            // light: intensity 6 puts the lit side well above 1.0 linear, which
            // is what makes the tone-mapping A/B observable.
            var ambient:AmbientLight = new AmbientLight(0x223344, 0.6);
            _scene.add(ambient);

            var key:DirectionalLight = new DirectionalLight(0xfff2e0, 6.0);
            key.position.set(3.5, 5.0, 5.0);
            _scene.add(key);

            // Backdrop: an opaque dark panel every other object is read against.
            var backdrop:MeshStandardMaterial = new MeshStandardMaterial();
            backdrop.color.setHex(0x2a3340);
            backdrop.roughness = 0.9;
            backdrop.metalness = 0.0;
            var backPanel:Mesh = new Mesh(new PlaneGeometry(14, 8, 1, 1), backdrop);
            backPanel.position.set(0, 0.5, -3.2);
            _scene.add(backPanel);

            // --- 2. alpha test: cutout panel -----------------------------------
            var cutout:MeshStandardMaterial = new MeshStandardMaterial();
            cutout.color.setHex(0x8fe0c0);
            cutout.roughness = 0.55;
            cutout.metalness = 0.0;
            cutout.map = new Texture(_makeCutout(256, 256));
            cutout.alphaTest = 0.5;
            // Single-sided is the interesting case: the discarded texels must
            // reveal the backdrop, so the panel cannot simply be see-through.
            var panel:Mesh = new Mesh(new PlaneGeometry(2.2, 2.2, 1, 1), cutout);
            panel.position.set(-2.05, 0.55, 0.2);
            _scene.add(panel);

            // --- 1. tone mapping: an over-driven sphere ------------------------
            var hot:MeshStandardMaterial = new MeshStandardMaterial();
            hot.color.setHex(0xffd9a0);
            hot.roughness = 0.28;
            hot.metalness = 0.0;
            var hotSphere:Mesh = new Mesh(new SphereGeometry(0.85, 48, 32), hot);
            hotSphere.position.set(-0.55, 0.5, 0.9);
            _scene.add(hotSphere);

            // --- 3. alpha blend: three overlapping glass boxes -----------------
            // Depths are chosen so the LARGEST z (nearest the camera) is added
            // last: red (+0.9) is nearest, then green (0.0), then blue (-0.9).
            // A back-to-front pass therefore composites blue, green, red.
            var glassRed:MeshStandardMaterial = _makeGlass(0xff5566, 0.35);
            var glassGreen:MeshStandardMaterial = _makeGlass(0x55ff88, 0.35);
            var glassBlue:MeshStandardMaterial = _makeGlass(0x5588ff, 0.35);

            var box:BoxGeometry = new BoxGeometry(1.1, 1.1, 1.1);
            var zs:Array = [0.9, 0.0, -0.9];
            var mats:Array = [glassRed, glassGreen, glassBlue];
            var xs:Array = [1.45, 2.05, 2.65];
            var i:int;
            for (i = 0; i < 3; i++)
            {
                var glass:Mesh = new Mesh(box, mats[i] as MeshStandardMaterial);
                glass.position.set(xs[i] as Number, 0.5, zs[i] as Number);
                _scene.add(glass);
            }

            logLine("M10 demo: toneMapping=" + _renderer.toneMapping
                + " exposure=" + _renderer.toneMappingExposure
                + " alphaTest=" + cutout.alphaTest
                + " transparent objects=3");
        }

        private function _makeGlass(color:uint, opacity:Number):MeshStandardMaterial
        {
            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(color);
            mat.roughness = 0.12;
            mat.metalness = 0.0;
            mat.transparent = true;
            mat.opacity = opacity;
            // three.js leaves depthWrite on for the default material and the
            // glTF loader turns it off for BLEND; a stack of overlapping glass
            // needs it off, otherwise the nearest panes occlude the far ones and
            // blending degenerates into "whichever drew first wins".
            mat.depthWrite = false;
            return mat;
        }

        // A ring + disc mask with fully transparent corners: the classic
        // cutout. alphaTest 0.5 keeps the disc, discards the corners.
        private function _makeCutout(w:int, h:int):BitmapData
        {
            var bmp:BitmapData = new BitmapData(w, h, true, 0x00000000);
            var cx:Number = w * 0.5;
            var cy:Number = h * 0.5;
            var outer:Number = w * 0.46;
            var inner:Number = w * 0.26;
            var y:int;
            var x:int;
            for (y = 0; y < h; y++)
            {
                for (x = 0; x < w; x++)
                {
                    var dx:Number = x - cx;
                    var dy:Number = y - cy;
                    var r:Number = Math.sqrt(dx * dx + dy * dy);
                    // Outer disc: 8 spokes cut out of the ring so the backdrop
                    // shows through in a pattern that is obvious at any zoom.
                    var inRing:Boolean = r <= outer && r >= inner;
                    var spoke:Boolean = false;
                    if (inRing)
                    {
                        var ang:Number = Math.atan2(dy, dx);
                        var sector:Number = Math.floor((ang + Math.PI) / (Math.PI / 6));
                        if (int(sector) % 2 == 1) spoke = true;
                    }
                    var solid:Boolean = (r < inner) || (inRing && !spoke);
                    if (solid)
                    {
                        // Greenish with a soft radial shade so the panel is not flat.
                        var shade:int = 160 + int(80 * (1 - r / outer));
                        bmp.setPixel32(x, y, 0xFF000000 | (shade << 8) | (shade << 16) | 0x60);
                    }
                    else
                    {
                        bmp.setPixel32(x, y, 0x00000000);
                    }
                }
            }
            return bmp;
        }
    }
}