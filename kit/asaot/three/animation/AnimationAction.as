// asaot.three.animation.AnimationAction -- one playable instance of an
// AnimationClip on a mixer.
//
// Borrows src/animation/AnimationAction.js (r187):
//   * the enabled/paused/weight/timeScale state machine and _updateWeight /
//     _updateTimeScale;
//   * _updateTime with LoopOnce / LoopRepeat / LoopPingPong wrapping, including
//     the "\u00abentering the last round\u00bb" ending-mode switch and the ping-pong
//     time inversion;
//   * _activate / _deactivate through the mixer, fadeIn / fadeOut via a lent
//     LinearInterpolant on the mixer clock, and _setEndings for cubic tracks.
//
// Loop constants mirror src/constants.js:2200-2202.
//
// DIVERGENCES:
//   D79  No EventDispatcher in this kit: the 'finished' / 'loop' events are
//        delivered through the mixer's optional `onFinished` / `onLoop` Function
//        fields (same information, same order, one global sink).
//   D80  warp() / halt() (the timeScale fade) were NOT borrowed in M12 -- speed
//        ramps were out of scope for the keyframe demo. M26 lifts this: three.js's
//        webgl_animation_walk crossfades with `crossFadeTo(action, d, true)`, and
//        the `true` is exactly warp(), so without it the reference demo cannot be
//        ported at all. Refusing warp instead of implementing it would have been a
//        silent (or worse, throwing) degradation on a real use case.
package asaot.three.animation
{
    public class AnimationAction
    {
        public static const LoopOnce:int = 2200;
        public static const LoopRepeat:int = 2201;
        public static const LoopPingPong:int = 2202;

        public var _mixer:AnimationMixer;
        public var _clip:AnimationClip;
        public var _localRoot:*;

        public var blendMode:int;

        public var _interpolants:Vector.<Interpolant>;
        public var _propertyBindings:Vector.<PropertyMixer>;
        public var _interpolantSettings:Object;

        public var loop:int = LoopRepeat;
        public var _loopCount:int = -1;
        public var _startTime:Number = NaN;      // NaN == null ("start now")
        public var time:Number = 0;
        public var timeScale:Number = 1;
        public var _effectiveTimeScale:Number = 1;
        public var weight:Number = 1;
        public var _effectiveWeight:Number = 1;
        public var repetitions:Number = 1e30;     // three.js: Infinity
        public var paused:Boolean = false;
        public var enabled:Boolean = true;
        public var clampWhenFinished:Boolean = false;
        public var zeroSlopeAtStart:Boolean = true;
        public var zeroSlopeAtEnd:Boolean = true;

        public var _weightInterpolant:Interpolant = null;
        // M26: the timeScale fade (warp). Separate lent interpolant from the
        // weight fade above -- one register cannot hold two ramps.
        public var _timeScaleInterpolant:Interpolant = null;

        // AnimationMixer bookkeeping (three.js uses a cacheIndex instead).
        public var _isActive:Boolean = false;

        public function AnimationAction(mixer:AnimationMixer, clip:AnimationClip, localRoot:* = null,
                                        blendMode:int = -1)
        {
            this._mixer = mixer;
            this._clip = clip;
            this._localRoot = localRoot;
            this.blendMode = (blendMode < 0) ? AnimationClip.NormalAnimationBlendMode : blendMode;

            var tracks:Vector.<KeyframeTrack> = clip.tracks;
            var nTracks:int = tracks.length;

            var settings:Object = {
                endingStart: CubicInterpolant.ZeroCurvatureEnding,
                endingEnd: CubicInterpolant.ZeroCurvatureEnding
            };
            this._interpolantSettings = settings;

            this._interpolants = new Vector.<Interpolant>(nTracks, true);
            for (var i:int = 0; i < nTracks; i++)
            {
                var interpolant:Interpolant = tracks[i].createInterpolant(null);
                interpolant.settings = settings;
                this._interpolants[i] = interpolant;
            }

            this._propertyBindings = new Vector.<PropertyMixer>(nTracks, true);
        }

        // ------------------------------------------------------------------
        // Public API
        // ------------------------------------------------------------------

        public function getClip():AnimationClip
        {
            return this._clip;
        }

        public function play():AnimationAction
        {
            this._mixer._activateAction(this);
            return this;
        }

        public function stop():AnimationAction
        {
            this._mixer._deactivateAction(this);
            return this.reset();
        }

        public function reset():AnimationAction
        {
            this.paused = false;
            this.enabled = true;
            this.time = 0;          // restart clip
            this._loopCount = -1;   // forget previous loops
            this._startTime = NaN;  // forget scheduling
            return this.stopFading().stopWarping();
        }

        public function isRunning():Boolean
        {
            return !this.paused
                && this.enabled
                && this.timeScale != 0
                && !(this._startTime == this._startTime)   // _startTime === null
                && this._mixer._isActiveAction(this);
        }

        public function isScheduled():Boolean
        {
            return this._mixer._isActiveAction(this) && (this._startTime == this._startTime);
        }

        public function startAt(time:Number):AnimationAction
        {
            this._startTime = time;
            return this;
        }

        public function setLoop(mode:int, repetitions:Number = -1):AnimationAction
        {
            this.loop = mode;
            this.repetitions = (repetitions >= 0) ? repetitions : 1e30;
            return this;
        }

        public function setEffectiveWeight(weight:Number):AnimationAction
        {
            this.weight = weight;
            // note: same as .setEffectiveWeight
            this._effectiveWeight = this.enabled ? weight : 0;
            return this.stopFading();
        }

        public function getEffectiveWeight():Number
        {
            return this._effectiveWeight;
        }

        public function fadeIn(duration:Number):AnimationAction
        {
            return this._scheduleFading(duration, 0, 1);
        }

        public function fadeOut(duration:Number):AnimationAction
        {
            return this._scheduleFading(duration, 1, 0);
        }

        public function stopFading():AnimationAction
        {
            var weightInterpolant:Interpolant = this._weightInterpolant;
            if (weightInterpolant != null)
            {
                this._weightInterpolant = null;
                this._mixer._takeBackControlInterpolant(weightInterpolant);
            }
            return this;
        }

        // ------------------------------------------------------------------
        // M26: crossfade + time-scale sync (AnimationAction.js:350-430)
        // ------------------------------------------------------------------

        // Fade this action in while fading `fadeOutAction` out over the same
        // window, so the two weights sum to 1 for the whole transition.
        //
        // `warp` additionally ramps the two TIME SCALES so the clips advance in
        // step while they blend: a 1 s clip fading into a 2 s clip would otherwise
        // drift apart mid-crossfade and pop when the transition ends. The ramp is
        // built from the duration ratio of the two clips, not from their playback
        // frame counts -- three.js derives it from `_clip.duration` and so do we.
        public function crossFadeFrom(fadeOutAction:AnimationAction, duration:Number,
                                       warp:Boolean = false):AnimationAction
        {
            fadeOutAction.fadeOut(duration);
            this.fadeIn(duration);

            if (warp)
            {
                var fadeInDuration:Number = this._clip.duration;
                var fadeOutDuration:Number = fadeOutAction._clip.duration;

                var startEndRatio:Number = fadeOutDuration / fadeInDuration;
                var endStartRatio:Number = fadeInDuration / fadeOutDuration;

                fadeOutAction.warp(1.0, startEndRatio, duration);
                this.warp(endStartRatio, 1.0, duration);
            }

            return this;
        }

        public function crossFadeTo(fadeInAction:AnimationAction, duration:Number,
                                    warp:Boolean = false):AnimationAction
        {
            return fadeInAction.crossFadeFrom(this, duration, warp);
        }

        // Adopt another action's playhead and rate; the usual companion to a
        // crossfade between two phases of one cycle (walk -> run).
        public function syncWith(action:AnimationAction):AnimationAction
        {
            this.time = action.time;
            this.timeScale = action.timeScale;
            return this;
        }

        // Schedule a timeScale ramp measured RELATIVE to the action's own
        // timeScale: the lent interpolant multiplies it in _updateTimeScale, so
        // the stored values are ratios, not absolute rates. At the end of the
        // window the accumulated rate is folded back into `timeScale` and the
        // interpolant is returned to the pool.
        public function warp(startTimeScale:Number, endTimeScale:Number,
                             duration:Number):AnimationAction
        {
            var mixer:AnimationMixer = this._mixer;
            var now:Number = mixer.time;
            var timeScale:Number = this.timeScale;

            var interpolant:Interpolant = this._timeScaleInterpolant;
            if (interpolant == null)
            {
                interpolant = mixer._lendControlInterpolant();
                this._timeScaleInterpolant = interpolant;
            }

            var times:Vector.<Number> = interpolant.parameterPositions;
            var values:Vector.<Number> = interpolant.sampleValues;

            times[0] = now;
            times[1] = now + duration;

            values[0] = startTimeScale / timeScale;
            values[1] = endTimeScale / timeScale;

            return this;
        }

        public function stopWarping():AnimationAction
        {
            var interpolant:Interpolant = this._timeScaleInterpolant;
            if (interpolant != null)
            {
                this._timeScaleInterpolant = null;
                this._mixer._takeBackControlInterpolant(interpolant);
            }
            return this;
        }

        // Ramp the current effective rate down to a full stop.
        public function halt(duration:Number):AnimationAction
        {
            return this.warp(this._effectiveTimeScale, 0, duration);
        }

        public function setEffectiveTimeScale(timeScale:Number):AnimationAction
        {
            this.timeScale = timeScale;
            this._effectiveTimeScale = this.paused ? 0 : timeScale;
            return this.stopWarping();
        }

        public function getEffectiveTimeScale():Number
        {
            return this._effectiveTimeScale;
        }

        // ------------------------------------------------------------------
        // Per-frame update (called by AnimationMixer)
        // ------------------------------------------------------------------

        public function _update(time:Number, deltaTime:Number, timeDirection:Number, accuIndex:int):void
        {
            if (!this.enabled)
            {
                // still refresh _effectiveWeight so callers see the truth
                this._updateWeight(time);
                return;
            }

            var startTime:Number = this._startTime;

            if (startTime == startTime)   // not NaN == scheduled
            {
                var timeRunning:Number = (time - startTime) * timeDirection;
                if (timeRunning < 0 || timeDirection == 0)
                {
                    deltaTime = 0;
                }
                else
                {
                    this._startTime = NaN; // unschedule
                    deltaTime = timeDirection * timeRunning;
                }
            }

            deltaTime *= this._updateTimeScale(time);
            var clipTime:Number = this._updateTime(deltaTime);

            var weight:Number = this._updateWeight(time);

            if (weight > 0)
            {
                var interpolants:Vector.<Interpolant> = this._interpolants;
                var propertyMixers:Vector.<PropertyMixer> = this._propertyBindings;
                var m:int = interpolants.length;

                for (var j:int = 0; j < m; j++)
                {
                    interpolants[j].evaluate(clipTime);
                    propertyMixers[j].incoming = interpolants[j].resultBuffer;
                    propertyMixers[j].accumulate(accuIndex, weight);
                }
            }
        }

        private function _updateWeight(time:Number):Number
        {
            var weight:Number = 0;

            if (this.enabled)
            {
                weight = this.weight;
                var interpolant:Interpolant = this._weightInterpolant;

                if (interpolant != null)
                {
                    var interpolantValue:Number = interpolant.evaluate(time)[0];
                    weight *= interpolantValue;

                    if (time > interpolant.parameterPositions[1])
                    {
                        this.stopFading();

                        if (interpolantValue == 0)
                        {
                            // faded out, disable
                            this.enabled = false;
                        }
                    }
                }
            }

            this._effectiveWeight = weight;
            return weight;
        }

        private function _updateTimeScale(time:Number):Number
        {
            var timeScale:Number = 0;

            if (!this.paused)
            {
                timeScale = this.timeScale;

                // M26 warp ramp, in the same slot the weight fade uses for
                // weights. Past the window the accumulated rate becomes the new
                // base rate -- folding it in (instead of dropping it) is what
                // keeps a warped crossfade from snapping back to 1x at the end.
                var interpolant:Interpolant = this._timeScaleInterpolant;
                if (interpolant != null)
                {
                    var interpolantValue:Number = interpolant.evaluate(time)[0];
                    timeScale *= interpolantValue;

                    if (time > interpolant.parameterPositions[1])
                    {
                        this.stopWarping();

                        if (timeScale == 0) this.paused = true;
                        else this.timeScale = timeScale;
                    }
                }
            }

            this._effectiveTimeScale = timeScale;
            return timeScale;
        }

        private function _updateTime(deltaTime:Number):Number
        {
            var duration:Number = this._clip.duration;
            var loop:int = this.loop;

            var time:Number = this.time + deltaTime;
            var loopCount:int = this._loopCount;

            var pingPong:Boolean = (loop == LoopPingPong);

            if (deltaTime == 0)
            {
                if (loopCount == -1) return time;
                return (pingPong && (loopCount & 1) == 1) ? duration - time : time;
            }

            if (loop == LoopOnce)
            {
                if (loopCount == -1)
                {
                    // just started
                    this._loopCount = 0;
                    this._setEndings(true, true, false);
                }

                var stopped:Boolean = false;

                if (time >= duration)
                {
                    time = duration;
                    stopped = true;
                }
                else if (time < 0)
                {
                    time = 0;
                    stopped = true;
                }

                if (stopped)
                {
                    if (this.clampWhenFinished) this.paused = true;
                    else this.enabled = false;

                    this.time = time;
                    this._mixer._dispatchFinished(this, (deltaTime < 0) ? -1 : 1);
                }
                else
                {
                    this.time = time;
                }
            }
            else
            {
                // LoopRepeat / LoopPingPong
                if (loopCount == -1)
                {
                    // just started
                    if (deltaTime >= 0)
                    {
                        loopCount = 0;
                        this._setEndings(true, this.repetitions == 0, pingPong);
                    }
                    else
                    {
                        // looping in reverse: the initial transition through zero
                        // counts as a repetition, so leave loopCount at -1
                        this._setEndings(this.repetitions == 0, true, pingPong);
                    }
                }

                if (time >= duration || time < 0)
                {
                    // wrap around
                    var loopDelta:Number = Math.floor(time / duration); // signed
                    time -= duration * loopDelta;
                    loopCount += Math.abs(loopDelta);

                    var pending:Number = this.repetitions - loopCount;

                    if (pending <= 0)
                    {
                        // stop (switch state, clamp time, fire event)
                        if (this.clampWhenFinished) this.paused = true;
                        else this.enabled = false;

                        time = (deltaTime > 0) ? duration : 0;

                        this.time = time;
                        this._mixer._dispatchFinished(this, (deltaTime > 0) ? 1 : -1);
                    }
                    else
                    {
                        if (pending == 1)
                        {
                            // entering the last round
                            var atStart:Boolean = (deltaTime < 0);
                            this._setEndings(atStart, !atStart, pingPong);
                        }
                        else
                        {
                            this._setEndings(false, false, pingPong);
                        }

                        this._loopCount = loopCount;
                        this.time = time;
                        this._mixer._dispatchLoop(this, loopDelta);
                    }
                }
                else
                {
                    this._loopCount = loopCount;
                    this.time = time;
                }

                if (pingPong && (loopCount & 1) == 1)
                {
                    // invert time for the "pong round"
                    return duration - time;
                }
            }

            return time;
        }

        private function _setEndings(atStart:Boolean, atEnd:Boolean, pingPong:Boolean):void
        {
            var settings:Object = this._interpolantSettings;

            if (pingPong)
            {
                settings["endingStart"] = CubicInterpolant.ZeroSlopeEnding;
                settings["endingEnd"] = CubicInterpolant.ZeroSlopeEnding;
            }
            else
            {
                // assuming for LoopOnce atStart == atEnd == true
                if (atStart)
                {
                    settings["endingStart"] = this.zeroSlopeAtStart
                        ? CubicInterpolant.ZeroSlopeEnding : CubicInterpolant.ZeroCurvatureEnding;
                }
                else
                {
                    settings["endingStart"] = CubicInterpolant.WrapAroundEnding;
                }

                if (atEnd)
                {
                    settings["endingEnd"] = this.zeroSlopeAtEnd
                        ? CubicInterpolant.ZeroSlopeEnding : CubicInterpolant.ZeroCurvatureEnding;
                }
                else
                {
                    settings["endingEnd"] = CubicInterpolant.WrapAroundEnding;
                }
            }
        }

        private function _scheduleFading(duration:Number, weightNow:Number, weightThen:Number):AnimationAction
        {
            var mixer:AnimationMixer = this._mixer;
            var now:Number = mixer.time;

            var interpolant:Interpolant = this._weightInterpolant;
            if (interpolant == null)
            {
                interpolant = mixer._lendControlInterpolant();
                this._weightInterpolant = interpolant;
            }

            interpolant.parameterPositions[0] = now;
            interpolant.sampleValues[0] = weightNow;
            interpolant.parameterPositions[1] = now + duration;
            interpolant.sampleValues[1] = weightThen;

            return this;
        }
    }
}