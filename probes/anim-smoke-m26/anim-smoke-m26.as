// asaot3d/probes/anim-smoke-m26/anim-smoke-m26.as
//
// Assertion smoke test for M26:
//   * AnimationAction.crossFadeTo / crossFadeFrom / syncWith,
//   * the warp() / halt() time-scale ramp those depend on (D80 lifted),
//   * asaot.three.input.Keyboard (the Stage keyboard bridge's state table),
//   * SkeletonHelper (bone segments in root-local space, colour gradient,
//     root transform inheritance).
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/anim-smoke-m26/anim-smoke-m26.as \
//        $(find kit -name '*.as') -o temp/anim-smoke-m26 --run
//
// Every expectation below is hand-computed in the comment above it; none of them
// are read back out of the implementation. No GPU, no window: the keyboard probe
// drives a plain EventDispatcher and the helper is updated by hand.
import asaot.three.animation.AnimationAction;
import asaot.three.animation.AnimationClip;
import asaot.three.animation.AnimationMixer;
import asaot.three.animation.KeyframeTrack;
import asaot.three.animation.VectorKeyframeTrack;
import asaot.three.core.BufferAttribute;
import asaot.three.core.BufferGeometry;
import asaot.three.core.Object3D;
import asaot.three.helpers.SkeletonHelper;
import asaot.three.input.Keyboard;
import asaot.three.materials.LineBasicMaterial;
import asaot.three.math.Color;
import asaot.three.math.Matrix4;
import asaot.three.objects.Bone;
import asaot.three.objects.LineSegments;

import flash.events.Event;
import flash.events.EventDispatcher;
import flash.events.KeyboardEvent;

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

function vec(values:Array):Vector.<Number>
{
    var out:Vector.<Number> = new Vector.<Number>();
    for (var i:int = 0; i < values.length; i++) out.push(Number(values[i]));
    return out;
}

function vecTracks(list:Array):Vector.<KeyframeTrack>
{
    var out:Vector.<KeyframeTrack> = new Vector.<KeyframeTrack>();
    for (var i:int = 0; i < list.length; i++) out.push(KeyframeTrack(list[i]));
    return out;
}

function section(title:String):void
{
    trace("");
    trace("-- " + title + " --");
}

// A one-track clip of the given duration that slides `node` along +X.
function slideClip(nodeName:String, clipName:String, duration:Number,
                   endX:Number):AnimationClip
{
    return new AnimationClip(clipName, duration, vecTracks([
        new VectorKeyframeTrack(nodeName + ".position", vec([0, duration]),
                                vec([0, 0, 0, endX, 0, 0]))
    ]));
}

// ===========================================================================
section("crossFadeTo: weights sum to 1 across the window");
// ===========================================================================
// A: duration 2 (x goes 0 -> 20, i.e. 10 units/s). B: duration 1 (0 -> 4).
// Crossfade over 1 s starting at mixer time 0 with warp OFF:
//   t=0.5 -> A weight = 1 - 0.5 = 0.5, B weight = 0 + 0.5 = 0.5
//   x = 0.5 * (10*0.5) + 0.5 * (4*0.5) = 2.5 + 1 = 3.5
var actorA:Object3D = new Object3D();
actorA.name = "actorA";
var mixerA:AnimationMixer = new AnimationMixer(actorA);

var actionA:AnimationAction = mixerA.clipAction(slideClip("actorA", "slow", 2, 20));
var actionB:AnimationAction = mixerA.clipAction(slideClip("actorA", "fast", 1, 4));

actionA.play();
actionB.reset();
actionB.play();

// Both actions write the same single property, so PropertyMixer is shared and
// the two weights blend into one accumulator.
//
// `weight` is the TARGET the fade interpolant multiplies (three.js's
// executeCrossFade does `setWeight(endAction, 1)` before crossFadeTo for exactly
// this reason); the ramp itself starts at 0, so the fade-in contributes nothing
// on the first frame.
actionA.weight = 1;
actionB.weight = 1;
mixerA.setTime(0);

actionA.crossFadeTo(actionB, 1.0, false);

mixerA.setTime(0);
mixerA.update(0.5);

