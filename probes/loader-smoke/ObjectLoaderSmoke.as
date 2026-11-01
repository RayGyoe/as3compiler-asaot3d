// asaot3d/probes/loader-smoke/ObjectLoaderSmoke.as -- M3 loader smoke test.
//
// Verifies ObjectLoader deserializes a three.js JSON Object/Scene format 4
// envelope into a correct scene graph: BufferGeometry attributes + index,
// MeshStandardMaterial/MeshBasicMaterial by type, and the Scene/Group/Mesh/
// AmbientLight/DirectionalLight object tree with position/rotation/scale and the
// matrix fallback. Runs headless (no Stage3D context) -- pure CPU deserialization.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/loader-smoke/ObjectLoaderSmoke.as \
//        $(find kit -name '*.as') -o temp/loader-smoke.exe --run
import asaot.three.core.BufferGeometry;
import asaot.three.core.BufferAttribute;
import asaot.three.core.Object3D;
import asaot.three.geometries.BoxGeometry;
import asaot.three.lights.AmbientLight;
import asaot.three.lights.DirectionalLight;
import asaot.three.loaders.ObjectLoader;
import asaot.three.materials.MeshBasicMaterial;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.objects.Group;
import asaot.three.objects.Mesh;
import asaot.three.scenes.Scene;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

// ---- 1) Main scene graph ----
var json:Object = {
    metadata: { version: 4.5, type: "Object", generator: "asaot3d" },
    geometries: [
        {
            uuid: "geo-cube",
            type: "BufferGeometry",
            name: "cube-geo",
            data: {
                attributes: {
                    position: { itemSize: 3, type: "Float32Array", array: [ 0,0,0, 1,0,0, 0,1,0, 1,1,0 ] },
                    normal:   { itemSize: 3, type: "Float32Array", array: [ 0,0,1, 0,0,1, 0,0,1, 0,0,1 ] },
                    uv:       { itemSize: 2, type: "Float32Array", array: [ 0,0, 1,0, 0,1, 1,1 ] }
                },
                index: { itemSize: 1, type: "Uint16Array", array: [ 0,1,2, 2,1,3 ] }
            }
        }
    ],
    materials: [
        {
            uuid: "mat-std",
            type: "MeshStandardMaterial",
            name: "metal",
            color: 16711680,
            roughness: 0.25,
            metalness: 0.9,
            emissive: 65280,
            emissiveIntensity: 1.5,
            wireframe: true,
            flatShading: true
        },
        {
            uuid: "mat-basic",
            type: "MeshBasicMaterial",
            name: "flat",
            color: 255,
            wireframe: false
        }
    ],
    object: {
        uuid: "root",
        type: "Scene",
        name: "MainScene",
        children: [
            {
                uuid: "grp",
                type: "Group",
                name: "group-a",
                position: [ 1, 2, 3 ],
                children: [
                    {
                        uuid: "mesh-std",
                        type: "Mesh",
                        name: "cube-mesh",
                        geometry: "geo-cube",
                        material: "mat-std",
                        scale: [ 2, 2, 2 ]
                    }
                ]
            },
            {
                uuid: "mesh-basic",
                type: "Mesh",
                name: "quad-mesh",
                geometry: "geo-cube",
                material: "mat-basic",
                rotation: [ 0, 0, 0.5 ]
            },
            {
                uuid: "amb",
                type: "AmbientLight",
                color: 16777215,
                intensity: 0.5
            },
            {
                uuid: "dir",
                type: "DirectionalLight",
                color: 16711680,
                intensity: 0.8
            }
        ]
    }
};

var loader:ObjectLoader = new ObjectLoader();
var scene:Scene = Scene(loader.parse(json));

// Scene root
check("root is Scene", scene is Scene);
check("root uuid", scene.uuid == "root");
check("root name", scene.name == "MainScene");
check("root has 4 children", scene.children.length == 4);

// Child 0: Group
var grp:Group = Group(scene.children[0]);
check("c0 is Group", scene.children[0] is Group);
check("c0 uuid", grp.uuid == "grp");
check("c0 position.x", grp.position.x == 1);
check("c0 position.y", grp.position.y == 2);
check("c0 position.z", grp.position.z == 3);
check("c0 has 1 child", grp.children.length == 1);

