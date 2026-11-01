// asaot3d/probes/light-smoke-m6/LightSmokeM6.as -- M6 punctual light smoke test.
//
// Verifies PointLight and SpotLight defaults + custom constructors (borrowed
// from three.js r187 src/lights/PointLight.js and SpotLight.js). The AGAL
// additive-pass programs are exercised separately in the M6 renderer demo.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/light-smoke-m6/LightSmokeM6.as \
//        $(find kit -name '*.as') -o temp/light-smoke-m6.exe --run
import asaot.three.lights.Light;
import asaot.three.lights.PointLight;
import asaot.three.lights.SpotLight;

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

// ---- 1) PointLight defaults (PointLight.js r187) ----
var p:PointLight = new PointLight();
check("PointLight is Light", p is Light);
check("PointLight type test", p is PointLight);
check("PointLight distance default 0", near(p.distance, 0));
check("PointLight decay default 2", near(p.decay, 2));
check("PointLight color default white", near(p.color.r, 1) && near(p.color.g, 1) && near(p.color.b, 1));
check("PointLight intensity default 1", near(p.intensity, 1));

// ---- 2) PointLight custom ----
var p2:PointLight = new PointLight(0xff0000, 3, 10, 1);
check("PointLight custom color red", near(p2.color.r, 1) && near(p2.color.g, 0) && near(p2.color.b, 0));
check("PointLight custom intensity 3", near(p2.intensity, 3));
check("PointLight custom distance 10", near(p2.distance, 10));
check("PointLight custom decay 1", near(p2.decay, 1));

// ---- 3) SpotLight defaults (SpotLight.js r187) ----
var s:SpotLight = new SpotLight();
check("SpotLight is Light", s is Light);
check("SpotLight type test", s is SpotLight);
check("SpotLight distance default 0", near(s.distance, 0));
check("SpotLight angle default 60deg", near(s.angle, 1.0471975511965976));
check("SpotLight penumbra default 0", near(s.penumbra, 0));
check("SpotLight decay default 2", near(s.decay, 2));
check("SpotLight target exists", s.target != null);
check("SpotLight position default (0,1,0)", near(s.position.x, 0) && near(s.position.y, 1) && near(s.position.z, 0));

// ---- 4) SpotLight custom ----
var s2:SpotLight = new SpotLight(0x00ff00, 2, 5, 0.5, 0.3, 1);
check("SpotLight custom color green", near(s2.color.r, 0) && near(s2.color.g, 1) && near(s2.color.b, 0));
check("SpotLight custom intensity 2", near(s2.intensity, 2));
check("SpotLight custom distance 5", near(s2.distance, 5));
check("SpotLight custom angle 0.5", near(s2.angle, 0.5));
check("SpotLight custom penumbra 0.3", near(s2.penumbra, 0.3));
check("SpotLight custom decay 1", near(s2.decay, 1));

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));
