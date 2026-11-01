// asaot.three.animation.AnimationMixer -- drives AnimationActions and writes
// their blended results into the scene graph.
//
// Borrows src/animation/AnimationMixer.js (r187):
//   * the mixer clock (`time`, `timeScale`) and the `_accuIndex ^= 1`
//     double-buffered accumulator hand-off between frames;
//   * `clipAction()`'s "one action per (clip, root)" cache;
//   * `_bindAction()`'s shared PropertyMixer per (root, trackName) so two actions
//     animating the same property blend into ONE accumulator;
//   * activate/deactivate with PropertyMixer useCount and
//     saveOriginalState()/restoreOriginalState() so stopping an action restores
//     the pre-animation pose (three.js semantics, easy to get wrong);
//   * the lent LinearInterpolant pool used by AnimationAction fadeIn/fadeOut.
//
// DIVERGENCES:
//   D79  'finished' / 'loop' are delivered to optional Function sinks
//        (onFinished / onLoop) instead of an EventDispatcher.
//   D81  The active/inactive array partition + `_cacheIndex` re-cycling is not
//        borrowed: actions and mixers here keep their PropertyMixers for their
//        whole lifetime (a Vector lookup instead of O(1) cache slots). The
//        observable behaviour is identical; only the allocation pattern differs.
//   D82  uncacheClip / uncacheRoot / uncacheAction are not borrowed (a demo
//        scene has a bounded clip set).
package asaot.three.animation
{
    import asaot.three.core.Object3D;

    import flash.utils.Dictionary;

    public class AnimationMixer
    {
        public var time:Number = 0;
        public var timeScale:Number = 1;

        // D79: event sinks (see three-api-design §17.3)
        public var onFinished:Function = null;
        public var onLoop:Function = null;

        private var _root:Object3D;

        private var _actions:Vector.<AnimationAction>;
        private var _activeActions:Vector.<AnimationAction>;
        private var _bindings:Vector.<PropertyMixer>;
        private var _activeBindings:Vector.<PropertyMixer>;

        private var _accuIndex:int = 0;

        // clipUuid -> { actionByRoot: Dictionary, knownActions: Vector }
        private var _actionsByClip:Dictionary;
        // rootUuid -> Dictionary(trackName -> PropertyMixer)
        private var _bindingsByRootAndName:Dictionary;

        private var _controlInterpolants:Vector.<Interpolant>;
        private var _nActiveControlInterpolants:int = 0;

        public function AnimationMixer(root:Object3D)
        {
            this._root = root;
            this._actions = new Vector.<AnimationAction>();
            this._activeActions = new Vector.<AnimationAction>();
            this._bindings = new Vector.<PropertyMixer>();
            this._activeBindings = new Vector.<PropertyMixer>();
            this._actionsByClip = new Dictionary();
            this._bindingsByRootAndName = new Dictionary();
            this._controlInterpolants = new Vector.<Interpolant>();
        }

        public function getRoot():Object3D
        {
            return this._root;
        }

        public function setTime(time:Number):AnimationMixer
        {
            this.time = 0;
            this._accuIndex = 0;

            var n:int = this._activeActions.length;
            for (var i:int = 0; i < n; i++) this._activeActions[i].time = 0;

            return this.update(time);
        }

        // AnimationMixer.js:update. Note the accumulator index flips BEFORE the
        // actions run, so `apply()` compares this frame's accumulator against the
        // previous frame's -- that comparison is how a binding avoids redundant
        // scene-graph writes.
        public function update(deltaTime:Number):AnimationMixer
        {
            deltaTime *= this.timeScale;

            var actions:Vector.<AnimationAction> = this._activeActions;
            var nActions:int = actions.length;

            this.time += deltaTime;

            var time:Number = this.time;
            var timeDirection:Number = (deltaTime < 0) ? -1 : ((deltaTime > 0) ? 1 : 0);

            this._accuIndex = this._accuIndex ^ 1;
            var accuIndex:int = this._accuIndex;

            for (var i:int = 0; i < nActions; i++)
            {
                actions[i]._update(time, deltaTime, timeDirection, accuIndex);
            }

            var bindings:Vector.<PropertyMixer> = this._activeBindings;
            var nBindings:int = bindings.length;
            for (var j:int = 0; j < nBindings; j++)
            {
                bindings[j].apply(accuIndex);
            }

            return this;
        }

        public function stopAllAction():AnimationMixer
        {
            var actions:Vector.<AnimationAction> = this._activeActions;

            for (var n:int = actions.length - 1; n >= 0; n--)
            {
                this._deactivateAction(actions[n]);
            }

            return this;
        }

        // ------------------------------------------------------------------
        // clipAction / activation
        // ------------------------------------------------------------------

        public function clipAction(clip:*, optionalRoot:Object3D = null, blendMode:int = -1):AnimationAction
        {
            var root:Object3D = (optionalRoot != null) ? optionalRoot : this._root;
            var rootUuid:String = root.uuid;

            var clipObject:AnimationClip = (clip is String) ? AnimationClip.findByName(root, String(clip)) : clip;
            if (clipObject == null) return null;

            var actionsForClip:Object = this._actionsByClip[clipObject.uuid];
            if (actionsForClip != null)
            {
                var existing:AnimationAction = actionsForClip["actionByRoot"][rootUuid];
                if (existing != null) return existing;
            }

            var newAction:AnimationAction = new AnimationAction(this, clipObject, optionalRoot);
            this._bindAction(newAction);

            if (actionsForClip == null)
            {
                actionsForClip = {
                    actionByRoot: new Dictionary(),
                    knownActions: new Vector.<AnimationAction>()
                };
                this._actionsByClip[clipObject.uuid] = actionsForClip;
            }

            actionsForClip["actionByRoot"][rootUuid] = newAction;
            var known:Vector.<AnimationAction> = actionsForClip["knownActions"];
            known.push(newAction);

            this._actions.push(newAction);

            return newAction;
        }

        private function _bindAction(action:AnimationAction):void
        {
            var root:Object3D = (action._localRoot != null) ? Object3D(action._localRoot) : this._root;
            var tracks:Vector.<KeyframeTrack> = action._clip.tracks;
            var nTracks:int = tracks.length;

            var bindingsByName:Dictionary = this._bindingsByRootAndName[root.uuid];
            if (bindingsByName == null)
            {
                bindingsByName = new Dictionary();
                this._bindingsByRootAndName[root.uuid] = bindingsByName;
            }

            for (var i:int = 0; i < nTracks; i++)
            {
                var track:KeyframeTrack = tracks[i];
                var trackName:String = track.name;

                var mixer:PropertyMixer = bindingsByName[trackName];

                if (mixer != null)
                {
                    mixer.referenceCount++;
                }
                else
                {
                    var binding:PropertyBinding = PropertyBinding.create(root, trackName);
                    if (binding.bindingType == PropertyBinding.INVALID)
                    {
                        // D75/D83: a track that cannot bind is a hard error. Silently
                        // keeping a no-op binding makes a typo look like a working
                        // animation, which is exactly the class of bug this kit's
                        // probes are meant to catch.
                        throw new Error("THREE.AnimationMixer: cannot bind track '" + trackName + "' on '" + root.name + "'");
                    }

                    // getValueStride(), not getValueSize(): a CUBICSPLINE track's
                    // buffer is three values per key (see KeyframeTrack).
                    mixer = new PropertyMixer(binding, track.valueTypeName, track.getValueStride());
                    mixer.referenceCount = 1;
                    bindingsByName[trackName] = mixer;
                    this._bindings.push(mixer);
                }

                action._propertyBindings[i] = mixer;

                var rb:Vector.<Number> = new Vector.<Number>(track.getValueStride());
                action._interpolants[i].resultBuffer = rb;
            }
        }

        public function _isActiveAction(action:AnimationAction):Boolean
        {
            return action._isActive;
        }

        public function _activateAction(action:AnimationAction):void
        {
            if (action._isActive) return;

            var bindings:Vector.<PropertyMixer> = action._propertyBindings;
            for (var i:int = 0; i < bindings.length; i++)
            {
                var mixer:PropertyMixer = bindings[i];
                if (mixer.useCount == 0)
                {
                    mixer.saveOriginalState();
                    this._activeBindings.push(mixer);
                }
                mixer.useCount++;
            }

            action._isActive = true;
            this._activeActions.push(action);
        }

        public function _deactivateAction(action:AnimationAction):void
        {
            if (!action._isActive) return;

            var bindings:Vector.<PropertyMixer> = action._propertyBindings;
            for (var i:int = 0; i < bindings.length; i++)
            {
                var mixer:PropertyMixer = bindings[i];
                mixer.useCount--;
                if (mixer.useCount == 0)
                {
                    // three.js restores the pre-animation value so a stopped action
                    // leaves no trace in the scene graph.
                    mixer.restoreOriginalState();
                    var at:int = this._activeBindings.indexOf(mixer);
                    if (at >= 0) this._activeBindings.splice(at, 1);
                }
            }

            action._isActive = false;
            var actionAt:int = this._activeActions.indexOf(action);
            if (actionAt >= 0) this._activeActions.splice(actionAt, 1);
        }

        // ------------------------------------------------------------------
        // Control-interpolant pool (fadeIn / fadeOut)
        // ------------------------------------------------------------------

        public function _lendControlInterpolant():Interpolant
        {
            var interpolants:Vector.<Interpolant> = this._controlInterpolants;
            var nActive:int = this._nActiveControlInterpolants;

            var interpolant:Interpolant = null;
            if (nActive < interpolants.length) interpolant = interpolants[nActive];

            if (interpolant == null)
            {
                var times:Vector.<Number> = new Vector.<Number>(2);
                var values:Vector.<Number> = new Vector.<Number>(2);
                interpolant = new LinearInterpolant(times, values, 1, new Vector.<Number>(1));
                interpolants.push(interpolant);
            }

            this._nActiveControlInterpolants = nActive + 1;
            return interpolant;
        }

        public function _takeBackControlInterpolant(interpolant:Interpolant):void
        {
            this._nActiveControlInterpolants--;
        }

        // ------------------------------------------------------------------
        // Event sinks (D79)
        // ------------------------------------------------------------------

        public function _dispatchFinished(action:AnimationAction, direction:int):void
        {
            if (this.onFinished != null) this.onFinished(action, direction);
        }

        public function _dispatchLoop(action:AnimationAction, loopDelta:Number):void
        {
            if (this.onLoop != null) this.onLoop(action, loopDelta);
        }
    }
}