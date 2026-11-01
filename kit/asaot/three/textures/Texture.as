// asaot.three.textures.Texture -- GPU texture descriptor, three.js style.
//
// Borrows src/textures/Texture.js (r187): wrap/magFilter/minFilter/flipY/
// generateMipmaps/colorSpace + the write-only needsUpdate -> version dirty flag
// (the same contract as Material, so the renderer re-uploads the texture when
// the author sets needsUpdate = true).
//
// M17 made every one of those fields actually do something; before that they
// were inert (the AGAL sampler was hard-coded `clamp,linear,mipnone` and the
// upload never looked at flipY or colorSpace, so REPEAT tiled textures clamped,
// `generateMipmaps` never produced a chain, and every color map was fed to the
// lighting math as if it were already linear). The renderer now maps them onto
// Stage3D state:
//
//   wrapS/wrapT   -> Context3D.setSamplerStateAt(slot, wrap, ...) after
//                    setProgram (AIR: last writer wins). MirroredRepeat has no
//                    Stage3D equivalent -- it degrades to repeat with a warning.
//   min/magFilter -> the single Stage3D filter for that slot, derived from
//                    minFilter (minification is where quality is lost); mip
//                    variants additionally require generateMipmaps + a chain.
//   generateMipmaps -> a real mip chain generated at upload time. Mip-filtering
//                    a texture WITHOUT a chain makes AIR drop the whole draw.
//   flipY          -> row flip at upload time. Stage3D's t=0 is the bitmap's
//                    top row, three.js's flipY=true means t=0 is the bottom.
//   colorSpace     -> AGAL pow(x, 2.2) on the color slots (map/emissive/env).
//                    three.js defaults to NoColorSpace, so nothing is decoded
//                    unless the author (or GLTFLoader) says the map is sRGB.
//
// M18 adds the uv transform: offset/repeat/rotation/center are folded into
// `matrix` by updateMatrix(), and the renderer applies that matrix to the uv
// attribute PER SAMPLER SLOT in the vertex program (three.js puts one
// `xxxMapTransform` uniform and one `vXxxMapUv` varying on every map -- see
// uv_pars_vertex.glsl.js / uv_vertex.glsl.js). `matrixAutoUpdate` mirrors
// three.js: while true the renderer refreshes the matrix before each draw
// (WebGLMaterials.js:13-22 refreshTransformUniform), so an author writes
// `map.repeat.set(4, 4)` and nothing else; with it false the matrix is taken as
// authored (`map.matrix.setUvTransform(...)` or a direct write).
//
// image is a flash.display.BitmapData (D16's "BitmapData.pixels -> Stage3D"
// contract). three.js holds an arbitrary HTMLImageElement; our "image" is the
// one AIR-side bitmap the Stage3D seam can upload, so it is typed BitmapData
// rather than a boxed any.
package asaot.three.textures
{
    import flash.display.BitmapData;

    import asaot.three.math.Matrix3;
    import asaot.three.math.Vector2;

    public class Texture
    {
        // wrap constants (src/constants.js:548,556)
        public static const RepeatWrapping:int = 1000;
        public static const ClampToEdgeWrapping:int = 1001;
        public static const MirroredRepeatWrapping:int = 1002;

        // color spaces (src/constants.js ColorSpaces; ColorManagement.js). The
        // string values match three.js so a ported snippet reads the same. Only
        // SRGBColorSpace triggers a decode in the renderer (M17).
        public static const NoColorSpace:String = '';
        public static const SRGBColorSpace:String = 'srgb';
        public static const LinearSRGBColorSpace:String = 'srgb-linear';

        // filter constants (src/constants.js:573,583,594,605,615,626)
        public static const NearestFilter:int = 1003;
        public static const NearestMipmapNearestFilter:int = 1004;
        public static const NearestMipmapLinearFilter:int = 1005;
        public static const LinearFilter:int = 1006;
        public static const LinearMipmapNearestFilter:int = 1007;
        public static const LinearMipmapLinearFilter:int = 1008;

        public var name:String;
        public var image:BitmapData;

        public var wrapS:int;
        public var wrapT:int;
        public var magFilter:int;
        public var minFilter:int;
        public var flipY:Boolean;
        public var generateMipmaps:Boolean;
        // Encoding of the texel data (Texture.js colorSpace, default
        // NoColorSpace). SRGBColorSpace means the renderer must decode to linear
        // before lighting; LinearSRGBColorSpace/NoColorSpace mean it must not.
        public var colorSpace:String;

        // M18 uv transform (Texture.js:199-247). These are the AUTHOR-facing
        // knobs; `matrix` is what the renderer consumes.
        public var offset:Vector2;
        public var repeat:Vector2;
        public var center:Vector2;
        public var rotation:Number;
        public var matrix:Matrix3;
        // While true the renderer calls updateMatrix() before every draw that
        // uses this texture (three.js WebGLMaterials.refreshTransformUniform).
        public var matrixAutoUpdate:Boolean;

        public var version:int;

        public function Texture(image:BitmapData = null)
        {
            this.name = '';
            this.image = image;
            this.wrapS = Texture.ClampToEdgeWrapping;
            this.wrapT = Texture.ClampToEdgeWrapping;
            this.magFilter = Texture.LinearFilter;
            this.minFilter = Texture.LinearMipmapLinearFilter;
            this.flipY = true;
            this.generateMipmaps = true;
            this.colorSpace = Texture.NoColorSpace;
            this.offset = new Vector2(0, 0);
            this.repeat = new Vector2(1, 1);
            this.center = new Vector2(0, 0);
            this.rotation = 0;
            this.matrix = new Matrix3();
            this.matrixAutoUpdate = true;
            this.version = 0;
        }

        // Texture.js:451-455. Folds offset/repeat/rotation/center into `matrix`.
        // Called by the renderer while matrixAutoUpdate is true; an author who
        // sets matrixAutoUpdate = false owns `matrix` and calls this only when
        // they want it recomputed from the four fields.
        public function updateMatrix():void
        {
            this.matrix.setUvTransform(this.offset.x, this.offset.y,
                                       this.repeat.x, this.repeat.y,
                                       this.rotation, this.center.x, this.center.y);
        }

        // Write-only flag (Texture.js:326): the renderer re-uploads the GPU
        // texture when version changes, mirroring Material.needsUpdate.
        public function set needsUpdate(value:Boolean):void
        {
            if (value) this.version++;
        }

        // Texture.js:296 clone(): every descriptor field is copied, the image is
        // SHARED (a clone is a second sampling configuration over the same
        // pixels, which is exactly what glTF's per-slot texture transforms need).
        // `matrix` is recomputed rather than copied so a clone can never inherit
        // a stale transform.
        public function clone():Texture
        {
            var t:Texture = new Texture(this.image);
            t.name = this.name;
            t.wrapS = this.wrapS;
            t.wrapT = this.wrapT;
            t.magFilter = this.magFilter;
            t.minFilter = this.minFilter;
            t.flipY = this.flipY;
            t.generateMipmaps = this.generateMipmaps;
            t.colorSpace = this.colorSpace;
            t.offset.copy(this.offset);
            t.repeat.copy(this.repeat);
            t.center.copy(this.center);
            t.rotation = this.rotation;
            t.matrixAutoUpdate = this.matrixAutoUpdate;
            if (t.matrixAutoUpdate == false) t.matrix.copy(this.matrix);
            else t.updateMatrix();
            t.needsUpdate = true;
            return t;
        }
    }
}
