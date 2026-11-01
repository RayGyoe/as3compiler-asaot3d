// UVM18.as -- M18 acceptance demo: the uv transform actually transforms.
//
// Before M18 `Texture.offset/repeat/rotation/center/matrix` did not exist, so
// the only way to tile a map was to scale the geometry's uv attribute (which is
// what TexStateM17's quad B does, and what every ported snippet would have to
// do by hand). three.js instead multiplies the uv by a per-map mat3 in the
// vertex shader (uv_vertex.glsl.js: `vMapUv = (mapTransform * vec3(uv,1)).xy`),
// built from those four fields by Texture.updateMatrix().
//
// Every quad below uses the SAME PlaneGeometry with the SAME untouched uv
// attribute (0..1). Only Texture state differs, so anything that looks tiled,
// shifted, rotated or mirrored is the transform:
//
//   A  repeat (1,1)                       -- one copy, the reference.
//   B  repeat (4,4) + RepeatWrapping      -- 4x4 tiles, geometry untouched.
//   C  repeat (1,1) + offset (0.5,-0.25)  -- the gradient starts a half tile in.
//   D  rotation PI/4, center (0.5,0.5)    -- rotates about the tile centre (a
//                                            rotation about (0,0) would swing it
//                                            off the quad entirely).
//   E  matrixAutoUpdate=false + a hand-written matrix with scale (-1,1)
//                                         -- MIRRORED. This is the case
//                                            `texture.repeat` cannot express: a
//                                            negative scale is not a tiling
//                                            count, so the manual matrix is the
//                                            only path.
//   F  map repeat (1,1) + emissiveMap repeat (3,3)
//                                         -- per-slot transforms: the base
//                                            gradient stays single-copy while
//                                            the emissive glow tiles 3x3.
package
{
    import flash.display.BitmapData;

    import asaot.three.AGALRenderer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.loaders.TextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.Texture;

    public class UVM18 extends Stage3DApp
    {
        private var _uvGrid:Texture;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 10);

            var sun:DirectionalLight = new DirectionalLight(0xffffff, 2.2);
            sun.position.set(0, 0, 1);
            _scene.add(sun);
            _scene.add(new AmbientLight(0xffffff, 0.35));

            var loader:TextureLoader = new TextureLoader();
            loader.load("app:/assets/textures/uvgrid.png", onUVGrid, null, onLoadError);
        }

        private function onLoadError(e:Object):void
        {
            logLine("M18 asset load error: " + e);
        }

        private function onUVGrid(loaded:Texture):void
        {
            _uvGrid = loaded;
            _uvGrid.colorSpace = Texture.SRGBColorSpace;

            // --- A: reference copy -----------------------------------------
            _scene.add(this._quad(-3.2, 2.0, 0.0, this._tex(1.0, 1.0, 0.0, 0.0, false)));

            // --- B: 4x4 tiles from repeat alone ----------------------------
            var tiled:Texture = this._tex(4.0, 4.0, 0.0, 0.0, false);
            _scene.add(this._quad(0.0, 2.0, 0.0, tiled));

            // --- C: offset -----------------------------------------------
            // RepeatWrapping so the shift is a wrap, not a clamp smear: with
            // offset 0.5 alone the sample runs off the right edge and the whole
            // right half would read the same edge texel, which a broken sampler
            // would reproduce just as well. Wrapping puts the seam at exactly
            // u = 0.5 of the quad, which is the number the screenshot can check.
            var shifted:Texture = this._tex(1.0, 1.0, 0.5, 0.0, true);
            _scene.add(this._quad(3.2, 2.0, 0.0, shifted));

            // --- D: rotation about the tile centre ------------------------
            var rotated:Texture = this._tex(1.0, 1.0, 0.0, 0.0, false, Math.PI / 4, 0.5, 0.5);
            _scene.add(this._quad(-3.2, -1.6, 0.0, rotated));

            // --- E: hand-written matrix (mirror, matrixAutoUpdate = false) --
            // A negative scale is a MIRROR, which `repeat` cannot express (repeat
            // is a tiling count). RepeatWrapping is what makes the mirror visible:
            // with clamp the negative uv would collapse onto the edge texel.
            var mirrored:Texture = this._tex(1.0, 1.0, 0.0, 0.0, true);
            mirrored.matrixAutoUpdate = false;
            mirrored.matrix.setUvTransform(0, 0, -1, 1, 0, 0, 0);
            _scene.add(this._quad(0.0, -1.6, 0.0, mirrored));

            // --- F: two slots, two transforms -----------------------------
            // Flat dark base (one copy) + a 3x3 tiled EMISSIVE map: the emissive
            // slot's transform alone decides the pattern, so a renderer that
            // shared one uv between the slots would show a single copy.
            var flatBase:Texture = new Texture(this._makeFlat(0x404040));
            flatBase.generateMipmaps = false;
            flatBase.minFilter = Texture.LinearFilter;
            var multi:Mesh = this._quad(3.2, -1.6, 0.0, flatBase);
            var emissive:Texture = this._tex(3.0, 3.0, 0.0, 0.0, false);
            var multiMat:MeshStandardMaterial = MeshStandardMaterial(multi.material);
            multiMat.emissiveMap = emissive;
            multiMat.emissive.setHex(0xffffff);
            _scene.add(multi);

            // updateMatrix() is what folds offset/repeat/rotation/center into
            // `matrix`; the renderer calls it per draw while matrixAutoUpdate is
            // true (three.js refreshTransformUniform), so at this point the field
            // is still identity for every texture above. Call it explicitly here
            // so the trace below prints the matrix the first draw will use.
            tiled.updateMatrix();
            shifted.updateMatrix();
            rotated.updateMatrix();

            // Trace the resolved matrices: a probe/screenshot pair is only
            // evidence if the numbers behind the picture are stated.
            logLine("M18 tiled: repeat=" + tiled.repeat.x + "x" + tiled.repeat.y
                + " matrix=[" + tiled.matrix.elements.join(", ") + "]");
            logLine("M18 shifted: offset=" + shifted.offset.x + "," + shifted.offset.y
                + " matrix=[" + shifted.matrix.elements.join(", ") + "]");
            logLine("M18 rotated: rotation=" + rotated.rotation + " center=" + rotated.center.x + "," + rotated.center.y
                + " matrix=[" + rotated.matrix.elements.join(", ") + "]");
            logLine("M18 mirrored (matrixAutoUpdate=false): matrix=[" + mirrored.matrix.elements.join(", ") + "]");
            logLine("M18 uv rows for the tiled map: " + this._rows(tiled));
            logLine("M18 uv rows for the emissive map: " + this._rows(emissive));
            logLine("M18 uv rows for the untouched flat base: " + this._rows(flatBase));
            logLine("M18 matrixAutoUpdate is still true (three.js updateMatrix does not clear it): "
                + tiled.matrixAutoUpdate);
        }

        private function _makeFlat(hex:uint):BitmapData
        {
            return new BitmapData(8, 8, false, 0xFF000000 | hex);
        }

        private function _rows(t:Texture):String
        {
            var out:Vector.<Number> = new Vector.<Number>(8);
            AGALRenderer.uvRowsInto(out, 0, AGALRenderer.uvMatrixOf(t));
            return "[" + out[0] + ", " + out[1] + ", " + out[2] + ", " + out[3] + "] ["
                + out[4] + ", " + out[5] + ", " + out[6] + ", " + out[7] + "]";
        }

        // A Texture over the shared uvgrid bitmap with an authored uv transform.
        private function _tex(repeatU:Number, repeatV:Number, offsetU:Number, offsetV:Number,
                              wrap:Boolean, rotation:Number = 0,
                              centerU:Number = 0, centerV:Number = 0):Texture
        {
            var t:Texture = new Texture(_uvGrid.image);
            t.colorSpace = Texture.SRGBColorSpace;
            if (wrap || repeatU > 1 || repeatV > 1)
            {
                t.wrapS = Texture.RepeatWrapping;
                t.wrapT = Texture.RepeatWrapping;
            }
            t.repeat.set(repeatU, repeatV);
            t.offset.set(offsetU, offsetV);
            t.rotation = rotation;
            t.center.set(centerU, centerV);
            return t;
        }

        // One quad, uv left at 0..1. `map` carries the transform; a null map
        // would draw the bare material color.
        private function _quad(x:Number, y:Number, z:Number, map:Texture):Mesh
        {
            var geo:PlaneGeometry = new PlaneGeometry(2.4, 2.4, 1, 1);

            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(map == null ? 0x808080 : 0xffffff);
            mat.roughness = 1.0;
            mat.metalness = 0.0;
            mat.map = map;

            var mesh:Mesh = new Mesh(geo, mat);
            mesh.position.set(x, y, z);
            return mesh;
        }
    }
}