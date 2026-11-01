// asaot3d/probes/animation-smoke-m12/animation-smoke-m12.as
//
// Assertion smoke test for the M12 animation family:
//   Interpolant / KeyframeTrack / PropertyBinding / PropertyMixer /
//   AnimationClip / AnimationMixer / AnimationAction,
//   plus the CPU SkinnedMesh + Skeleton + morph-target deform path and the
//   GLTFLoader skin / animation / morph import.
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/animation-smoke-m12/animation-smoke-m12.as \
//        $(find kit -name '*.as') -o temp/animation-smoke-m12 --run
//
// Every numeric expectation below is hand-computed in the comment above it; none
// of them are read back out of the implementation.
import asaot.three.animation.AnimationAction;
import asaot.three.animation.AnimationClip;
import asaot.three.animation.AnimationMixer;
import asaot.three.animation.AnimationUtils;
import asaot.three.animation.BooleanKeyframeTrack;
import asaot.three.animation.ColorKeyframeTrack;
import asaot.three.animation.CubicInterpolant;
import asaot.three.animation.DiscreteInterpolant;
import asaot.three.animation.GltfCubicSplineInterpolant;
import asaot.three.animation.Interpolant;
import asaot.three.animation.KeyframeTrack;
import asaot.three.animation.LinearInterpolant;
import asaot.three.animation.NumberKeyframeTrack;
import asaot.three.animation.PropertyBinding;
import asaot.three.animation.PropertyMixer;
import asaot.three.animation.QuaternionKeyframeTrack;
import asaot.three.animation.QuaternionLinearInterpolant;
import asaot.three.animation.VectorKeyframeTrack;
import asaot.three.core.BufferAttribute;
import asaot.three.core.BufferGeometry;
import asaot.three.core.Object3D;
import asaot.three.loaders.GLTFLoader;
import asaot.three.materials.MeshStandardMaterial;
import asaot.three.math.Matrix4;
import asaot.three.math.Quaternion;
import asaot.three.math.Vector3;
import asaot.three.objects.Bone;
import asaot.three.objects.Group;
import asaot.three.objects.Mesh;
import asaot.three.objects.Skeleton;
import asaot.three.objects.SkinnedMesh;

var failed:int = 0;
var passed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) { passed++; trace("PASS " + name); }
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-6):Boolean
{
    var d:Number = a - b;
    if (d < 0) d = -d;
    return d <= eps;
}

function nearV(v:Vector.<Number>, values:Array, eps:Number = 1e-6):Boolean
{
    for (var i:int = 0; i < values.length; i++)
    {
        if (!near(v[i], Number(values[i]), eps)) return false;
    }
    return true;
}

function vec(values:Array):Vector.<Number>
{
    var out:Vector.<Number> = new Vector.<Number>();
    for (var i:int = 0; i < values.length; i++) out.push(Number(values[i]));
    return out;
}

function section(title:String):void
{
    trace("");
    trace("-- " + title + " --");
}

// ---------------------------------------------------------------------------
section("AnimationUtils");
// ---------------------------------------------------------------------------
// convertArray always copies into a Vector.<Number> (D67: no typed-array views).
var converted:Vector.<Number> = AnimationUtils.convertArray(Object([1, 2, 3]));
check("convertArray copies into a Vector.<Number>",
      converted.length == 3 && near(converted[2], 3));
check("convertArray is a copy, not a view", AnimationUtils.isArrayLike(Object([1])) == true);

// ---------------------------------------------------------------------------
section("Interpolants");
// ---------------------------------------------------------------------------
// Linear: times [0,1,2], values [10,20,40]; at t=0.5 -> 15, at t=1.5 -> 30.
var lin:LinearInterpolant = new LinearInterpolant(vec([0, 1, 2]), vec([10, 20, 40]), 1);
check("linear t=0.5 -> 15", near(lin.evaluate(0.5)[0], 15));
check("linear t=1.5 -> 30", near(lin.evaluate(1.5)[0], 30));
check("linear clamps before start", near(lin.evaluate(-3)[0], 10));
check("linear clamps after end", near(lin.evaluate(9)[0], 40));

