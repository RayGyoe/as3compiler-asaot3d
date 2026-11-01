// asaot3d/probes/shadow-smoke-m7/ShadowSmokeM7.as -- M7 shadow kit smoke test.
//
// Verifies OrthographicCamera, DirectionalLightShadow defaults, and
// DirectionalLight.shadow wiring (borrowed from r187 OrthographicCamera.js /
// DirectionalLightShadow.js / DirectionalLight.js). The shadow-map prepass and
// PCF sampling are exercised in the M7 renderer demo.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/shadow-smoke-m7/ShadowSmokeM7.as \
//        $(find kit -name '*.as') -o temp/shadow-smoke-m7.exe --run
import asaot.three.cameras.OrthographicCamera;
import asaot.three.lights.DirectionalLight;
import asaot.three.lights.DirectionalLightShadow;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-5):Boolean
{
    return Math.abs(a - b) < eps;
}

// ---- 1) OrthographicCamera defaults (OrthographicCamera.js r187) ----
var o:OrthographicCamera = new OrthographicCamera();
check("OrthographicCamera zoom default 1", near(o.zoom, 1));
check("OrthographicCamera frustum defaults", near(o.left, -1) && near(o.right, 1) && near(o.top, 1) && near(o.bottom, -1));
check("OrthographicCamera near default 0.1", near(o.near, 0.1));
check("OrthographicCamera far default 2000", near(o.far, 2000));
check("OrthographicCamera projection built", o.projectionMatrix.elements[15] == 1);

// ---- 2) OrthographicCamera custom + zoom ----
var o2:OrthographicCamera = new OrthographicCamera(-10, 10, 10, -10, 1, 100);
o2.zoom = 2;
o2.updateProjectionMatrix();
check("OrthographicCamera custom zoom kept", near(o2.zoom, 2));
// zoom=2 halves the half-extent: effective left/right become +-5 (frustum centre 0).
// Projection matrix row 0: 2/(right-left). With dx=(10-(-10))/(2*2)=5, so
// right-left=10 -> te[0]=2/10=0.2.
check("OrthographicCamera zoom scales projection", near(o2.projectionMatrix.elements[0], 0.2));

// ---- 3) DirectionalLightShadow defaults (DirectionalLightShadow.js r187) ----
var s:DirectionalLightShadow = new DirectionalLightShadow();
check("shadow camera is OrthographicCamera", s.camera is OrthographicCamera);
check("shadow camera near 0.5", near(s.camera.near, 0.5));
check("shadow camera far 500", near(s.camera.far, 500));
check("shadow camera left -5", near(s.camera.left, -5));
check("shadow camera right 5", near(s.camera.right, 5));
check("shadow mapSize default 512", near(s.mapSize.x, 512) && near(s.mapSize.y, 512));
check("shadow bias default 0", near(s.bias, 0));
check("shadow map starts null", s.map == null);
check("shadow matrix exists", s.matrix != null);

// ---- 4) DirectionalLight.shadow wiring (DirectionalLight.js r187) ----
var d:DirectionalLight = new DirectionalLight();
check("DirectionalLight has shadow", d.shadow != null);
check("DirectionalLight shadow camera", d.shadow.camera is OrthographicCamera);
check("DirectionalLight target exists", d.target != null);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));
