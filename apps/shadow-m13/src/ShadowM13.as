// ShadowM13.as -- M13 shadow-quality demo.
//
// Four things M7 could not show, in one frame:
//
//   1. PCF radius: the shadow edge is a 3x3 tap average scaled by
//      DirectionalLightShadow.radius, so the boundary is a gradient instead of
//      one texel of hard edge.
//   2. normalBias: the torus is a curved, low-poly surface, the classic acne
//      case. Offsetting the RECEIVER along its normal before projecting into
//      shadow space (three.js shadowmap_vertex) removes the stripes without the
//      constant depth offset that bias applies -- which would detach the
//      contact shadow.
//   3. alphaTest cutout casters: the plate on the left carries a base-color map
//      with transparent windows and alphaTest = 0.5, so it casts a shadow with
//      matching holes instead of a solid rectangle.
//   4. two directional lights holding ONE shadow map: the warm key casts, the
//      cool fill lights the shaded side without casting (D93: the eight AGAL
//      sampler units are fully spent by the standard material, so a second
//      shadow map has no unit to sample from).
package
{
    import flash.display.BitmapData;

    import asaot.three.AGALRenderer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.TorusGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class ShadowM13 extends Stage3DApp
    {
        private var _torus:Mesh;
        private var _plate:Mesh;
        private var _key:DirectionalLight;
        private var _fill:DirectionalLight;
        // Freeze the turntable so A/B screenshots of shadow settings compare the
        // same pose. Flip to false for the moving demo.
        private static const ANIMATE:Boolean = true;
        private var _frames:int = 0;

        // PCF kernel radius in shadow-map texels (LightShadow.radius). 2 spreads
        // the 3x3 taps over two texels, i.e. a ~5-texel-wide penumbra.
        // Measured on the frozen pose against the same scene with no shadow at
        // all (temp/m13-f-*.png): the share of torus pixels that were wrongly
        // self-shadowed was 34.5% at normalBias 0, 14.1% at bias 0, and 2.6%
        // here -- i.e. the remaining darkening is genuine self-occlusion.
        private static const RADIUS:Number = 2;
        // Receiver offset along its own normal, in world units. The torus tube
        // radius is 0.45, so 0.02 is ~4% of the local geometry -- enough to clear
        // one 8-bit depth step without visibly floating the shadow.
        private static const NORMAL_BIAS:Number = 0.02;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(55, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 5.5, 12);
            _camera.lookAt(0, 1.6, 0);

            // ---- ground: the shadow receiver -------------------------------
            var groundMat:MeshStandardMaterial = new MeshStandardMaterial();
            groundMat.color.setHex(0x8f9099);
            groundMat.roughness = 0.95;
            groundMat.metalness = 0.0;
            var ground:Mesh = new Mesh(new PlaneGeometry(24, 24), groundMat);
            ground.rotation.x = -1.5707963267948966; // -PI/2
            ground.receiveShadow = true;
            _scene.add(ground);

            // ---- torus: curved caster, the acne test case ------------------
            var torusMat:MeshStandardMaterial = new MeshStandardMaterial();
            torusMat.color.setHex(0xd98d4a);
            torusMat.roughness = 0.5;
            torusMat.metalness = 0.1;
            _torus = new Mesh(new TorusGeometry(1.3, 0.45, 20, 44), torusMat);
            _torus.position.set(0.6, 2.9, 0);
            _torus.castShadow = true;
            _torus.receiveShadow = true;
            _scene.add(_torus);

            // ---- cutout plate: alphaTest caster ----------------------------
            var plateMat:MeshStandardMaterial = new MeshStandardMaterial();
            plateMat.color.setHex(0xdfe3ea);
            plateMat.roughness = 0.7;
            plateMat.metalness = 0.0;
            plateMat.map = makeCutoutTexture();
            // The whole point of M13's cutout path: the plate's shadow has the
            // same holes as the plate (three.js renders casters with a depth
            // material carrying alphaTest/alphaMap, D89).
            plateMat.alphaTest = 0.5;
            // A thin BOX, not a plane: the shadow pass culls front faces, so a
            // single-sided plane seen from the light writes no depth at all.
            _plate = new Mesh(new BoxGeometry(3.4, 3.4, 0.12), plateMat);
            // Laid FLAT and hovering, so its shadow lands on the ground face-on
            // and the four cut-out windows are readable in the projection (a
            // vertical plate's shadow is compressed along the light's azimuth).
            _plate.rotation.x = -1.5707963267948966;
            _plate.position.set(-3.4, 4.2, -0.4);
            _plate.castShadow = true;
            // Receivers, not just casters: without this the torus would not be
            // shaded by its own ring and the acne test would be vacuous.
            _plate.receiveShadow = true;
            _scene.add(_plate);

            // ---- lights ---------------------------------------------------
            var ambient:AmbientLight = new AmbientLight(0x5a5f70, 0.30);
            _scene.add(ambient);

            // Warm key: the only shadow caster.
            _key = new DirectionalLight(0xfff2e0, 1.15);
            _key.position.set(6, 10, 4.5);
            _key.castShadow = true;
            _key.shadow.radius = RADIUS;
            _key.shadow.normalBias = NORMAL_BIAS;
            // Negative bias: fc9.x is ADDED to the receiver's shadow-space depth,
            // so a positive value increases occlusion (acne). M13 stores the
            // shadow depth as two base-255 digits, so one step is ~0.0006 world
            // units over this camera's 0.5..40 range instead of the 0.155 that
            // a raw 8-bit channel would give -- which is why this scene needs
            // only -0.002 (a 3-step safety margin for slope error) where the M7
            // raw-depth path needed -0.004.
            _key.shadow.bias = -0.002;
            _key.shadow.camera.near = 0.5;
            _key.shadow.camera.far = 40;
            _key.shadow.camera.left = -9;
            _key.shadow.camera.right = 9;
            _key.shadow.camera.top = 9;
            _key.shadow.camera.bottom = -9;
            _key.shadow.camera.updateProjectionMatrix();
            _scene.add(_key);
            _scene.add(_key.target);

            // Cool fill: a second directional light, no shadow (D93). It lights
            // the side the key does not reach, which is what proves the base pass
            // is summing two lights rather than one.
            _fill = new DirectionalLight(0x7f9bff, 0.45);
            _fill.position.set(-7, 4, -6);
            _fill.castShadow = false;
            _scene.add(_fill);
            _scene.add(_fill.target);

            logLine("M13 demo: key radius=" + _key.shadow.radius + " normalBias=" +
                  _key.shadow.normalBias + " bias=" + _key.shadow.bias +
                  "; cutout plate alphaTest=" + plateMat.alphaTest);
            logLine("M13 demo: caps MAX_DIR_LIGHTS=" + AGALRenderer.MAX_DIR_LIGHTS +
                  " MAX_SHADOW_LIGHTS=" + AGALRenderer.MAX_SHADOW_LIGHTS +
                  " PCF_TAPS=" + AGALRenderer.PCF_TAPS);
        }

        // 64x64 plate texture: an opaque card with four transparent windows. The
        // plate material treats it as a CUTOUT (alphaTest), so the windows are
        // holes in the geometry's coverage -- both in the colour pass and in the
        // shadow map.
        private function makeCutoutTexture():Texture
        {
            var size:int = 64;
            // Transparent BitmapData: the windows must be alpha 0, not black. A
            // non-transparent surface silently forces alpha to 255 on every
            // pixel, which makes alphaTest() above useless -- the plate would
            // render its windows as black squares and cast a solid shadow.
            var bmp:BitmapData = new BitmapData(size, size, true, 0x00000000);
            var py:int;
            var px:int;
            for (py = 0; py < size; py++)
            {
                for (px = 0; px < size; px++)
                {
                    var inX:Boolean = (px >= 8 && px < 24) || (px >= 32 && px < 48);
                    var inY:Boolean = (py >= 8 && py < 24) || (py >= 32 && py < 48);
                    if (inX && inY) bmp.setPixel32(px, py, 0x00000000);
                    else bmp.setPixel32(px, py, 0xF0E8ECF2);
                }
            }
            return new Texture(bmp);
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frames++;
            // Slow spin: the torus silhouette sweeps across its own shadow,
            // which is what makes acne (if any) and the penumbra readable.
            // ANIMATE = false holds the pose so screenshots of different shadow
            // settings are pixel-comparable.
            if (ANIMATE)
            {
                _torus.rotation.y += 0.012;
                _torus.rotation.x += 0.006;
                _plate.rotation.z = 0.25 * Math.sin(_frames * 0.01);
            }
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_frames == 1)
            {
                logLine("M13 demo frame 1 rendered (PCF radius " + _key.shadow.radius + ")");
            }
        }
    }
}