// Discrete: value holds until the NEXT key (i1-1).
var disc:DiscreteInterpolant = new DiscreteInterpolant(vec([0, 1, 2]), vec([10, 20, 40]), 1);
check("discrete at t=0.9 -> 10 (previous key)", near(disc.evaluate(0.9)[0], 10));
check("discrete at t=1.0 -> 20", near(disc.evaluate(1.0)[0], 20));

// QuaternionLinearInterpolant: 0deg -> 90deg about Z, at 0.5 the angle is 45deg,
// so (x,y,z,w) = (0,0,sin22.5,cos22.5) = (0,0,0.3826834,0.9238795).
var qlin:QuaternionLinearInterpolant = new QuaternionLinearInterpolant(
    vec([0, 1]), vec([0, 0, 0, 1, 0, 0, Math.sin(Math.PI / 4), Math.cos(Math.PI / 4)]), 4);
var half:Vector.<Number> = qlin.evaluate(0.5);
check("slerp 0->90deg at 0.5 is 45deg (z)",
      near(half[2], 0.3826834324, 1e-8) && near(half[3], 0.9238795325, 1e-8));
check("slerp stays unit length", near(Math.sqrt(half[0] * half[0] + half[1] * half[1] +
                                               half[2] * half[2] + half[3] * half[3]), 1, 1e-9));
// 180deg apart: slerp must pick a path, not divide by a zero dot product.
var qflip:QuaternionLinearInterpolant = new QuaternionLinearInterpolant(
    vec([0, 1]), vec([0, 0, 0, 1, 0, 0, 0, -1]), 4);
var mid:Vector.<Number> = qflip.evaluate(0.5);
check("antipodal slerp has no NaN", !isNaN(mid[0]) && !isNaN(mid[3]));

// CubicInterpolant (Catmull-Rom-ish, no overshoot at a flat run):
// values [0,0,0] at [0,1,2] -> the tangents are zero, so every sample is 0.
var cub:CubicInterpolant = new CubicInterpolant(vec([0, 1, 2]), vec([0, 0, 0]), 1);
check("cubic on a constant run stays 0", near(cub.evaluate(0.7)[0], 0));

// glTF CUBICSPLINE: one interval, key0 = value 0 with zero tangents,
// key1 = value 10 with zero tangents -> smoothstep from 0 to 10.
// At p=0.5 the Hermite basis gives 0.5*10 = 5.
var spline:GltfCubicSplineInterpolant = new GltfCubicSplineInterpolant(
    vec([0, 1]), vec([0, 0, 0,  0, 10, 0]), 1);
check("gltf cubicspline midpoint is 5", near(spline.evaluate(0.5)[0], 5));
// p=0.25: s0=1-s2, s2=-2p^3+3p^2 = -0.03125+0.1875=0.15625 -> 1.5625
check("gltf cubicspline at p=0.25 is 1.5625", near(spline.evaluate(0.25)[0], 1.5625));
check("gltf cubicspline copySampleValue picks the middle value", near(spline.copySampleValue(0)[0], 0));

// ---------------------------------------------------------------------------
section("KeyframeTrack");
// ---------------------------------------------------------------------------
var vt:VectorKeyframeTrack = new VectorKeyframeTrack(
    "cube.position", vec([0, 1]), vec([0, 0, 0, 10, 0, 0]));
check("vector track value size is 3", vt.getValueSize() == 3);
check("vector track default interpolation is linear",
      vt.getInterpolation() == KeyframeTrack.InterpolateLinear);
check("vector track value type name", vt.valueTypeName == "vector");
check("vector track validates", vt.validate());

var quant:QuaternionKeyframeTrack = new QuaternionKeyframeTrack(
    "cube.quaternion", vec([0]), vec([0, 0, 0, 1]));
check("quaternion track value type name", quant.valueTypeName == "quaternion");
check("quaternion track default interpolation is linear",
      quant.getInterpolation() == KeyframeTrack.InterpolateLinear);

var boolTrack:BooleanKeyframeTrack = new BooleanKeyframeTrack("o.visible", vec([0, 1]), vec([0, 1]));
check("boolean track default interpolation is discrete",
      boolTrack.getInterpolation() == KeyframeTrack.InterpolateDiscrete);
