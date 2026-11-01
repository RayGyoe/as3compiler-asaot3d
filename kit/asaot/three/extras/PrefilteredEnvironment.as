// asaot.three.extras.PrefilteredEnvironment -- a roughness ladder of cubes.
//
// three.js builds a PMREM: one cube render target whose MIP chain holds the
// environment pre-convolved at increasing roughness, then `textureCubeUV`
// selects a level per fragment. This backend has neither float render targets
// nor explicit-LOD cube sampling (D152, D156), so M25-R1 splits the same idea
// across resolution: each roughness level is a SEPARATE 8-bit cube, baked on the
// CPU, and the renderer picks one per DRAW on the host side.
//
// What that buys and what it costs, stated plainly (D174):
//
//   * buys: a rough surface samples radiance convolved at roughly its own
//     roughness, instead of the sharp cube mixed toward the normal (the M9
//     stand-in). Highlights stop being a mirror image on a 0.6-roughness metal.
//   * costs: the level is chosen from `material.roughness` -- one value per draw.
//     A material whose roughnessMap varies across the surface gets the level of
//     its FACTOR, so a per-pixel roughness ramp is only approximately followed;
//     and with N levels the ramp is quantized (nearest), not interpolated.
//
// The ladder is ordered by ascending roughness and every level shares one
// `hdrScale` (one autoScale for the whole bake), which is what lets the shader
// keep using a single intensity scalar per sampler slot.
package asaot.three.extras
{
    import asaot.three.textures.CubeTexture;

    public class PrefilteredEnvironment
    {
        /** Level i, ascending roughness. levels[0] is the sharp bake. */
        public var levels:Vector.<CubeTexture>;

        /** Roughness each level was baked at (parallel to `levels`). */
        public var roughness:Vector.<Number>;

        /** Radiance divisor shared by every level (D154). */
        public var hdrScale:Number;

        public var faceSize:int;

        public function PrefilteredEnvironment(levels:Vector.<CubeTexture>,
                                               roughness:Vector.<Number>,
                                               hdrScale:Number, faceSize:int)
        {
            if (levels == null || levels.length == 0)
                throw new Error("PrefilteredEnvironment: needs at least one level");
            if (roughness == null || roughness.length != levels.length)
                throw new Error("PrefilteredEnvironment: roughness must parallel levels");
            this.levels = levels;
            this.roughness = roughness;
            this.hdrScale = hdrScale > 0 ? hdrScale : 1.0;
            this.faceSize = faceSize;
        }

        public function get levelCount():int
        {
            return this.levels.length;
        }

        /** The sharp bake (what `scene.background` wants). */
        public function get sharpCube():CubeTexture
        {
            return this.levels[0];
        }

        /**
         * The roughest level: the closest thing this backend has to a
         * pre-convolved irradiance cube. `getIBLIrradiance` in three.js samples
         * the PMREM at roughness 1, i.e. exactly this level, which is why the
         * diffuse term binds it separately from the specular level (D175).
         */
        public function get irradianceCube():CubeTexture
        {
            return this.levels[this.levels.length - 1];
        }

        /** Index of the level whose roughness is nearest to `r`. */
        public function levelFor(r:Number):int
        {
            var n:int = this.levels.length;
            if (!(r == r)) return 0;                 // NaN -> sharp
            if (r <= this.roughness[0]) return 0;
            var best:int = 0;
            var bestD:Number = Math.abs(r - this.roughness[0]);
            var i:int;
            for (i = 1; i < n; i++)
            {
                var d:Number = Math.abs(r - this.roughness[i]);
                if (d < bestD)
                {
                    bestD = d;
                    best = i;
                }
            }
            return best;
        }

        public function cubeFor(r:Number):CubeTexture
        {
            return this.levels[this.levelFor(r)];
        }
    }
}