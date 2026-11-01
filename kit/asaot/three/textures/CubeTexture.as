// asaot.three.textures.CubeTexture -- six-face environment map, three.js style.
//
// Borrows src/textures/CubeTexture.js (r187): a Texture whose payload is six
// faces instead of one image, ordered +X, -X, +Y, -Y, +Z, -Z (the same order as
// three.js's `images` array and Stage3D's CubeTexture side index, so no
// re-ordering is needed at upload time).
//
// Inherited wrap/filter/flipY/version fields are consumed exactly like Texture's
// (the renderer re-uploads a cube when `version` changes), but `image` (the
// single-face BitmapData slot) is unused: a cube has `images` instead. As with
// Texture, an "image" is a BitmapData -- the one bitmap source the Stage3D seam
// can upload (three.js holds HTMLImageElements; Section D16 of
// three-api-design.md).
package asaot.three.textures
{
    import flash.display.BitmapData;

    public class CubeTexture extends Texture
    {
        // Six faces, +X/-X/+Y/-Y/+Z/-Z (CubeTexture.js:18-26). Gaps (null) are
        // tolerated at construction so a loader can fill faces as they decode;
        // the renderer falls back to the neutral cube if any face is missing.
        public var images:Vector.<BitmapData>;

        // M25/D154: radiance divisor of a bake produced by
        // EquirectangularToCube. The faces are 8-bit gamma-encoded LINEAR
        // radiance -- a cube has no float storage at any profile rung: a
        // `rgbaHalfFloat` cube is ACCEPTED by createCubeTexture and by
        // uploadFromBitmapData but stores the same 8-bit bytes as `bgra`
        // (measured, three-api-design.md §36.2), so the renderer multiplies the
        // environment contribution by this scalar to get the original HDR values
        // back. 1.0 for an LDR cube (CubeTextureLoader), which is what keeps the
        // M9 path byte-identical.
        //
        // The same measurement settles a design question for this class: one cube
        // with a mip chain per roughness level is NOT available either --
        // uploadFromBitmapData accepts `miplevel > 0` and then drops it (§36.3), so
        // a per-roughness mip ladder would silently collapse into the sharp level.
        // That is why the M25-R1 ladder is six CubeTextures (PrefilteredEnvironment)
        // rather than one cube with six mips.
        public var hdrScale:Number;

        public function CubeTexture(images:Vector.<BitmapData> = null)
        {
            // The single-image slot stays null: this texture is face-indexed.
            super(null);
            this.images = images != null ? images : new Vector.<BitmapData>();
            this.hdrScale = 1.0;
            // glTF-style cubemaps are uploaded top-down already; flipping the
            // faces would mirror the environment. three.js's CubeTexture leaves
            // flipY at the Texture default, but its WebGL upload path ignores
            // flipY for cubes, so we pin it false to say what actually happens.
            this.flipY = false;
        }

        // Edge length of the cube (faces must be square and equal). 0 when no
        // face has been filled yet.
        public function faceSize():int
        {
            if (this.images.length == 0) return 0;
            if (this.images[0] == null) return 0;
            return this.images[0].width;
        }
    }
}