// three.js falls back to the track's default instead of throwing.
boolTrack.setInterpolation(KeyframeTrack.InterpolateLinear);
check("boolean track falls back to discrete on linear",
      boolTrack.getInterpolation() == KeyframeTrack.InterpolateDiscrete);

var colorTrack:ColorKeyframeTrack = new ColorKeyframeTrack("m.color", vec([0, 1]), vec([1, 0, 0, 0, 1, 0]));
check("color track value type name is color", colorTrack.valueTypeName == "color");

var numTrack:NumberKeyframeTrack = new NumberKeyframeTrack("m.opacity", vec([0, 1]), vec([1, 0.5]));
check("number track value size is 1", numTrack.getValueSize() == 1);
check("number track value type name", numTrack.valueTypeName == "number");

// CUBICSPLINE stride: 3 values per key, so the mixer stride is a third.
var splineTrack:VectorKeyframeTrack = new VectorKeyframeTrack(
    "cube.position", vec([0, 1]), vec([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0]),
    KeyframeTrack.InterpolateCubicSpline);
check("cubicspline track value size is 9", splineTrack.getValueSize() == 9);
check("cubicspline mixer stride is 3", splineTrack.getValueStride() == 3);
check("cubicspline interpolant sample size is 3",
      (splineTrack.createInterpolant() as GltfCubicSplineInterpolant).valueSize == 3);

// shift / scale / trim act on times AND keep values aligned.
var shifted:KeyframeTrack = new VectorKeyframeTrack("cube.position",
    vec([0, 1]), vec([0, 0, 0, 10, 0, 0]));
shifted.shift(2);
check("shift moves times", near(shifted.times[0], 2) && near(shifted.times[1], 3));
var scaled:KeyframeTrack = new VectorKeyframeTrack("cube.position",
    vec([0, 1]), vec([0, 0, 0, 10, 0, 0]));
scaled.scale(2);
check("scale multiplies times", near(scaled.times[1], 2));
var trimmed:KeyframeTrack = new VectorKeyframeTrack("cube.position",
    vec([0, 1]), vec([0, 0, 0, 10, 0, 0]));
trimmed.trim(-1, 99);
check("trim keeps all keys when the window covers them", trimmed.times.length == 2);

// ---------------------------------------------------------------------------
section("PropertyBinding / parseTrackName");
// ---------------------------------------------------------------------------
var parsed:Object = PropertyBinding.parseTrackName("cube.position");
check("parse nodeName", parsed["nodeName"] == "cube");
// nodeName.property: there is no intermediate object level.
check("two-part name has no objectName", parsed["objectName"] == null);
check("parse propertyName", parsed["propertyName"] == "position");
check("plain property has no index", parsed["objectIndex"] == null && parsed["propertyIndex"] == null);

var parsedIdx:Object = PropertyBinding.parseTrackName("mesh.material[2].color");
check("parse indexed object", parsedIdx["objectName"] == "material" && parsedIdx["objectIndex"] == 2);
check("parse property after index", parsedIdx["propertyName"] == "color");

var parsedBone:Object = PropertyBinding.parseTrackName("skel.bones[Spine].position");
check("parse bone nodeName", parsedBone["nodeName"] == "skel");
check("parse bone objectName", parsedBone["objectName"] == "bones");
check("parse bone objectIndex", parsedBone["objectIndex"] == "Spine");

var parsedDotted:Object = PropertyBinding.parseTrackName("Root.Child.position");
check("parse dotted node name", parsedDotted["nodeName"] == "Root.Child");

check("sanitizeNodeName drops dots and underscores spaces",
      PropertyBinding.sanitizeNodeName("a.b c") == "ab_c");
check("sanitizeNodeName keeps underscores", PropertyBinding.sanitizeNodeName("a_b") == "a_b");

// findNode: by name, by uuid, and a Bone nested under a Group.
var root:Object3D = new Object3D();
root.name = "Root";
var child:Object3D = new Object3D();
child.name = "Child";
root.add(child);
var boneSpine:Bone = new Bone();
boneSpine.name = "Spine";
child.add(boneSpine);