// Group's child: Mesh with standard material
var m1:Mesh = Mesh(grp.children[0]);
check("m1 is Mesh", grp.children[0] is Mesh);
check("m1 uuid", m1.uuid == "mesh-std");
check("m1 scale.x", m1.scale.x == 2);
check("m1 scale.y", m1.scale.y == 2);
check("m1 scale.z", m1.scale.z == 2);
var g1:BufferGeometry = m1.geometry;
check("m1 geometry uuid", g1.uuid == "geo-cube");
check("m1 geometry position count", g1.getAttribute("position").count == 4);
check("m1 geometry position itemSize", g1.getAttribute("position").itemSize == 3);
check("m1 geometry normal itemSize", g1.getAttribute("normal").itemSize == 3);
check("m1 geometry uv itemSize", g1.getAttribute("uv").itemSize == 2);
check("m1 geometry index count", g1.index.count == 6);
check("m1 geometry pos[3]", g1.getAttribute("position").getX(1) == 1);
check("m1 geometry pos[5]", g1.getAttribute("position").getY(2) == 1);

var s1:MeshStandardMaterial = MeshStandardMaterial(m1.material);
check("m1 material is std", m1.material is MeshStandardMaterial);
check("m1 material uuid", s1.uuid == "mat-std");
check("m1 material color", s1.color.getHex() == 16711680);
check("m1 material roughness", s1.roughness == 0.25);
check("m1 material metalness", s1.metalness == 0.9);
check("m1 material emissive", s1.emissive.getHex() == 65280);
check("m1 material emissiveIntensity", s1.emissiveIntensity == 1.5);
check("m1 material wireframe", s1.wireframe == true);
check("m1 material flatShading", s1.flatShading == true);

// Child 1: Mesh with basic material
var m2:Mesh = Mesh(scene.children[1]);
check("c1 is Mesh", scene.children[1] is Mesh);
check("c1 rotation.z", m2.rotation.z == 0.5);
var b2:MeshBasicMaterial = MeshBasicMaterial(m2.material);
check("c1 material is basic", m2.material is MeshBasicMaterial);
check("c1 material color", b2.color.getHex() == 255);
check("c1 material wireframe", b2.wireframe == false);

// Child 2: AmbientLight
var amb:AmbientLight = AmbientLight(scene.children[2]);
check("c2 is AmbientLight", scene.children[2] is AmbientLight);
check("c2 color", amb.color.getHex() == 16777215);
check("c2 intensity", amb.intensity == 0.5);

// Child 3: DirectionalLight
var dir:DirectionalLight = DirectionalLight(scene.children[3]);
check("c3 is DirectionalLight", scene.children[3] is DirectionalLight);
check("c3 color", dir.color.getHex() == 16711680);
check("c3 intensity", dir.intensity == 0.8);

// ---- 2) Matrix path (matrixAutoUpdate=false keeps the matrix verbatim) ----
var matrixJson:Object = {
    metadata: { version: 4.5, type: "Object", generator: "asaot3d" },
    geometries: [
        {
            uuid: "geo-cube",
            type: "BufferGeometry",
            data: {
                attributes: {
                    position: { itemSize: 3, type: "Float32Array", array: [ 0,0,0, 1,0,0, 0,1,0, 1,1,0 ] },
                    normal:   { itemSize: 3, type: "Float32Array", array: [ 0,0,1, 0,0,1, 0,0,1, 0,0,1 ] },
                    uv:       { itemSize: 2, type: "Float32Array", array: [ 0,0, 1,0, 0,1, 1,1 ] }
                },
                index: { itemSize: 1, type: "Uint16Array", array: [ 0,1,2, 2,1,3 ] }
            }
        }
    ],
    materials: [
        { uuid: "mat-basic", type: "MeshBasicMaterial", name: "flat", color: 255 }
    ],
    object: {
        uuid: "m-matrix",
        type: "Mesh",
        name: "matrix-mesh",
        geometry: "geo-cube",
        material: "mat-basic",
        matrix: [ 1,0,0,0, 0,1,0,0, 0,0,1,0, 5,6,7,1 ],
        matrixAutoUpdate: false
    }
};
var m3:Mesh = Mesh(loader.parse(matrixJson));
check("matrix mesh name", m3.name == "matrix-mesh");
check("matrix mesh m03", m3.matrix.elements[12] == 5);
check("matrix mesh m13", m3.matrix.elements[13] == 6);
check("matrix mesh m23", m3.matrix.elements[14] == 7);
check("matrix mesh matrixAutoUpdate", m3.matrixAutoUpdate == false);

