// gltf-smoke-m8.as -- M8 glTF 2.0 loader smoke (GLB envelope, accessors,
// primitives, materials, external buffers, texture decode, node transforms).
//
// Run from asaot3d/ with the same manifest as loader-smoke-m5 (ASC_USE_SKIA=1 +
// the Skia sources/libs), because glTF textures go through the same decode:
//   node ../as3compiler/src/index.ts probes/gltf-smoke-m8/gltf-smoke-m8.as \
//     $(find kit -name '*.as') --manifest probes/gltf-smoke-m8/gltf-smoke-m8.build.json \
//     -o temp/gltf-smoke-m8 --run
import asaot.three.core.BufferAttribute;
import asaot.three.core.BufferGeometry;
import asaot.three.core.Object3D;
import asaot.three.loaders.GLTFLoader;
import asaot.three.materials.Material;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.objects.Group;
import asaot.three.objects.Mesh;
import asaot.three.textures.Texture;

var failed:int = 0;
function check(cond:Boolean, msg:String):void
{
    if (cond) trace("PASS " + msg);
    else { trace("FAIL " + msg); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-4):Boolean
{
    return Math.abs(a - b) < eps;
}

// Depth-first search for the first Mesh under `root`.
function findMesh(root:Object3D):Mesh
{
    if (root is Mesh) return Mesh(root);
    var kids:Vector.<Object3D> = root.children;
    for (var i:int = 0; i < kids.length; i++)
    {
        var m:Mesh = findMesh(kids[i]);
        if (m != null) return m;
    }
    return null;
}

// ======================================================================
// 1. GLB: Duck.glb (binary container, embedded PNG texture, matrix nodes)
// ======================================================================
var duckRoot:Group = null;
var duckErr:String = "";
var duckLoader:GLTFLoader = new GLTFLoader();
duckLoader.load("assets/models/gltf/Duck.glb",
    function(root:Object3D):void { duckRoot = Group(root); },
    null,
    function(e:Object):void { duckErr = String(e); });
tickTimers();

check(duckErr == "", "Duck.glb loads without error (" + duckErr + ")");
check(duckRoot != null, "GLB parse delivers a root Group");
// scenes[0] has no name, so the Group keeps Object3D's empty default; the
// structural check is that exactly one scene node (the 0.01-scale root) hangs
// off it.
check(duckRoot.children.length == 1, "root Group has the single scene node (got " +
      duckRoot.children.length + ")");

var duckMesh:Mesh = findMesh(duckRoot);
check(duckMesh != null, "GLB scene contains a Mesh");

var duckGeo:BufferGeometry = duckMesh.geometry;
var duckPos:BufferAttribute = duckGeo.getAttribute("position");
check(duckPos != null && duckPos.count == 2399, "Duck position accessor is 2399 verts (got " +
      (duckPos != null ? duckPos.count : -1) + ")");
check(duckGeo.index != null && duckGeo.index.count == 12636, "Duck index accessor is 12636 (got " +
      (duckGeo.index != null ? duckGeo.index.count : -1) + ")");
check(duckGeo.getAttribute("normal") != null && duckGeo.getAttribute("normal").count == 2399,
      "Duck normals decoded");
check(duckGeo.getAttribute("uv") != null && duckGeo.getAttribute("uv").itemSize == 2,
      "Duck uv decoded as VEC2");

// Float32 little-endian decode check: the POSITION accessor's own min/max in the
// GLB JSON are [-69.29850006103516 .. 96.17990112304688] for x. A big-endian
// misread would produce garbage bounds, so this pins D41 (the readFloatLE
// workaround).
var minX:Number = 1e30;
var maxX:Number = -1e30;
for (var i:int = 0; i < duckPos.count; i++)
{
    var px:Number = duckPos.getX(i);
    if (px < minX) minX = px;
    if (px > maxX) maxX = px;
}
check(near(minX, -69.29850006103516, 1e-3) && near(maxX, 96.17990112304688, 1e-3),
      "position x bounds match the accessor min/max (" + minX + " .. " + maxX + ")");

// Node matrix: the Duck root node carries a 0.01 uniform scale (matrix path).
check(near(duckMesh.matrixWorld.elements[0], 0.01, 1e-6) ||
      near(duckRoot.children[0].scale.x, 0.01, 1e-6),
      "node matrix decomposed to a 0.01 uniform scale");

var duckMat:Material = duckMesh.material;
check(duckMat is MeshStandardMaterial, "Duck material is MeshStandardMaterial");
var duckStd:MeshStandardMaterial = MeshStandardMaterial(duckMat);
check(near(duckStd.metalness, 0.0), "Duck metallicFactor 0 applied (got " + duckStd.metalness + ")");
check(duckStd.map != null, "Duck baseColorTexture became material.map");
check(duckStd.map != null && duckStd.map.flipY == false, "glTF texture keeps flipY=false");

// ======================================================================
// 2. External buffer + external JPEG textures: DamagedHelmet.gltf
// ======================================================================
var helmRoot:Group = null;
var helmErr:String = "";
var helmLoader:GLTFLoader = new GLTFLoader();
helmLoader.load("assets/models/gltf/DamagedHelmet/DamagedHelmet.gltf",
    function(root:Object3D):void { helmRoot = Group(root); },
    null,
    function(e:Object):void { helmErr = String(e); });
tickTimers();

check(helmErr == "", "DamagedHelmet.gltf loads (external .bin fetched) (" + helmErr + ")");
check(helmRoot != null, "glTF-text parse delivers a root Group");

var helmMesh:Mesh = findMesh(helmRoot);
check(helmMesh != null, "DamagedHelmet contains a Mesh");
var helmGeo:BufferGeometry = helmMesh.geometry;
check(helmGeo.getAttribute("position").count == 14556, "helmet has 14556 verts (got " +
      helmGeo.getAttribute("position").count + ")");
check(helmGeo.index != null && helmGeo.index.count == 46356, "helmet index is 46356");
check(helmGeo.getAttribute("normal") != null, "helmet normals decoded");
check(helmGeo.getAttribute("uv") != null, "helmet uvs decoded");

var helmStd:MeshStandardMaterial = MeshStandardMaterial(helmMesh.material);
check(near(helmStd.metalness, 1.0) && near(helmStd.roughness, 1.0),
      "missing metallic/roughness factors default to 1 (" + helmStd.metalness + "/" + helmStd.roughness + ")");
check(helmStd.map != null, "baseColorTexture -> map");
check(helmStd.normalMap != null, "normalTexture -> normalMap");
check(helmStd.metalnessMap != null && helmStd.roughnessMap != null,
      "metallicRoughnessTexture feeds both metalnessMap and roughnessMap");
// Emissive/AO (M8 follow-up): the seam's standard program samples the
// emissive texel at fs5 and multiplies it by emissive*emissiveIntensity, so
// the glTF factor AND the emissiveTexture both have to land on the material.
// Getting only the factor (the pre-follow-up state) rendered the whole mesh as
// a white blob -- the identity-texel rule means "no map" == a white texel.
check(helmStd.emissiveMap != null, "emissiveTexture -> material.emissiveMap");
check(near(helmStd.emissive.r, 1.0) && near(helmStd.emissive.g, 1.0) && near(helmStd.emissive.b, 1.0),
      "emissiveFactor (1,1,1) kept alongside the emissive texture (" +
      helmStd.emissive.r + "," + helmStd.emissive.g + "," + helmStd.emissive.b + ")");
check(helmStd.aoMap != null, "occlusionTexture -> material.aoMap");
check(near(helmStd.aoMapIntensity, 1.0),
      "occlusionTexture.strength defaults to 1 (got " + helmStd.aoMapIntensity + ")");
// Assets without those maps must leave the slots null so the renderer binds
// the neutral white texel (ao=1, emissive texel=1) -- an unbound slot would
// leave the previous draw's texture in fs5/fs6.
check(duckStd.emissiveMap == null && duckStd.aoMap == null,
      "Duck (no emissive/occlusion maps) leaves fs5/fs6 unbound");
check(duckStd.emissive.r == 0 && duckStd.emissive.g == 0 && duckStd.emissive.b == 0,
      "Duck (no emissiveFactor) stays non-emissive");

// ======================================================================
// 3. Texture decode: the async image loads must land in the Texture objects
// ======================================================================
var decodeTicks:int = 0;
while (duckStd.map.image == null && decodeTicks < 40)
{
    tickTimers();
    decodeTicks++;
}
check(duckStd.map.image != null, "embedded PNG decoded into texture.image after " + decodeTicks + " ticks");
check(duckStd.map.image != null && duckStd.map.image.width > 0 && duckStd.map.image.height > 0,
      "decoded Duck texture has real dimensions (" +
      (duckStd.map.image != null ? duckStd.map.image.width + "x" + duckStd.map.image.height : "none") + ")");
check(duckStd.map.version > 0, "texture.needsUpdate bumped version (renderer re-uploads)");

var helmTicks:int = 0;
while (helmStd.map.image == null && helmTicks < 60)
{
    tickTimers();
    helmTicks++;
}
check(helmStd.map.image != null, "external JPEG decoded into texture.image after " + helmTicks + " ticks");
check(helmStd.normalMap != null && helmStd.normalMap.image != null, "normal map JPEG decoded");

// ======================================================================
// 4. Sampler mapping (Duck uses repeat + linear/linear-mipmap-linear)
// ======================================================================
check(duckStd.map.wrapS == Texture.RepeatWrapping, "sampler wrapS 10497 -> RepeatWrapping");
check(duckStd.map.wrapT == Texture.RepeatWrapping, "sampler wrapT 10497 -> RepeatWrapping");
check(duckStd.map.magFilter == Texture.LinearFilter, "sampler magFilter 9729 -> LinearFilter");
// Duck declares minFilter 9986 = NEAREST_MIPMAP_LINEAR.
check(duckStd.map.minFilter == Texture.NearestMipmapLinearFilter,
      "sampler minFilter 9986 -> NearestMipmapLinearFilter (got " + duckStd.map.minFilter + ")");

// ======================================================================
// 5. Accessor paths not covered by the two models: unindexed + sparse-free
//    integer normalization is exercised through a tiny inline glTF.
// ======================================================================
// data URI: 3 x VEC3 float32 positions (36 bytes) + 3 x ushort indices (6 bytes).
var inlineJson:Object = JSON.parse(
    '{"asset":{"version":"2.0"},' +
    '"buffers":[{"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAABAAIA"}],' +
    '"bufferViews":[' +
    '{"buffer":0,"byteOffset":0,"byteLength":36},' +
    '{"buffer":0,"byteOffset":36,"byteLength":6}],' +
    '"accessors":[' +
    '{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","max":[1,1,0],"min":[0,0,0]},' +
    '{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],' +
    '"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"mode":4}]}],' +
    '"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}');

var inlineRoot:Group = null;
var inlineLoader:GLTFLoader = new GLTFLoader();
inlineLoader.parse(inlineJson, "", function(root:Object3D):void { inlineRoot = Group(root); }, null);
check(inlineRoot != null, "inline glTF (data-URI buffer) parses");
var inlineMesh:Mesh = findMesh(inlineRoot);
check(inlineMesh != null, "inline scene contains a Mesh");
var inlinePos:BufferAttribute = inlineMesh.geometry.getAttribute("position");
check(inlinePos != null && inlinePos.count == 3, "data-URI buffer decoded: 3 vertices");
check(near(inlinePos.getX(1), 1.0) && near(inlinePos.getY(2), 1.0),
      "data-URI float32 components decoded little-endian (" + inlinePos.getX(1) + "," + inlinePos.getY(2) + ")");
check(inlineMesh.geometry.index != null && inlineMesh.geometry.index.count == 3,
      "data-URI ushort index buffer decoded");
check(inlineMesh.geometry.getAttribute("normal") != null,
      "missing normals are computed from the triangle");

trace("gltf-smoke-m8: " + (failed == 0 ? "ALL PASS" : failed + " FAILURES"));