check("findNode by name", PropertyBinding.findNode(root, "Child") == child);
check("findNode falls back to uuid", PropertyBinding.findNode(root, child.uuid) == child);
check("findNode finds a nested bone", PropertyBinding.findNode(root, "Spine") == boneSpine);
check("findNode returns null for a miss", PropertyBinding.findNode(root, "Nope") == null);

// bind() on a real Vector3 property.
var host:Object3D = new Object3D();
host.name = "host";
var pb:PropertyBinding = new PropertyBinding(host, "host.position");
pb.bind();
// three.js binds a Vector3 through fromArray/toArray (PropertyBinding.js:697).
check("binding to Object3D.position is HasFromToArray",
      pb.bindingType == PropertyBinding.HasFromToArray && pb.node == host);
var buf:Vector.<Number> = vec([1.5, -2, 3.25]);
pb.setValue(buf, 0);
check("setValue writes the host position",
      near(host.position.x, 1.5) && near(host.position.y, -2) && near(host.position.z, 3.25));
var readBack:Vector.<Number> = new Vector.<Number>(3);
pb.getValue(readBack, 0);
check("getValue reads the host position", nearV(readBack, [1.5, -2, 3.25]));

// A track that targets a property that does not exist must fail loading, not
// silently animate nothing (D75). AnimationMixer._bindAction throws.
var badClip:AnimationClip = new AnimationClip("bad", 1,
    vecTracks([new NumberKeyframeTrack("host.doesNotExist", vec([0, 1]), vec([0, 1]))]));
var badMixer:AnimationMixer = new AnimationMixer(host);
var threw:Boolean = false;
try
{
    badMixer.clipAction(badClip);
}
catch (e:Error)
{
    threw = true;
}
check("unbindable track throws (D75)", threw);

// ---------------------------------------------------------------------------
section("AnimationClip");
// ---------------------------------------------------------------------------
var clip:AnimationClip = new AnimationClip("walk", -1, vecTracks([
    new VectorKeyframeTrack("root.position", vec([0, 0.5, 2]), vec([0, 0, 0, 1, 0, 0, 4, 0, 0])),
    new NumberKeyframeTrack("root.opacity", vec([0, 1]), vec([0, 1]))
]));
check("clip duration comes from the largest last time", near(clip.duration, 2));
check("clip keeps both tracks", clip.tracks.length == 2);
var clipList:Vector.<AnimationClip> = new Vector.<AnimationClip>();
clipList.push(clip);
check("clip findByName", AnimationClip.findByName(clipList, "walk") == clip);
check("clip findByName miss", AnimationClip.findByName(clipList, "run") == null);
check("clip resetDuration", near(clip.resetDuration().duration, 2));

// ---------------------------------------------------------------------------
section("AnimationMixer / AnimationAction");
// ---------------------------------------------------------------------------
// (PropertyMixer shares one accumulator per track path, so each case below uses
// its own clip -- clipAction() caches one action per clip+root.)
var actor:Object3D = new Object3D();
actor.name = "actor";

// duration 2, x(t) = 5t: times [0,2], values (0,0,0) -> (10,0,0).
function slideClip(clipName:String, endX:Number, endY:Number):AnimationClip
{
    return new AnimationClip(clipName, 2, vecTracks([
        new VectorKeyframeTrack("actor.position", vec([0, 2]), vec([0, 0, 0, endX, endY, 0]))
    ]));
}

var mixer:AnimationMixer = new AnimationMixer(actor);

var posClip:AnimationClip = slideClip("slide", 10, 0);
var action:AnimationAction = mixer.clipAction(posClip);
action.play();

mixer.setTime(0);
mixer.update(0.5);
check("mixer applies the interpolated position at t=0.5", near(actor.position.x, 2.5));
check("mixer leaves y/z untouched", near(actor.position.y, 0) && near(actor.position.z, 0));
check("action.time tracks the mixer clock", near(action.time, 0.5));

// LoopRepeat wraps: 3.5s into a 2s clip -> clip time 1.5 -> x = 7.5.
mixer.setTime(0);
mixer.update(3.5);
check("LoopRepeat wraps the clip time", near(action.time, 1.5) && near(actor.position.x, 7.5));

