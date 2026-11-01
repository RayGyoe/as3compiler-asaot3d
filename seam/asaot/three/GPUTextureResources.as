// GPUTextureResources.as -- per-Texture Stage3D 2D texture cache for AGALRenderer.
//
// This file imports flash.display3D.textures.Texture under its simple name: there
// is no asaot Texture in scope here, so the clash that forces AGALRenderer.as to
// spell the GPU type out in full does not exist. See GPUMeshResources.as for why
// the cache lives in its own file rather than next to the renderer.
package asaot.three
{
    import flash.display3D.textures.Texture;

    // The Stage3D texture is re-uploaded only when Texture.version changes.
    public class GPUTextureResources
    {
        public var texture:Texture = null;
        public var uploadVersion:int = -1;
        // M17: the GPU texture can be resized only by recreating it, and the
        // mipmapped flag decides whether a mip minFilter is legal at all, so both
        // are part of the cache identity.
        public var width:int = 0;
        public var height:int = 0;
        public var mipmapped:Boolean = false;
    }
}