// ---- 6) JSON.parse path ----
// The object-literal tests above exercise the deserializer on native AS3
// objects. Real ObjectLoader.load goes through JSON.parse, whose records have a
// different runtime representation (as_object boxes). Pin that path with a
// compact string envelope: 1 quad geometry, 1 standard material, a
// Scene->Group->Mesh tree and two lights (with the front-lit position used by
// the loader-scene demo).
var jsonText:String =
    '{"metadata":{"version":4.5,"type":"Object"},"geometries":[' +
    '{"uuid":"g1","type":"BufferGeometry","data":{"attributes":{' +
    '"position":{"itemSize":3,"type":"Float32Array","array":[0,0,0,1,0,0,0,1,0,1,1,0]},' +
    '"normal":{"itemSize":3,"type":"Float32Array","array":[0,0,1,0,0,1,0,0,1,0,0,1]},' +
    '"uv":{"itemSize":2,"type":"Float32Array","array":[0,0,1,0,0,1,1,1]}},' +
    '"index":{"itemSize":1,"type":"Uint16Array","array":[0,1,2,2,1,3]}}}],' +
    '"materials":[{"uuid":"m1","type":"MeshStandardMaterial","name":"blue",' +
    '"color":3366527,"roughness":0.3,"metalness":0.1,"emissive":0,"emissiveIntensity":1}],' +
    '"object":{"uuid":"root","type":"Scene","name":"Scene","children":[' +
    '{"uuid":"grp","type":"Group","name":"holder","children":[' +
    '{"uuid":"mesh","type":"Mesh","name":"cube","geometry":"g1","material":"m1"}' +
    ']},' +
    '{"uuid":"sun","type":"DirectionalLight","color":16777215,"intensity":1.0,"position":[0,1,3]},' +
    '{"uuid":"amb","type":"AmbientLight","color":16777215,"intensity":0.15}' +
    ']}}';
var parsed:Object = JSON.parse(jsonText);
var pScene:Scene = Scene(loader.parse(parsed));
check("json scene children", pScene.children.length == 3);
check("json scene uuid", pScene.uuid == "root");
var pGroup:Group = Group(pScene.children[0]);
var pMesh:Mesh = Mesh(pGroup.children[0]);
check("json mesh name", pMesh.name == "cube");
check("json mesh geometry pos", pMesh.geometry.getAttribute("position").count == 4);
check("json mesh geometry idx", pMesh.geometry.index.count == 6);
check("json mesh material color", MeshStandardMaterial(pMesh.material).color.getHex() == 3366527);
check("json mesh material rough", MeshStandardMaterial(pMesh.material).roughness == 0.3);
var pSun:DirectionalLight = DirectionalLight(pScene.children[1]);
check("json dir light pos x", pSun.position.x == 0);
check("json dir light pos y", pSun.position.y == 1);
check("json dir light pos z", pSun.position.z == 3);
check("json dir light intensity", pSun.intensity == 1.0);
check("json amb intensity", AmbientLight(pScene.children[2]).intensity == 0.15);

// ---- BoxGeometry winding pin (M4 regression): the loader-scene demo JSON must
// match BoxGeometry.as byte for byte -- the M3 demo shipped a hand-written
// vertex layout whose second triangle per face wound the wrong way, culling one
// triangle per face (only visible at some rotation angles). This pins the
// authoritative index sequence so authored JSON can be checked against it. ----
var refBox:BoxGeometry = new BoxGeometry(2, 2, 2);
var refIdx:BufferAttribute = refBox.getIndex();
var refPos:BufferAttribute = refBox.getAttribute("position");
check("box ref index count", refIdx.count == 36);
check("box ref first 6 idx", refIdx.getX(0) == 0 && refIdx.getX(1) == 2 && refIdx.getX(2) == 1 &&
      refIdx.getX(3) == 2 && refIdx.getX(4) == 3 && refIdx.getX(5) == 1);
check("box ref v0", refPos.getX(0) == 1 && refPos.getY(0) == 1 && refPos.getZ(0) == 1);
check("box ref v3", refPos.getX(3) == 1 && refPos.getY(3) == -1 && refPos.getZ(3) == -1);

// ---- Summary ----
trace("=== ObjectLoaderSmoke done, failed = " + failed + " ===");
if (failed == 0) trace("ALL PASS");
else trace("SOME FAILED");