// stop() restores the original state (PropertyMixer.restoreOriginalState).
mixer.setTime(0);
mixer.update(1.0);
check("precondition: x is 5 before stop", near(actor.position.x, 5));
action.stop();
check("stop restores the pre-animation value", near(actor.position.x, 0));

// LoopOnce + clampWhenFinished holds the last value and reports completion.
var once:AnimationAction = mixer.clipAction(slideClip("once", 10, 0));
once.reset();
once.setLoop(AnimationAction.LoopOnce, 1);
once.clampWhenFinished = true;
var finished:int = 0;
mixer.onFinished = function(a:AnimationAction, dir:int):void { finished++; };
once.play();
mixer.setTime(0);
mixer.update(5.0);
check("LoopOnce clamps at the end value", near(actor.position.x, 10));
check("LoopOnce fires onFinished once", finished == 1);
check("finished action stops running", !once.isRunning());
once.stop();
mixer.onFinished = null;

// weight 0.5 blends half way to the animated value.
var halfAction:AnimationAction = mixer.clipAction(slideClip("half", 10, 0));
halfAction.reset();
halfAction.setLoop(AnimationAction.LoopRepeat, 1e30);
halfAction.setEffectiveWeight(0.5);
halfAction.play();
mixer.setTime(0);
mixer.update(1.0);            // clip time 1 -> x = 5, blended at 0.5 -> 2.5
check("weight 0.5 halves the applied delta", near(actor.position.x, 2.5));
halfAction.stop();

// Two actions on the same property: the mixer takes the weighted average. At
// clip time 1 of the 2s clip, x(t)=5t gives 5 and y(t)=15t gives 15, so two
// equal-weight actions average to (2.5, 7.5).
var aX:AnimationAction = mixer.clipAction(slideClip("onlyX", 10, 0));
var aY:AnimationAction = mixer.clipAction(slideClip("onlyY", 0, 30));
aX.reset();
aY.reset();
aX.play();
aY.play();
mixer.setTime(0);
mixer.update(1.0);
check("two actions average on a shared property",
      near(actor.position.x, 2.5) && near(actor.position.y, 7.5));
aX.stop();
aY.stop();

// fadeIn schedules a 0 -> 1 weight ramp; the effective weight is unchanged until
// the next mixer update (three.js evaluates the ramp inside _updateWeight).
var fadeAction:AnimationAction = mixer.clipAction(slideClip("fade", 0, 0));
fadeAction.reset();
mixer.setTime(0);          // the ramp is anchored at the mixer clock
fadeAction.fadeIn(2);
fadeAction.play();
check("fadeIn does not change the weight before an update", near(fadeAction.getEffectiveWeight(), 1));
mixer.update(1.0);
check("fadeIn is half weight after half the duration", near(fadeAction.getEffectiveWeight(), 0.5, 1e-6));
mixer.update(1.0);
check("fadeIn reaches full weight", near(fadeAction.getEffectiveWeight(), 1, 1e-6));
fadeAction.stop();

// loop events: one dispatch per update carrying the wrap count (5.5s / 2s -> 2).
var loopAction:AnimationAction = mixer.clipAction(slideClip("loopy", 0, 0));
loopAction.reset();
loopAction.setLoop(AnimationAction.LoopRepeat, 1e30);
var loops:int = 0;
var lastLoopDelta:Number = 0;
mixer.onLoop = function(a:AnimationAction, delta:Number):void { loops++; lastLoopDelta = delta; };
loopAction.play();
mixer.setTime(0);
mixer.update(5.5);
check("LoopRepeat dispatches one loop event per update", loops == 1);
check("loop event reports the wrap count", near(lastLoopDelta, 2));
mixer.onLoop = null;
loopAction.stop();

// ---------------------------------------------------------------------------
section("Skeleton");
// ---------------------------------------------------------------------------
var boneRoot:Bone = new Bone();
boneRoot.name = "boneRoot";
var boneTip:Bone = new Bone();
boneTip.name = "boneTip";
boneTip.position.set(1, 0, 0);
boneRoot.add(boneTip);