check("fade-out weight is 0.5 mid-window", near(actionA.getEffectiveWeight(), 0.5, 1e-9));
check("fade-in weight is 0.5 mid-window", near(actionB.getEffectiveWeight(), 0.5, 1e-9));
check("blend lands between the two clips", near(actorA.position.x, 3.5, 1e-9));
check("unwarped crossfade keeps both time scales at 1",
      near(actionA.timeScale, 1) && near(actionB.timeScale, 1));

// Past the end of the window the faded-out action is disabled and the faded-in
// action owns the property outright.
mixerA.update(0.6);
check("fade-out action is disabled after the window", !actionA.enabled);
check("fade-in action holds full weight", near(actionB.getEffectiveWeight(), 1, 1e-9));
// B has been running 1.1 s of its 1 s clip -> wrapped to 0.1 s -> x = 4*0.1/1 = 0.4
check("fade-in action drives the property alone", near(actorA.position.x, 0.4, 1e-9));

// ===========================================================================
section("crossFadeFrom: the mirror call is the same schedule");
// ===========================================================================
// crossFadeTo(a, d) == a.crossFadeFrom(this, d): fading B back into A must
// reproduce the same 0.5/0.5 split.
//
// The previous window left A disabled (a completed fadeOut disables the action,
// see _updateWeight) and B at full weight, so both are re-armed first -- the same
// `play()` + `setWeight(1)` step three.js's executeCrossFade performs before every
// transition.
actorA.position.set(0, 0, 0);
actionA.reset();
actionA.play();
actionA.weight = 1;
actionB.reset();
actionB.play();
actionB.weight = 1;
// The fade window is scheduled on the mixer clock at CALL time, so the clock is
// rewound first (scheduling at t=1.1 and then rewinding would put the window in
// the future and clamp both weights to 0).
mixerA.setTime(0);
actionB.crossFadeFrom(actionA, 1.0, false);
mixerA.update(0.5);
check("crossFadeFrom fades the target out to 0.5", near(actionA.getEffectiveWeight(), 0.5, 1e-9));
check("crossFadeFrom fades the caller in to 0.5", near(actionB.getEffectiveWeight(), 0.5, 1e-9));

// ===========================================================================
section("crossFadeTo(warp = true): duration ratios reach the time scales");
// ===========================================================================
// A has duration 2, B has duration 1.
//   fadeInAction (B).warp(endStartRatio = 1/2 = 0.5 -> 1.0)
//   fadeOutAction(A).warp(1.0 -> startEndRatio = 2/1 = 2.0)
// Both ramps are linear over 1 s, read at the MIDDLE of the window -> 0.75 and
// 1.5 respectively (the interpolant multiplies the action's own timeScale).
var actorW:Object3D = new Object3D();
actorW.name = "actorW";
var mixerW:AnimationMixer = new AnimationMixer(actorW);
var wSlow:AnimationAction = mixerW.clipAction(slideClip("actorW", "slowW", 2, 20));
var wFast:AnimationAction = mixerW.clipAction(slideClip("actorW", "fastW", 1, 4));
wSlow.play();
wFast.play();
wFast.weight = 1;
mixerW.setTime(0);

wSlow.crossFadeTo(wFast, 1.0, true);
mixerW.setTime(0);
mixerW.update(0.5);

check("warp: fade-in time scale ramps 0.5 -> 1 (0.75 at mid)", near(wFast._effectiveTimeScale, 0.75, 1e-9));
check("warp: fade-out time scale ramps 1 -> 2 (1.5 at mid)", near(wSlow._effectiveTimeScale, 1.5, 1e-9));
check("warp: base timeScale is left alone while ramping",
      near(wFast.timeScale, 1) && near(wSlow.timeScale, 1));

// After the window the accumulated rate is folded into the base rate and the
// interpolant is returned to the mixer's pool.
mixerW.update(0.6);
check("warp: ramped rate folded into timeScale at the end", near(wFast.timeScale, 1, 1e-9));
check("warp: interpolant released at the end", wFast._timeScaleInterpolant == null);
check("warp: fade-out folded rate is 2", near(wSlow.timeScale, 2, 1e-9));

