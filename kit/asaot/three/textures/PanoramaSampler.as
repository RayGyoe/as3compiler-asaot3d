// asaot.three.textures.PanoramaSampler -- "an equirectangular panorama I can
// bilinear-sample", the seam EquirectangularToCube bakes from.
//
// Two implementations share this shape:
//
//   * HDRImage      -- RGBe bytes as decoded from a .hdr/.exr file (M25)
//   * FloatPanorama -- linear floats, used by the prefilter blur (M25-R1)
//
// It exists so the cube bake has ONE loop (EquirectangularToCube
// .bakeTexelsSampled) instead of one copy per storage format. AS3 has no
// structural typing, so the alternative to an interface would be a dynamic
// `Object` call per texel -- 150k as_dyn_get lookups per bake, i.e. exactly the
// hot-path lookup the project's runtime red lines warn about.
//
// The interface deliberately declares ONLY the sampler: bakeTexelsSampled works
// in uv space and never needs to know the source resolution (the sampler itself
// wraps u and clamps v). Callers that need the size use their concrete type.
//
// uv convention (published by EquirectangularToCube, pinned by
// probes/hdr-smoke-m25): u = 0.5 + atan2(z, x)/2pi wraps, v = 0.5 - asin(y)/pi
// clamps, and v = 0 is the +Y pole (row 0).
package asaot.three.textures
{
    public interface PanoramaSampler
    {
        // Bilinear sample at (u, v); `out[0..2]` receives LINEAR radiance
        // (any file-level exposure divisor already applied).
        function sampleBilinear(u:Number, v:Number, out:Vector.<Number>):void;
    }
}