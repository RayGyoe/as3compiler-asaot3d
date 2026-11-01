// asaot3d/probes/material-smoke-m2/MaterialSmokeM2.as -- M2 material/texture smoke test.
//
// Verifies MeshStandardMaterial's PBR parameter defaults and the Texture class's
// wrap/filter constants and version bump, mirroring the M1 material-light-smoke
// discipline. Runs headless (no Stage3D context) -- it only exercises the engine
// layer that the AGALRenderer consumes.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/material-smoke-m2/MaterialSmokeM2.as \
//        $(find kit -name '*.as') -o temp/material-smoke-m2.exe --run
import asaot.three.materials.Material;
import asaot.three.materials.MeshBasicMaterial;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.textures.Texture;

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

// ---- 1) MeshStandardMaterial PBR defaults (MeshStandardMaterial.js r187) ----
var std:MeshStandardMaterial = new MeshStandardMaterial();
check("std is a Material", std is Material);
check("std color default white", near(std.color.r, 1) && near(std.color.g, 1) && near(std.color.b, 1));
check("std roughness default 1", near(std.roughness, 1));
check("std metalness default 0", near(std.metalness, 0));
check("std emissive default black", near(std.emissive.r, 0) && near(std.emissive.g, 0) && near(std.emissive.b, 0));
check("std emissiveIntensity default 1", near(std.emissiveIntensity, 1));
check("std map default null", std.map == null);
check("std normalMap default null", std.normalMap == null);
check("std roughnessMap default null", std.roughnessMap == null);
check("std metalnessMap default null", std.metalnessMap == null);
// M4: normalScale is a Vector2(1,1) (MeshStandardMaterial.js:238), not null.
check("std normalScale default (1,1)", std.normalScale != null && std.normalScale.x == 1 && std.normalScale.y == 1);
std.normalScale.set(2, 3);
check("std normalScale set(2,3)", std.normalScale.x == 2 && std.normalScale.y == 3);
check("std wireframe default false", std.wireframe == false);
check("std flatShading default false", std.flatShading == false);

// ---- 2) Material needsUpdate -> version still applies to the subclass ----
std.needsUpdate = true;
check("std needsUpdate bumps version", std.version == 1);

// ---- 3) Texture constants match src/constants.js r187 ----
check("RepeatWrapping 1000", Texture.RepeatWrapping == 1000);
check("ClampToEdgeWrapping 1001", Texture.ClampToEdgeWrapping == 1001);
check("MirroredRepeatWrapping 1002", Texture.MirroredRepeatWrapping == 1002);
check("NearestFilter 1003", Texture.NearestFilter == 1003);
check("NearestMipmapNearestFilter 1004", Texture.NearestMipmapNearestFilter == 1004);
check("NearestMipmapLinearFilter 1005", Texture.NearestMipmapLinearFilter == 1005);
check("LinearFilter 1006", Texture.LinearFilter == 1006);
check("LinearMipmapNearestFilter 1007", Texture.LinearMipmapNearestFilter == 1007);
check("LinearMipmapLinearFilter 1008", Texture.LinearMipmapLinearFilter == 1008);

// ---- 4) Texture defaults (Texture.js r187) ----
var tex:Texture = new Texture();
check("tex name default empty", tex.name == "");
check("tex image default null", tex.image == null);
check("tex wrapS default clamp", tex.wrapS == Texture.ClampToEdgeWrapping);
check("tex wrapT default clamp", tex.wrapT == Texture.ClampToEdgeWrapping);
check("tex magFilter default linear", tex.magFilter == Texture.LinearFilter);
check("tex minFilter default mipmap linear", tex.minFilter == Texture.LinearMipmapLinearFilter);
check("tex flipY default true", tex.flipY == true);
check("tex generateMipmaps default true", tex.generateMipmaps == true);
check("tex version default 0", tex.version == 0);

// ---- 5) Texture needsUpdate -> version bump ----
tex.needsUpdate = true;
check("tex needsUpdate bumps version", tex.version == 1);
tex.needsUpdate = false;
check("tex needsUpdate false no bump", tex.version == 1);

if (failed == 0) trace("ALL PASS");
else trace(failed + " FAILED");