// ===========================================================================
section("halt: ramp the current rate down to a full stop");
// ===========================================================================
var actorH:Object3D = new Object3D();
actorH.name = "actorH";
var mixerH:AnimationMixer = new AnimationMixer(actorH);
var hAction:AnimationAction = mixerH.clipAction(slideClip("actorH", "halt", 2, 20));
hAction.play();
hAction.setEffectiveTimeScale(2);
mixerH.setTime(0);
hAction.halt(1.0);
// halt = warp(effective, 0, d) => values 1.0 -> 0.0, midpoint 0.5 -> rate 1.0
mixerH.update(0.5);
check("halt ramps the effective rate toward 0", near(hAction._effectiveTimeScale, 1.0, 1e-9));
mixerH.update(0.6);
check("halt pauses the action when the rate reaches 0", hAction.paused);
hAction.stop();

// ===========================================================================
section("syncWith");
// ===========================================================================
var actorS:Object3D = new Object3D();
actorS.name = "actorS";
var mixerS:AnimationMixer = new AnimationMixer(actorS);
var srcAction:AnimationAction = mixerS.clipAction(slideClip("actorS", "src", 2, 20));
var dstAction:AnimationAction = mixerS.clipAction(slideClip("actorS", "dst", 2, 20));
srcAction.time = 1.7;
srcAction.timeScale = 2;
dstAction.syncWith(srcAction);
check("syncWith copies the playhead", near(dstAction.time, 1.7));
check("syncWith copies the rate", near(dstAction.timeScale, 2));

// ===========================================================================
section("Keyboard: state table");
// ===========================================================================
const KEY_W:int = 87;
const KEY_S:int = 83;
const KEY_SHIFT:int = 16;

var dispatcher:EventDispatcher = new EventDispatcher();
var kb:Keyboard = new Keyboard(dispatcher);

function keyDown(code:int, shift:Boolean = false):void
{
    dispatcher.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_DOWN, true, true, 0, code,
                                               0, false, false, shift, false, false, false));
}

function keyUp(code:int):void
{
    dispatcher.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_UP, true, false, 0, code));
}

check("nothing is down initially", !kb.isDown(KEY_W) && !kb.anyDown());
keyDown(KEY_W);
check("keyDown sets isDown", kb.isDown(KEY_W));
check("keyDown sets justPressed", kb.justPressed(KEY_W));
check("unrelated key stays up", !kb.isDown(KEY_S));
check("anyDown reports the held key", kb.anyDown());

kb.endFrame();
check("endFrame clears the edge, keeps the hold",
      !kb.justPressed(KEY_W) && kb.isDown(KEY_W));

keyDown(KEY_W);            // auto-repeat
check("auto-repeat does not double-count the hold", kb.anyDown() && kb.isDown(KEY_W));

// A tap that completes inside one frame must still report one press.
keyUp(KEY_W);
check("keyUp clears isDown", !kb.isDown(KEY_W));
check("dispersed press flag survives the release inside one frame", kb.justPressed(KEY_W));
kb.endFrame();
check("edge cleared on the next frame", !kb.justPressed(KEY_W));

// Two keys held at once: releasing one must not clear the other.
keyDown(KEY_W);
keyDown(KEY_SHIFT);
keyUp(KEY_W);
check("second key survives the first release", kb.isDown(KEY_SHIFT) && !kb.isDown(KEY_W));
check("anyDown still true with one key held", kb.anyDown());
keyUp(KEY_SHIFT);
check("anyDown false after the last release", !kb.anyDown());

// D148: focus loss resets a latched key (no keyUp ever arrives for it).
keyDown(KEY_W);
dispatcher.dispatchEvent(new Event(Event.DEACTIVATE, true, false));
check("DEACTIVATE releases held keys", !kb.isDown(KEY_W) && !kb.anyDown());

// Out-of-range codes are counted, not swallowed.
check("droppedKeys starts at 0", kb.droppedKeys == 0);
keyDown(300);
check("out-of-range keyCode is counted", kb.droppedKeys == 1);
check("out-of-range keyCode is not treated as down", !kb.isDown(300 % Keyboard.MAX_CODE));

// detach stops delivery.
kb.detach();
keyDown(KEY_W);
check("detach stops events reaching the table", !kb.isDown(KEY_W));

// ===========================================================================
section("SkeletonHelper: bone segments in root-local space");
// ===========================================================================
// root (Object3D) -> bone1 (0,1,0) -> bone2 (+1 in Y) -> bone3 (+1 in Y).
// Only bone2 and bone3 have a Bone PARENT, so the helper draws exactly 2
// segments: (bone2 -> bone1) and (bone3 -> bone2).
var root:Object3D = new Object3D();
var bone1:Bone = new Bone();
bone1.position.set(0, 1, 0);
var bone2:Bone = new Bone();
bone2.position.set(0, 1, 0);
var bone3:Bone = new Bone();
bone3.position.set(0, 1, 0);
root.add(bone1);
bone1.add(bone2);
bone2.add(bone3);

