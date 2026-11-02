// asaot3d/probes/apphost-smoke-m16/AppHostSmokeM16.as -- M16 app-host smoke.
//
// Stage3DApp is the shared bootstrap every demo now inherits: it requests the
// Stage3D context, syncs the application clock to the display's refresh rate,
// reconfigures the back buffer + projection on window resize, and renders /
// presents each frame. A headless probe cannot create a context, so this pins
// the parts that decide BEHAVIOUR without a GPU:
//
//   A. frameRateForRefresh(): the panel rate is adopted verbatim, and "cannot
//      query the panel" (0 / negative / NaN) never becomes stage.frameRate = 0
//      -- writing 0 is not "leave it alone" (AIR floors an assigned 0 at
//      0.01 fps), so the host keeps the rate it already had.
//   B. aspectFor(): w/h, with zero/negative viewports rejected instead of
//      producing NaN/Infinity in the projection matrix.
//   C. The projection refit the host performs on resize: for a perspective
//      camera, elements[0] * aspect == elements[5]. If resize set only one of
//      them the image would shear/stretch -- that is the bug this pins.
//   D. Host state before a context exists: refreshRate 0, renderer null, and
//      constructing the host does NOT throw (the Stage3D request is deferred to
//      ADDED_TO_STAGE).
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/apphost-smoke-m16/AppHostSmokeM16.as \
//     $(find kit -name '*.as') $(find seam -name '*.as') \
//     -o temp/apphost-smoke-m16 --run
import asaot.three.app.Stage3DApp;
import asaot.three.cameras.PerspectiveCamera;
import asaot.three.math.MathUtils;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-6):Boolean
{
    return Math.abs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// A. Display-rate -> application frame rate.
// ---------------------------------------------------------------------------
// A 120 Hz panel is the machine this ran on; 60 and 59.94 are the other two
// rates the backend can report (SDL gives the integer panel rate, so 59.94 is
// what a fractional-rate display rounds to on some drivers).
check("A1 120 Hz is adopted verbatim", near(Stage3DApp.frameRateForRefresh(120), 120));
check("A2 60 Hz is adopted verbatim", near(Stage3DApp.frameRateForRefresh(60), 60));
check("A3 fractional rates survive", near(Stage3DApp.frameRateForRefresh(59.94), 59.94));
check("A4 0 means 'cannot query' -> keep the app rate", near(Stage3DApp.frameRateForRefresh(0), 0));
check("A5 a negative rate is treated as unknown", near(Stage3DApp.frameRateForRefresh(-60), 0));
check("A6 NaN is treated as unknown", near(Stage3DApp.frameRateForRefresh(0 / 0), 0));
check("A7 only the unknown sentinel is 0", Stage3DApp.frameRateForRefresh(1) == 1);

// A8-A12: the demo's own ceiling (capFrameRate). A ceiling is a CAP, not a
// request to raise: it may lower the application clock below the panel rate
// (that is the whole point -- a 120 Hz panel otherwise doubles the CPU cost of
// a frame no one asked to be redrawn), and it may never raise it above the panel.
check("A8 a 60 ceiling halves a 120 Hz panel", near(Stage3DApp.capFrameRate(120, 60), 60));
check("A9 a ceiling never raises above the panel", near(Stage3DApp.capFrameRate(60, 120), 60));
check("A10 a ceiling equal to the panel is a no-op", near(Stage3DApp.capFrameRate(60, 60), 60));
check("A11 0 means 'no ceiling', not '0 fps'", near(Stage3DApp.capFrameRate(120, 0), 120));
check("A12 a NaN/negative ceiling is ignored",
      near(Stage3DApp.capFrameRate(120, 0 / 0), 120) && near(Stage3DApp.capFrameRate(120, -60), 120));

// ---------------------------------------------------------------------------
// B. Viewport -> projection aspect.
// ---------------------------------------------------------------------------
check("B1 960x720 is 4:3", near(Stage3DApp.aspectFor(960, 720), 4.0 / 3.0));
check("B2 1280x720 is 16:9", near(Stage3DApp.aspectFor(1280, 720), 16.0 / 9.0));
check("B3 a square viewport is 1", near(Stage3DApp.aspectFor(500, 500), 1.0));
check("B4 zero width is rejected", near(Stage3DApp.aspectFor(0, 720), 0));
check("B5 zero height is rejected", near(Stage3DApp.aspectFor(960, 0), 0));
check("B6 a negative size is rejected", near(Stage3DApp.aspectFor(-10, 720), 0));
check("B7 the result is never NaN", !isNaN(Stage3DApp.aspectFor(1, 3)));

// ---------------------------------------------------------------------------
// C. The projection refit. applyViewportSize() assigns camera.aspect and calls
//    updateProjectionMatrix(); this is that exact pair, without a context.
// ---------------------------------------------------------------------------
var cam:PerspectiveCamera = new PerspectiveCamera(60, 1, 0.1, 100);
var e1:Vector.<Number> = cam.projectionMatrix.elements;
var scaleY:Number = e1[5];

check("C1 a fresh 1:1 camera has equal x/y scale", near(e1[0], scaleY));

cam.aspect = 2.0;
cam.updateProjectionMatrix();
var e2:Vector.<Number> = cam.projectionMatrix.elements;
check("C2 after a 2:1 refit the x scale halves", near(e2[0] * 2.0, e2[5]));
check("C3 the y scale is untouched by the aspect", near(e2[5], scaleY));
check("C4 the inverse matrix follows",
      near(cam.projectionMatrixInverse.elements[0], 1.0 / e2[0]));

cam.aspect = Stage3DApp.aspectFor(820, 568);
cam.updateProjectionMatrix();
var e3:Vector.<Number> = cam.projectionMatrix.elements;
check("C5 the resize path (820x568) keeps the ratio",
      near(e3[0] * (820.0 / 568.0), e3[5]));
check("C6 vertical fov is preserved across the refit",
      near(2.0 * MathUtils.radToDeg(Math.atan(1.0 / e3[5])), 60.0, 1e-4));

// ---------------------------------------------------------------------------
// D. Host state before a Stage3D context exists.
// ---------------------------------------------------------------------------
class HeadlessHost extends Stage3DApp
{
    override protected function createScene():void
    {
        // never reached headlessly: no stage -> no CONTEXT3D_CREATE
    }
}

var host:HeadlessHost = new HeadlessHost();
check("D1 constructing the host is safe without a stage", host != null);
check("D2 no renderer before the context exists", host.renderer == null);
check("D3 refreshRate is 0 until a panel rate is reported", near(host.refreshRate, 0));
check("D4 the host is a display object like any demo", host.numChildren == 0);
// D5: the default must be "no ceiling". A non-zero default here would silently
// throttle every demo that never asked for one.
check("D5 the base host asks for no ceiling", near(Stage3DApp.capFrameRate(120, 0), 120));

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));