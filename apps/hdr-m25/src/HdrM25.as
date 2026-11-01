// HdrM25.as -- M25 acceptance demo: an HDR panorama as the environment.
//
// M9 lit the metal row with six 8-bit JPEG cube faces, which means the brightest
// thing in the room is white (1.0). M25 loads a Radiance .hdr panorama instead:
//
//   RGBELoader (float radiance)
//     -> EquirectangularToCube.bakeTexels (CPU, 8-bit gamma-encoded + hdrScale)
//       -> CubeTexture on scene.environment AND scene.background
//
// The softboxes in tools/gen-hdr.js are 60.0 and 25.0 -- sixty times over white.
// That is the whole point of HDR: after ACES the mirror sphere still shows a
// white-hot panel with a clean falloff instead of a flat clipped blob, and the
// rough spheres pick up a warm key / cool rim split that an LDR map cannot carry.
//
// Keys (the acceptance A/B):
//   1  backgroundBlurriness 0 <-> 1
//   2  scene.environmentIntensity 1 -> 2 -> 0 -> 1   (0 = the near-black control)
//   3  scene.backgroundIntensity 1 -> 0.4 -> 1
//   4  scene.background on/off (falls back to the clear colour)
//   5  scene.environment on/off
//   6  re-bake at half face size (64 instead of 128)
//   7  panorama source .hdr <-> .exr (M25-R3; same generator, so the environment
//      must look the same -- the .exr is 256x128 instead of 512x256)
//   8  scene.environmentPrefiltered on/off (M25-R1). With it the environment is a
//      six-level roughness ladder and each sphere samples the level matching its
//      own roughness, so the highlight WIDENS down the row. Without it the M9
//      stand-in returns: one sharp cube, the reflection mixed toward the normal by
//      roughness^4, which keeps highlights mirror-sharp at roughness 1.
package
{
    import asaot.three.AGALRenderer;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.Object3D;
    import asaot.three.extras.EquirectangularToCube;
    import asaot.three.extras.PrefilterJob;
    import asaot.three.extras.PrefilteredEnvironment;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.loaders.EXRLoader;
    import asaot.three.loaders.RGBELoader;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;
    import asaot.three.textures.CubeTexture;
    import asaot.three.textures.HDRImage;
    import flash.display.BitmapData;
    import flash.ui.Keyboard;

    public class HdrM25 extends Stage3DApp
    {
        private static const ROUGHNESS:Array = [0.05, 0.2, 0.45, 0.7, 1.0];
        private static const FACE_SIZE:int = 128;

        private var _panorama:HDRImage = null;
        private var _cube:CubeTexture = null;
        private var _envOn:Boolean = true;
        private var _bgOn:Boolean = true;
        private var _envStep:int = 0;      // 0 -> 1.0, 1 -> 2.0, 2 -> 0.0
        private var _bgStep:int = 0;
        private var _blurred:Boolean = false;
        private var _faceSize:int = FACE_SIZE;
        private var _useExr:Boolean = false;
        private var _ladder:PrefilteredEnvironment = null;
        private var _ladderOn:Boolean = true;
        private var _job:PrefilterJob = null;
        private var _bakeT0:Number = 0;

        override protected function createScene():void
        {
            _scene = new Scene();
            _scene.background = new Color(0x101014);

            // ACES at exposure 1.0. Without tone mapping the 60.0 softboxes clip
            // to flat white and the sky renders as raw linear light -- M25 is the
            // first demo whose environment actually carries values above 1.0, so
            // this is where the curve starts to matter. The kit defaults to
            // NoToneMapping (three.js's own default), so it is set here.
            renderer.toneMapping = AGALRenderer.ACESFilmicToneMapping;
            renderer.toneMappingExposure = 1.0;
            _camera = new PerspectiveCamera(30, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0.55, 7.2);
            _camera.lookAt(0, 0.05, 0);

            var sphere:SphereGeometry = new SphereGeometry(0.62, 48, 32);
            var i:int;
            for (i = 0; i < 5; i++)
            {
                var mat:MeshStandardMaterial = new MeshStandardMaterial();
                mat.color.setHex(0xffffff);
                mat.metalness = 1.0;
                mat.roughness = ROUGHNESS[i] as Number;
                var mesh:Mesh = new Mesh(sphere, mat);
                mesh.position.set(-2.55 + i * 1.275, 0.15, 0);
                _scene.add(mesh);
            }

            // A dark, fully rough floor: it shows the panorama's sky/ground split
            // smeared into irradiance, which is where an LDR map looks flat.
            var floorMat:MeshStandardMaterial = new MeshStandardMaterial();
            floorMat.color.setHex(0x1a1a1e);
            floorMat.metalness = 0.0;
            floorMat.roughness = 1.0;
            var floor:Mesh = new Mesh(new PlaneGeometry(30, 30), floorMat);
            floor.rotation.x = -Math.PI / 2;
            floor.position.y = -0.5;
            _scene.add(floor);

            // M25: the panorama is the ONLY light source (no lights at all), so
            // the frame is entirely a function of the HDR environment -- which
            // is what makes the A/B on keys 2/4/5 judgeable.
            loadPanorama();
        }

        // M25-R3: the same panorama exists as Radiance .hdr and OpenEXR .exr
        // (tools/gen-hdr.js / tools/gen-exr.js share the radiance function), so
        // key 7 is a decoder A/B: both paths must light the spheres identically.
        private function loadPanorama():void
        {
            if (_useExr)
            {
                var xl:EXRLoader = new EXRLoader();
                xl.load("app:/assets/textures/hdr/studio.exr", onHdr, null, onHdrError);
            }
            else
            {
                var rl:RGBELoader = new RGBELoader();
                rl.load("app:/assets/textures/hdr/studio.hdr", onHdr, null, onHdrError);
            }
        }

        private function onHdrError(e:Object):void
        {
            logLine("HDR load/decode failed: " + e);
        }

        private function onHdr(img:HDRImage):void
        {
            _panorama = img;
            logLine("HDR panorama " + (_useExr ? "exr " : "hdr ") + img.width + "x" + img.height
                    + " exposure=" + img.exposure);
            bake();
        }

        // M25-R1: the ladder is baked ONE LEVEL PER FRAME (see PrefilterJob).
        // Under `adl` the same six-level bake costs ~2.2s in a single frame,
        // which is over a third of AIR's 15-second script watchdog; level 0 is
        // the sharp cube, so the environment still appears on the first step.
        private function bake():void
        {
            if (_panorama == null) return;
            var scale:Number = EquirectangularToCube.autoScale(_panorama);
            _job = new PrefilterJob(_panorama, _faceSize, scale);
            _bakeT0 = new Date().time;
            _cube = null;
            _ladder = null;
            _scene.background = new Color(0x101014);
            applyState();
            logLine("bake start " + _faceSize + "px, " + _job.levelCount + " levels, autoScale=" +
                    scale);
        }

        // One ladder step per frame; the environment appears as soon as level 0
        // exists and gets rougher-looking reflections as the rest land.
        private function stepBake():void
        {
            if (_job == null || _job.done) return;
            var had:int = _job.completed;
            _job.step();
            if (_job.completed == had) return;

            var first:Boolean = had == 0;
            var bmd:BitmapData = _job.cubes[0] != null ? _job.cubes[0].images[0] : null;
            _cube = _job.cubes[0];
            _ladder = _job.partial();
            applyState();
            if (_job.done)
            {
                logLine("bake " + _faceSize + "px in " + int(new Date().time - _bakeT0) + "ms over " +
                        _job.completed + " frames, ladder=" + _job.levelCount + " levels, hdrScale=" +
                        _cube.hdrScale + ", colorSpace=" + _cube.colorSpace + ", face0=" +
                        (bmd != null ? bmd.width + "x" + bmd.height : "null"));
                _scene.background = _bgOn ? _cube : new Color(0x101014);
                _job = null;
            }
            else if (first)
            {
                logLine("ladder level 0 (" + _cube.colorSpace + ", hdrScale=" + _cube.hdrScale +
                        ") after " + int(new Date().time - _bakeT0) + "ms");
                _scene.background = _bgOn ? _cube : new Color(0x101014);
            }
        }

        private function applyState():void
        {
            _scene.environment = _envOn ? _cube : null;
            // The ladder only matters when there IS an environment: it is a set of
            // cubes to choose between, not a light source of its own.
            _scene.environmentPrefiltered = (_envOn && _ladderOn) ? _ladder : null;
            _scene.environmentIntensity = _envStep == 0 ? 1.0 : (_envStep == 1 ? 2.0 : 0.0);
            _scene.backgroundIntensity = _bgStep == 0 ? 1.0 : 0.4;
            _scene.backgroundBlurriness = _blurred ? 1.0 : 0.0;
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            stepBake();
            if (keys == null) return;
            if (keys.justPressed(Keyboard.NUMBER_1))
            {
                _blurred = !_blurred;
                applyState();
                logLine("backgroundBlurriness=" + (_blurred ? 1 : 0));
            }
            if (keys.justPressed(Keyboard.NUMBER_2))
            {
                _envStep = (_envStep + 1) % 3;
                applyState();
                logLine("environmentIntensity=" + _scene.environmentIntensity);
            }
            if (keys.justPressed(Keyboard.NUMBER_3))
            {
                _bgStep = (_bgStep + 1) % 2;
                applyState();
                logLine("backgroundIntensity=" + _scene.backgroundIntensity);
            }
            if (keys.justPressed(Keyboard.NUMBER_4))
            {
                _bgOn = !_bgOn;
                _scene.background = _bgOn ? _cube : new Color(0x101014);
                logLine("background=" + (_bgOn ? "env" : "clear"));
            }
            if (keys.justPressed(Keyboard.NUMBER_5))
            {
                _envOn = !_envOn;
                applyState();
                logLine("environment=" + (_envOn ? "on" : "off"));
            }
            if (keys.justPressed(Keyboard.NUMBER_7))
            {
                _useExr = !_useExr;
                logLine("panorama source=" + (_useExr ? "exr" : "hdr"));
                loadPanorama();
            }
            if (keys.justPressed(Keyboard.NUMBER_8))
            {
                _ladderOn = !_ladderOn;
                applyState();
                logLine("environmentPrefiltered=" + (_ladderOn ? "ladder" : "M9 stand-in"));
            }
            if (keys.justPressed(Keyboard.NUMBER_6))
            {
                _faceSize = _faceSize == FACE_SIZE ? 64 : FACE_SIZE;
                bake();
            }
        }
    }
}