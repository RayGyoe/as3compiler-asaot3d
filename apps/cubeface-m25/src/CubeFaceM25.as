// CubeFaceM25.as -- M25 prerequisite probe: WHICH CUBE FACE DOES EACH RUNTIME
// SAMPLE, AND FROM WHICH DIRECTION?
//
// Why this exists: the same `env-m9` scene renders differently on the two
// backends (temp/env-m9-aot-crop.png vs temp/env-m9-air-crop.png). AIR shows the
// SwedishRoyalCastle night sky above the horizon and the lit facade below it;
// AOT shows a dark red-ish cap where the sky should be. Every face loads
// ("environment loaded: face 512px"), every face uploads (six separate
// uploadFromBitmapData calls), and s3d_upload_cube_texture writes face N to
// Metal slice N in AGAL's +X,-X,+Y,-Y,+Z,-Z order -- so the bug is not "a face
// is missing", it is "a face is sampled from the wrong direction". That
// distinction cannot be read off a photo-realistic environment, so this demo
// replaces it with six saturated flat colours and a mirror sphere.
//
// The environment is a 16x16 flat colour per face:
//     +X red   -X green   +Y blue   -Y yellow   +Z magenta   -Z cyan
// A metalness=1 / roughness=0.02 sphere at the origin reflects those six faces
// as six unambiguous colour patches, so "which face appears where" is a
// per-pixel question with a single correct answer, independent of tone mapping
// (this demo leaves toneMapping at the renderer default, NoToneMapping).
//
// The expected layout, camera at +Z looking at the origin (Stage3D/D3D/GL cube
// convention, which is what AGAL specifies):
//     centre of the sphere -> +Z (magenta),  behind the camera and therefore
//     visible only near the silhouette rim
//     left rim  -> +X (red)      right rim -> -X (green)
//     top       -> +Y (blue)     bottom    -> -Y (yellow)
// A runtime that shows a different colour in one of those places has a cube
// orientation bug, not a shading bug.
//
// Build/run from asaot3d/:
//   ./apps/cubeface-m25/build.sh aot --run
//   ./apps/cubeface-m25/build.sh air --run
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.AGALRenderer;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.loaders.CubeTextureLoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.CubeTexture;

    import flash.display.BitmapData;

    public class CubeFaceM25 extends Stage3DApp
    {
        override protected function createScene():void
        {
            AGALRenderer.dumpFragSource = true;
            AGALRenderer.debugReflect = false;
            _scene = new Scene();
            _camera = new PerspectiveCamera(40, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 6.5);
            _camera.lookAt(0, 0, 0);

            // A perfect mirror: every visible texel is the environment, so the
            // six faces are the only thing that can colour the sphere. Nothing
            // else is added -- no ambient, no directional -- because any direct
            // light would tint the patches and destroy the reading.
            var mat:MeshStandardMaterial = new MeshStandardMaterial();
            mat.color.setHex(0xffffff);
            mat.metalness = 1.0;
            mat.roughness = 0.02;

            var sphere:Mesh = new Mesh(new SphereGeometry(0.9, 64, 48), mat);
            _scene.add(sphere);

            // The same +X,-X,+Y,-Y,+Z,-Z order every other demo uses; only the
            // CONTENT of the faces changed, so nothing here can mask a face-order
            // bug in the loader or the uploader.
            var urls:Vector.<String> = new Vector.<String>();
            urls.push("app:/assets/textures/cube/probe6c/px_gray.jpg");
            urls.push("app:/assets/textures/cube/probe6c/nx_green.jpg");
            urls.push("app:/assets/textures/cube/probe6c/py_blue.jpg");
            urls.push("app:/assets/textures/cube/probe6c/ny_white.jpg");
            urls.push("app:/assets/textures/cube/probe6c/pz_red.jpg");
            urls.push("app:/assets/textures/cube/probe6c/nz_black.jpg");

            var loader:CubeTextureLoader = new CubeTextureLoader();
            loader.load(urls, onEnvLoaded, null, onEnvError);
        }

        private function onEnvLoaded(cube:CubeTexture):void
        {
            // DIAGNOSTIC (M25): the kit's default minFilter is
            // LinearMipmapLinearFilter with generateMipmaps=true, so
            // setSamplerStateAt ends up at "miplinear" and OVERRIDES the AGAL's
            // inline mipnone. This runtime ignores uploadFromBitmapData for
            // miplevel > 0 and relies on the backend's blit to build the cube
            // chain, so if that chain is incomplete the minified regions sample
            // an empty level. Toggling it off isolates that.
            cube.generateMipmaps = !_noMip;
            cube.minFilter = _noMip ? 0 : 7;
            _scene.environment = cube;
            // Same cube as the SKYBOX too. The mirror sphere reads the env map
            // through the PBR path (roughness -> LOD, reflection vector from the
            // view/normal pair), while the skybox reads it through a rotation-only
            // view matrix -- so the two programs are an immediate split between
            // "the cube data is wrong" and "the PBR sampling is wrong".
            _scene.background = cube;
            logLine("CubeFaceM25 environment: face " + cube.faceSize() + "px mip=" + cube.generateMipmaps + " minFilter=" + cube.minFilter);
            // Which faces actually carry pixels? A face whose decode failed is
            // still non-null in some paths, so the pixel VALUE has to be read,
            // not just the slot.
            var fi:int;
            for (fi = 0; fi < 6; fi++)
            {
                var bd:BitmapData = cube.images[fi];
                var hex:String = "NULL";
                var dims:String = "null";
                if (bd != null)
                {
                    dims = bd.width + "x" + bd.height;
                    try { hex = bd.getPixel32(bd.width >> 1, bd.height >> 1).toString(16) + " / a=" + bd.getPixel32(0, 0).toString(16); }
                    catch (err:Error) { hex = "getPixel?"; }
                }
                logLine("  face " + fi + " " + dims + " center=0x" + hex);
            }
        }

        private function onEnvError(e:Object):void
        {
            logLine("CubeFaceM25 cube error: " + e);
        }

        // Set from the environment so one binary can exercise both paths.
        private var _noMip:Boolean = true;

        private var _frame:int = 0;

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frame++;
            if (_frame == 1)
            {
                logLine("CubeFaceM25 ready: env=" + (_scene.environment != null) +
                        " expect top=BLUE(+Y) bottom=YELLOW(-Y) left=RED(+X) right=GREEN(-X)");
            }
        }
    }
}