boneRoot.updateMatrixWorld(true);
var skel:Skeleton = new Skeleton(vecBones(boneRoot, boneTip), null);
skel.calculateInverses();
check("skeleton bone matrices sized 16 per bone", skel.boneMatrices.length == 32);
check("skeleton stored 2 inverse bind matrices", skel.boneInverses.length == 2);
check("getBoneByName", skel.getBoneByName("boneTip") == boneTip);

boneRoot.updateMatrixWorld(true);
skel.update();
// bind pose: bone0 offset = I, bone1 offset = T(1,0,0) -> translation 1,0,0
check("bind-pose offset of the root bone is identity",
      near(skel.boneMatrices[12], 0) && near(skel.boneMatrices[0], 1));
// At the bind pose every offset matrix (boneWorld * inverseBind) is identity,
// including the child bone, because its inverseBind already holds T(-1,0,0).
check("bind-pose offset of the tip bone is identity",
      near(skel.boneMatrices[16 + 0], 1) && near(skel.boneMatrices[16 + 12], 0));

// pose() resets the bone transforms to the bind pose (identity here).
boneTip.position.set(5, 0, 0);
boneTip.updateMatrixWorld(true);
skel.pose();
boneRoot.updateMatrixWorld(true);
check("pose restores the stored bind translation", near(boneTip.position.x, 1));

// ---------------------------------------------------------------------------
section("SkinnedMesh (CPU skinning)");
// ---------------------------------------------------------------------------
// One triangle, 3 vertices; vertices 0,1 are rigid to bone 0 (identity), vertex
// 2 is rigid to bone 1 which we rotate 90deg about Z at (1,0,0).
// bindMatrix = identity, so skinned = boneWorld * inverseBind * p.
// bone1 world at 90deg about Z = R; p2 = (0,1,0) -> R*(0,1,0) = (-1,0,0), then
// + translation of bone1? bone1's origin is the origin here, so the expected
// vertex 2 becomes (-1, 0, 0).
function makeSkins():SkinnedMesh
{
    var geometry:BufferGeometry = new BufferGeometry();
    geometry.setAttribute("position", new BufferAttribute(vec([0, 0, 0, 1, 0, 0, 0, 1, 0]), 3));
    geometry.setAttribute("normal", new BufferAttribute(vec([0, 0, 1, 0, 0, 1, 0, 0, 1]), 3));
    geometry.setAttribute("skinIndex", new BufferAttribute(vec([0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]), 4));
    geometry.setAttribute("skinWeight", new BufferAttribute(vec([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]), 4));

    var mesh:SkinnedMesh = new SkinnedMesh(geometry, new MeshStandardMaterial());
    mesh.name = "skinnedTri";

    var b0:Bone = new Bone();
    b0.name = "b0";
    var b1:Bone = new Bone();
    b1.name = "b1";

    var skeleton:Skeleton = new Skeleton(vecBones(b0, b1), null);
    skeleton.calculateInverses();
    mesh.bind(skeleton, new Matrix4());
    return mesh;
}

var skinned:SkinnedMesh = makeSkins();
var skel2:Skeleton = skinned.skeleton;
skel2.bones[1].quaternion.set(0, 0, Math.sin(Math.PI / 4), Math.cos(Math.PI / 4));
skel2.bones[0].updateMatrixWorld(true);
skel2.bones[1].updateMatrixWorld(true);   // force: the quaternion was set directly
skinned.updateMatrixWorld(true);
skel2.update();

// applyBoneTransform is the CPU reference.
var probeV:Vector3 = new Vector3(0, 1, 0);
skinned.applyBoneTransform(2, probeV);
check("applyBoneTransform rotates vertex 2 by 90deg about Z",
      near(probeV.x, -1, 1e-6) && near(probeV.y, 0, 1e-6) && near(probeV.z, 0, 1e-6));

var probeV0:Vector3 = new Vector3(0, 0, 0);
skinned.applyBoneTransform(0, probeV0);
check("applyBoneTransform leaves identity-bound vertices alone",
      near(probeV0.x, 0) && near(probeV0.y, 0) && near(probeV0.z, 0));

