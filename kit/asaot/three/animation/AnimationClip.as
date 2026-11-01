// asaot.three.animation.AnimationClip -- a named bundle of keyframe tracks.
//
// Borrows src/animation/AnimationClip.js (r187): name/uuid, tracks, the
// `duration` derived as the last key time across all tracks, trim(), and the
// static findByName() lookup.
//
// DIVERGENCES:
//   D77  `CreateFromMorphTargetSequence` / `CreateClipsFromMorphTargetSequences`
//        are not borrowed: glTF delivers real clips, and the legacy
//        `morphTarget_<n>` naming convention never occurs in this kit.
//   D78  blendMode is carried as an int (NormalAnimationBlendMode = 2500) but only
//        normal blending exists (D76 for additive).
package asaot.three.animation
{
    import asaot.three.math.MathUtils;

    public class AnimationClip
    {
        public static const NormalAnimationBlendMode:int = 2500;
        public static const AdditiveAnimationBlendMode:int = 2501;

        public var name:String;
        public var uuid:String;
        public var tracks:Vector.<KeyframeTrack>;
        public var duration:Number;
        public var blendMode:int;

        public function AnimationClip(name:String = "", duration:Number = -1,
                                     tracks:Vector.<KeyframeTrack> = null, blendMode:int = -1)
        {
            this.name = name;
            this.uuid = MathUtils.generateUUID();
            this.tracks = (tracks != null) ? tracks : new Vector.<KeyframeTrack>();
            // note: a default argument cannot reference a class constant here
            // (defaults are emitted at the CALL SITE, in the caller's scope), so
            // -1 means "normal blending".
            this.blendMode = (blendMode < 0) ? NormalAnimationBlendMode : blendMode;
            this.duration = duration;
            this.resetDuration();

            if (duration > 0) this.duration = duration;
        }

        // duration := last key time across all tracks
        public function resetDuration():AnimationClip
        {
            var duration:Number = 0;
            var tracks:Vector.<KeyframeTrack> = this.tracks;
            for (var i:int = 0; i < tracks.length; i++)
            {
                var track:KeyframeTrack = tracks[i];
                var times:Vector.<Number> = track.times;
                if (times.length > 0)
                {
                    var last:Number = times[times.length - 1];
                    if (last > duration) duration = last;
                }
            }
            this.duration = duration;
            return this;
        }

        public function trim():AnimationClip
        {
            for (var i:int = 0; i < this.tracks.length; i++)
            {
                this.tracks[i].trim(0, this.duration);
            }
            return this;
        }

        // AnimationClip.js:findByName. `objectOrClipArray` may be a Vector of
        // clips, or any object carrying an `animations` vector.
        public static function findByName(objectOrClipArray:*, name:String):AnimationClip
        {
            var clipArray:* = objectOrClipArray;

            if (!(clipArray is Array) && !AnimationUtils.isArrayLike(clipArray) && !(clipArray is Vector.<AnimationClip>))
            {
                var holder:* = objectOrClipArray;
                clipArray = (holder.animations != null) ? holder.animations : null;
            }

            if (clipArray == null) return null;

            var n:int = int(clipArray.length);
            for (var i:int = 0; i < n; i++)
            {
                if (AnimationClip(clipArray[i]).name == name) return AnimationClip(clipArray[i]);
            }

            return null;
        }
    }
}