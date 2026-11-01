// TexStateM17.as -- M17 acceptance demo: the Texture state fields that used to be
// inert now change the picture, and the change is visible in one frame.
//
// Before M17 the AGAL sampler was hard-coded `<2d,clamp,linear,mipnone>` and the
// upload ignored flipY/colorSpace, so of the five quads below only E would have
// looked right:
//
//   A  uvgrid, default state           -- flipY proof: the gradient's green
//                                         channel grows toward the image TOP, so
//                                         a correct upload shows green at the top
//                                         edge and near-black at the bottom. A
//                                         wrongly-oriented upload shows the
//                                         vertical gradient reversed.
//   B  uvgrid, RepeatWrapping, uv x4   -- wrap proof: four tiles per axis. With
//                                         the old hard-coded `clamp` this was one
//                                         stretched copy with the border smeared.
//   C  uvgrid, RepeatWrapping, uv x32, at z=-6
//                                      -- mip proof: 32 tiles squeezed into ~90 px
//                                         aliases into noise without a mip chain,
//                                         and resolves to a smooth blend with one.
//   D  flat 0x808080 sRGB texture map  -- color-space proof: see below.
//   E  flat 0x808080 material color    -- color-space proof: D and E must match.
//
// D vs E is the decisive one. `Color.setHex` decodes sRGB to the linear working
// space (D30) and every program re-encodes on output (R7), so a material COLOR of
// 0x808080 round-trips to 0x808080. A map declared SRGBColorSpace has to be
// decoded the same way before lighting; without that decode its texels entered
// the math as if linear, the output encode applied the curve a SECOND time, and D
// came out visibly brighter than E (pow(0.502, 1/2.2) = 0.73 instead of 0.502).
package
{
    import flash.display.BitmapData;

    import asaot.three.AGALRenderer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.BufferAttribute;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.loaders.TextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class TexStateM17 extends Stage3DApp
    {
        private var _uvTexture:Texture;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 7);

            // Head-on light so D and E (and every quad) receive identical
            // irradiance; the comparison must not depend on shading variation.
            var sun:DirectionalLight = new DirectionalLight(0xffffff, 2.2);
            sun.position.set(0, 0, 1);
            _scene.add(sun);
            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.35);
            _scene.add(ambient);

            var loader:TextureLoader = new TextureLoader();
            loader.load("app:/assets/textures/uvgrid.png", onUVGrid, null, onLoadError);
        }

        private function onLoadError(e:Object):void
        {
            logLine("M17 asset load error: " + e);
        }

        private function onUVGrid(loaded:Texture):void
        {
            _uvTexture = loaded;
            // uvgrid is a color gradient (red = +u, green = +v), i.e. sRGB data,
            // so it declares SRGBColorSpace like any glTF baseColorTexture.
            _uvTexture.colorSpace = Texture.SRGBColorSpace;

            // --- A: default state, one copy --------------------------------
            _scene.add(this._quad(0.0, 0.0, 0, 0.0, _uvTexture));

            // --- B: 4x tiling (REPEAT + uv scale) --------------------------
            var tiled:Texture = this._retexture(_uvTexture);
            tiled.wrapS = Texture.RepeatWrapping;
            tiled.wrapT = Texture.RepeatWrapping;
            _scene.add(this._quad(-3.2, 2.0, 0.0, 4.0, tiled));

            // --- C: 32x tiling, far away (minification -> mip chain) -------
            var minified:Texture = this._retexture(_uvTexture);
            minified.wrapS = Texture.RepeatWrapping;
            minified.wrapT = Texture.RepeatWrapping;
            _scene.add(this._quad(3.2, 2.0, -6.0, 32.0, minified));

            // --- D: sRGB texture of the SAME gray as E's material color ----
            var grayTex:Texture = new Texture(this._makeFlat(0x808080));
            grayTex.colorSpace = Texture.SRGBColorSpace;
            // 8x8: a chain would be pointless, and declaring mips the texture
            // cannot back would make AIR drop the draw (mipFilterFor guards it).
            grayTex.generateMipmaps = false;
            grayTex.minFilter = Texture.LinearFilter;
            _scene.add(this._quad(-1.7, -2.0, 0.0, 1.0, grayTex));

            // --- E: the same gray as a flat material color -----------------
            _scene.add(this._quad(1.7, -2.0, 0.0, 0.0, null));

            logLine("M17 demo: uvgrid " + _uvTexture.image.width + "x" + _uvTexture.image.height
                + " colorSpace=" + _uvTexture.colorSpace
                + " flipY=" + _uvTexture.flipY
                + " minFilter=" + _uvTexture.minFilter
                + " mip=" + AGALRenderer.mipFilterFor(_uvTexture.minFilter, _uvTexture.generateMipmaps)
                + " levels=" + AGALRenderer.mipLevelCount(_uvTexture.image.width, _uvTexture.image.height));
            logLine("M17 gray: sRGB texel 0x808080 -> linear " + Math.pow(0x80 / 255, 2.2)
                + " (no decode would leave it at " + (0x80 / 255)
                + ", and the output encode would then map it to " + Math.pow(0x80 / 255, 1 / 2.2) + ")");
        }

        // A quad facing the camera. `map` null means "flat 0x808080 material".
        private function _quad(x:Number, y:Number, z:Number, uvScale:Number, map:Texture):Mesh
        {
            var geo:PlaneGeometry = new PlaneGeometry(2.4, 2.4, 1, 1);
            if (uvScale > 0)
            {
                // Tile by scaling the uv attribute: our map path has no
                // texture.matrix/offset yet, so the geometry carries the scale.
                var uv:BufferAttribute = geo.getAttribute("uv");
                var i:int;
                for (i = 0; i < uv.count; i++)
                {
                    uv.setXY(i, uv.getX(i) * uvScale, uv.getY(i) * uvScale);
                }
            }

            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            // A mapped quad keeps a WHITE base color, because the map owns the
            // albedo: diffuseColor = baseColor * texel (map_fragment.glsl.js:14),
            // so a gray base color would multiply the gray texel down to
            // 0x808080^2 and D could never match E.
            mat.color.setHex(map == null ? 0x808080 : 0xffffff);
            mat.roughness = 1.0;
            mat.metalness = 0.0;
            mat.map = map;

            var mesh:Mesh = new Mesh(geo, mat);
            mesh.position.set(x, y, z);
            return mesh;
        }

        // A second Texture over the SAME BitmapData: the wrap/filter state lives
        // on the Texture, so tiling needs its own object while the pixels are
        // shared.
        private function _retexture(src:Texture):Texture
        {
            var t:Texture = new Texture(src.image);
            t.colorSpace = Texture.SRGBColorSpace;
            return t;
        }

        private function _makeFlat(hex:uint):BitmapData
        {
            var bmp:BitmapData = new BitmapData(8, 8, false, 0xFF000000 | hex);
            return bmp;
        }
    }
}