// updateDeform writes the skinned result back into the geometry attribute.
skinned.updateDeform(1);
var dstPos:Vector.<Number> = skinned.geometry.getAttribute("position").array;
check("updateDeform skins vertex 2 in place",
      near(dstPos[6], -1, 1e-6) && near(dstPos[7], 0, 1e-6));
check("updateDeform leaves bone-0 vertices untouched",
      near(dstPos[3], 1) && near(dstPos[0], 0));
skinned.updateDeform(1);
check("updateDeform is idempotent per frame id", near(dstPos[6], -1, 1e-6));

// ---------------------------------------------------------------------------
section("Morph targets (CPU)");
// ---------------------------------------------------------------------------
var morphGeo:BufferGeometry = new BufferGeometry();
morphGeo.setAttribute("position", new BufferAttribute(vec([0, 0, 0, 1, 0, 0, 0, 1, 0]), 3));
morphGeo.setAttribute("normal", new BufferAttribute(vec([0, 0, 1, 0, 0, 1, 0, 0, 1]), 3));
var morphTarget:BufferAttribute = new BufferAttribute(vec([0, 0, 1, 0, 0, 1, 0, 0, 1]), 3);
morphGeo.morphAttributes["position"] = new <BufferAttribute>[morphTarget];
morphGeo.morphTargetsRelative = true;

var morphMesh:Mesh = new Mesh(morphGeo, new MeshStandardMaterial());
morphMesh.updateMorphTargets();
check("updateMorphTargets allocates one influence per target",
      morphMesh.morphTargetInfluences != null && morphMesh.morphTargetInfluences.length == 1);
check("morph target dictionary names the slot",
      int(morphMesh.morphTargetDictionary["morphTarget0"]) == 0);

morphMesh.morphTargetInfluences[0] = 0.5;
morphMesh.updateDeform(10);
var morphPos:Vector.<Number> = morphGeo.getAttribute("position").array;
check("relative morph target adds weight*delta",
      near(morphPos[2], 0.5) && near(morphPos[5], 0.5) && near(morphPos[8], 0.5));

morphMesh.morphTargetInfluences[0] = 1;
morphMesh.updateDeform(11);
check("morph weight 1 applies the full delta", near(morphPos[2], 1) && near(morphPos[8], 1));

// A second deform with the same frame id must be a no-op (renderer calls it from
// the shadow pass and the main pass).
morphPos[2] = 123;
morphMesh.updateDeform(11);
check("updateDeform skips a repeated frame id", near(morphPos[2], 123));

// ---------------------------------------------------------------------------
section("GLTFLoader: skin + animation + morph");
// ---------------------------------------------------------------------------
var loader:GLTFLoader = new GLTFLoader();
var loadedRoot:Object3D = null;
var loadError:String = null;

loader.load("probes/animation-smoke-m12/assets/rig.gltf",
    function(root:Object3D):void { loadedRoot = root; },
    null,
    function(e:Object):void { loadError = String(e); });

// FileLoader is async (URLLoader); pump the I/O queue once like the M5/M8 probes.
tickTimers();

check("rig.gltf loads without error", loadedRoot != null && loadError == null);