var helper:SkeletonHelper = new SkeletonHelper(root);
check("helper found every bone (root is not a Bone)", helper.bones.length == 3);
check("helper draws one segment per bone with a Bone parent",
      SkeletonHelper.segmentCount(helper.bones) == 2);
check("helper is a LineSegments", helper is LineSegments);

var posAttr:BufferAttribute = helper.geometry.getAttribute("position");
var colAttr:BufferAttribute = helper.geometry.getAttribute("color");
check("position attribute holds 2 segments x 2 vertices", posAttr.count == 4);
check("colour attribute matches the position count", colAttr.count == 4);

check("helper inherits the root transform by aliasing its matrix",
      helper.matrix == root.matrixWorld && !helper.matrixAutoUpdate);

root.updateMatrixWorld(true);
helper.updateMatrixWorld(true);

// Root is at the origin, so root-local == world here.
//   segment 0: bone2 (0,2,0) -> bone1 (0,1,0)
//   segment 1: bone3 (0,3,0) -> bone2 (0,2,0)
check("segment 0 starts at the child bone", near(posAttr.getX(0), 0) && near(posAttr.getY(0), 2) && near(posAttr.getZ(0), 0));
check("segment 0 ends at the parent bone", near(posAttr.getX(1), 0) && near(posAttr.getY(1), 1) && near(posAttr.getZ(1), 0));
check("segment 1 starts at bone3", near(posAttr.getY(2), 3));
check("segment 1 ends at bone2", near(posAttr.getY(3), 2));

// Default gradient: blue at the bone, green at its parent (three.js setColors).
check("default first colour is blue", near(colAttr.getX(0), 0) && near(colAttr.getY(0), 0) && near(colAttr.getZ(0), 1));
check("default second colour is green", near(colAttr.getX(1), 0) && near(colAttr.getY(1), 1) && near(colAttr.getZ(1), 0));

// Repaint: red at the bone, blue at the parent.
helper.setColors(new Color(0xff0000), new Color(0x0000ff));
check("setColors repaints the odd vertices", near(colAttr.getX(2), 1) && near(colAttr.getZ(2), 0));
check("setColors repaints the even vertices", near(colAttr.getZ(3), 1) && near(colAttr.getX(3), 0));

// The roots' own transform does NOT change the root-local positions, but it does
// move the object's matrixWorld -- which is what makes the helper follow a model
// placed somewhere in the scene.
root.position.set(10, 0, 0);
root.updateMatrixWorld(true);
helper.updateMatrixWorld(true);
check("root-local positions are unchanged by a root translation", near(posAttr.getY(0), 2));
check("helper matrixWorld follows the root", near(helper.matrixWorld.elements[12], 10, 1e-9));

// A bone rotation moves its descendants: rotating bone1 by 90deg about Z turns
// bone2's world offset from +Y into -X, so segment 0's child end goes to
// root-local (-1, 1, 0) relative to bone1's (0, 1, 0).
bone1.rotation.z = Math.PI * 0.5;
root.updateMatrixWorld(true);
helper.updateMatrixWorld(true);
check("rotating a bone moves the segment", near(posAttr.getX(0), -1, 1e-6) && near(posAttr.getY(0), 1, 1e-6));

// The bounding sphere is recomputed on every update (D150), so culling cannot
// use a stale extent.
check("bounding sphere tracks the current pose", helper.geometry.boundingSphere != null
      && helper.geometry.boundingSphere.radius > 0);

// Material flags three.js sets for a skeleton helper.
var helperMaterial:LineBasicMaterial = LineBasicMaterial(helper.material);
check("helper material is untested/unwritten", !helperMaterial.depthTest && !helperMaterial.depthWrite);
check("helper material uses vertex colours", helperMaterial.vertexColors);
check("helper material skips tone mapping", !helperMaterial.toneMapped);
check("helper material is transparent", helperMaterial.transparent);

// ===========================================================================
trace("");
trace("RESULT " + passed + " passed, " + failed + " failed");
if (failed > 0) throw new Error("anim-smoke-m26: " + failed + " assertion(s) failed");