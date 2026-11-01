// GPUCubeResources.as -- per-CubeTexture Stage3D cube map cache for AGALRenderer (M9).
//
// Same version contract as GPUTextureResources, plus the face edge length: a cube
// map cannot be resized in place, so a size change forces a new GPU cube.
package asaot.three
{
    import flash.display3D.textures.CubeTexture;

    public class GPUCubeResources
    {
        public var cube:CubeTexture = null;
        public var size:int = 0;
        public var uploadVersion:int = -1;
    }
}