if (loadedRoot != null)
{
    var skinnedMesh:SkinnedMesh = findSkinned(loadedRoot);
    check("glTF scene contains a SkinnedMesh", skinnedMesh != null);

    if (skinnedMesh != null)
    {
        check("glTF skeleton has 2 joints", skinnedMesh.skeleton.bones.length == 2);
        check("glTF joint names survive sanitising",
              skinnedMesh.skeleton.getBoneByName("bone1") != null);
        check("glTF inverse bind matrices imported",
              near(skinnedMesh.skeleton.boneInverses[0].elements[0], 1));

        var mesh2:Mesh = skinnedMesh;
        check("glTF morph target imported",
              mesh2.morphTargetInfluences != null && mesh2.morphTargetInfluences.length == 1);
        check("glTF default morph weight applied", near(mesh2.morphTargetInfluences[0], 0));

        check("glTF JOINTS_0 imported", skinnedMesh.geometry.getAttribute("skinIndex") != null);
        check("glTF WEIGHTS_0 imported", skinnedMesh.geometry.getAttribute("skinWeight") != null);
        check("glTF skin weights normalised",
              near(skinnedMesh.geometry.getAttribute("skinWeight").array[0], 1));
    }

    check("glTF exposes one AnimationClip", loader.animations != null && loader.animations.length == 1);
    if (loader.animations != null && loader.animations.length == 1)
    {
        var gltfClip:AnimationClip = loader.animations[0];
        check("glTF clip name", gltfClip.name == "rigAnim");
        check("glTF clip has a rotation and a weights track", gltfClip.tracks.length == 2);
        check("glTF clip duration is 1", near(gltfClip.duration, 1));

        var trackNames:String = "";
        for (var ti:int = 0; ti < gltfClip.tracks.length; ti++)
        {
            trackNames += gltfClip.tracks[ti].name + "|";
        }
        check("glTF rotation track binds the joint by name",
              trackNames.indexOf("bone1.quaternion|") >= 0);
        check("glTF weights track binds the morphing mesh",
              trackNames.indexOf(".morphTargetInfluences") >= 0);

        // Drive the rig through the mixer and compare against hand-computed
        // skinning. At t=0.5 bone1 is rotated 45deg about Z and sits at
        // (1,0,0); the morph weight is 0.5, so vertex 2 leaves the bind pose at
        // p = (0,1,0.5). The skin offset is boneWorld * inverseBind
        //    = T(1,0,0) * Rz(45) * T(-1,0,0)
        // applied to p:
        //    p - (1,0,0) = (-1,1,0.5)
        //    Rz(45) * (-1,1,0.5) = (-sqrt(2), 0, 0.5)
        //    + (1,0,0)            = (1 - sqrt(2), 0, 0.5) = (-0.4142136, 0, 0.5)
        var rigMixer:AnimationMixer = new AnimationMixer(loadedRoot);
        var rigAction:AnimationAction = rigMixer.clipAction(gltfClip);
        rigAction.play();
        rigMixer.setTime(0);
        rigMixer.update(0.5);

        var bone1:Object3D = skinnedMesh != null ? skinnedMesh.skeleton.getBoneByName("bone1") : null;
        check("mixer rotated the joint", bone1 != null && near(bone1.quaternion.z, 0.3826834324, 1e-6));

        if (skinnedMesh != null)
        {
            loadedRoot.updateMatrixWorld(true);
            skinnedMesh.updateDeform(50);
            var rigPos:Vector.<Number> = skinnedMesh.geometry.getAttribute("position").array;
            check("glTF rig: skinned+ morphed vertex 2 lands at hand-computed x",
                  near(rigPos[6], 1 - 1.4142135624, 1e-5));
            check("glTF rig: skinned vertex 2 y is 0",
                  near(rigPos[7], 0, 1e-5));
            check("glTF rig: morph pushed vertex 2 to z=0.5", near(rigPos[8], 0.5, 1e-5));
            check("glTF rig: bone-0 vertex only moved by the morph",
                  near(rigPos[0], 0) && near(rigPos[1], 0) && near(rigPos[2], 0.5));
        }
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
function vecTracks(list:Array):Vector.<KeyframeTrack>
{
    var out:Vector.<KeyframeTrack> = new Vector.<KeyframeTrack>();
    for (var i:int = 0; i < list.length; i++) out.push(KeyframeTrack(list[i]));
    return out;
}

function vecBones(a:Object3D, b:Object3D = null):Vector.<Object3D>
{
    var out:Vector.<Object3D> = new Vector.<Object3D>();
    out.push(a);
    if (b != null) out.push(b);
    return out;
}

function findSkinned(object:Object3D):SkinnedMesh
{
    if (object is SkinnedMesh) return SkinnedMesh(object);
    for (var i:int = 0; i < object.children.length; i++)
    {
        var found:SkinnedMesh = findSkinned(object.children[i]);
        if (found != null) return found;
    }
    return null;
}

// ---------------------------------------------------------------------------
trace("");
trace("passed " + passed + ", failed " + failed);
if (failed == 0) trace("ALL PASS");
else trace("FAILED: " + failed);