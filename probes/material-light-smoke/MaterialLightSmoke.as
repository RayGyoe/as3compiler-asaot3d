// asaot3d/probes/material-light-smoke/MaterialLightSmoke.as -- material/light smoke test.
//
// Verifies the material base class defaults and the needsUpdate->version bump,
// MeshBasicMaterial's color, and the light base/Ambient/Directional defaults.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/material-light-smoke/MaterialLightSmoke.as \
//        $(find kit -name '*.as') -o temp/material-light-smoke.exe --run
//
// Full kit sweep: core's Frustum.intersectsObject / Box3.expandByObject take a Mesh, so
// math+core+materials+lights alone no longer compile.
import asaot.three.lights.AmbientLight;
import asaot.three.lights.DirectionalLight;
import asaot.three.lights.Light;
import asaot.three.materials.Material;
import asaot.three.materials.MeshBasicMaterial;

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

// ---- 1) Material base defaults (borrowed from Material.js r187) ----
var m:Material = new Material();
check("name default empty", m.name == "");
check("transparent default false", m.transparent == false);
check("opacity default 1", near(m.opacity, 1));
check("side default FrontSide", m.side == Material.FrontSide);
check("blending default NormalBlending", m.blending == Material.NormalBlending);
check("depthTest default true", m.depthTest == true);
check("depthWrite default true", m.depthWrite == true);
check("visible default true", m.visible == true);
check("version default 0", m.version == 0);

// ---- 2) needsUpdate bumps version (Material.js:1246) ----
m.needsUpdate = true;
check("needsUpdate true bumps version", m.version == 1);
m.needsUpdate = false;
check("needsUpdate false does not bump", m.version == 1);

// ---- 3) MeshBasicMaterial color default 0xffffff ----
var basic:MeshBasicMaterial = new MeshBasicMaterial();
check("MeshBasicMaterial is a Material", basic is Material);
check("color default white", near(basic.color.r, 1) && near(basic.color.g, 1) && near(basic.color.b, 1));
check("wireframe default false", basic.wireframe == false);

// ---- 4) Light base color + intensity ----
var light:Light = new Light(0xff0000, 2);
check("light color red", near(light.color.r, 1) && near(light.color.g, 0) && near(light.color.b, 0));
check("light intensity 2", near(light.intensity, 2));
check("light is Object3D", light.position != null);

// ---- 5) AmbientLight defaults ----
var ambient:AmbientLight = new AmbientLight();
check("ambient default white", near(ambient.color.r, 1));
check("ambient default intensity 1", near(ambient.intensity, 1));

// ---- 6) DirectionalLight defaults (position = DEFAULT_UP, DirectionalLight.js:55) ----
var dir:DirectionalLight = new DirectionalLight();
check("directional position (0,1,0)", near(dir.position.x, 0) && near(dir.position.y, 1) && near(dir.position.z, 0));
check("directional has target", dir.target != null);
check("directional target at origin", near(dir.target.position.x, 0) && near(dir.target.position.y, 0) && near(dir.target.position.z, 0));

if (failed == 0) trace("ALL PASS");
else trace(failed + " FAILED");
