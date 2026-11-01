// asaot.three.materials.Material -- material base class, three.js style.
//
// Borrows src/materials/Material.js (r187): name/transparent/opacity/side/
// blending/depthTest/depthWrite/visible + version (driven by the write-only
// needsUpdate flag). side/blending are static int constants matching
// src/constants.js, not an AS3 enum (enums are forbidden by the project rules).
//
// M19: side/blending/depthTest/depthWrite became REAL render state. Before M19
// the renderer hard-coded one culling / depth / blend state for every draw, so
// `side = DoubleSide` (which GLTFLoader sets for `doubleSided: true`) silently
// drew thin geometry single-sided, and an author's depth/blend choice was
// ignored. See AGALRenderer._applyMaterialState and three-api-design.md §24.
package asaot.three.materials
{
    import asaot.three.math.MathUtils;

    public class Material
    {
        // side constants (src/constants.js:92,100,108)
        public static const FrontSide:int = 0;
        public static const BackSide:int = 1;
        public static const DoubleSide:int = 2;

        // blending constants (src/constants.js:117-151). M19 wires all five
        // standard modes to Stage3D blend factors; CustomBlending has no
        // per-material blendSrc/blendDst pair in this port (Material.js:349-373),
        // so it degrades to NormalBlending and says so once (R35).
        public static const NoBlending:int = 0;
        public static const NormalBlending:int = 1;
        public static const AdditiveBlending:int = 2;
        public static const SubtractiveBlending:int = 3;
        public static const MultiplyBlending:int = 4;
        public static const CustomBlending:int = 5;

        public var name:String;
        public var uuid:String;
        public var transparent:Boolean;
        public var opacity:Number;
        // M10: alpha test threshold (Material.js:477 `_alphaTest = 0`). The
        // fragment discards when the diffuse alpha falls below it; the renderer
        // encodes it as a `kil` (AGAL has no smoothstep/fwidth, so the cut is
        // hard -- three-api-design.md §15).
        public var alphaTest:Number;
        // M19: side/blending/depthTest/depthWrite used to be dead fields -- the
        // renderer wrote one hard-coded culling/depth/blend state for every
        // draw. They are now read per draw (AGALRenderer._applyMaterialState).
        public var side:int;
        public var blending:int;
        // three.js semantics: `depthTest` off disables the test AND the writes
        // (an OpenGL depth buffer is only updated while the test is enabled);
        // `depthWrite` off keeps the test but stops the write.
        public var depthTest:Boolean;
        public var depthWrite:Boolean;
        public var visible:Boolean;
        // M20: three.js Material.fog (Material.js:66) -- when false the draw is
        // excluded from the scene fog even if scene.fog is set (typical for a
        // HUD-ish mesh or a material that already encodes distance).
        public var fog:Boolean;

        // M26: three.js Material.toneMapped (Material.js:458). The renderer bakes
        // tone mapping into the program source, so honouring this means a program
        // variant -- only the LINE and BASIC programs implement it today, because
        // that is where three.js uses it (helpers set toneMapped = false so an
        // authored colour is not re-graded). A standard-material draw that asks
        // for toneMapped = false is reported once by the renderer instead of being
        // silently tone mapped; see R59 in three-api-design.md §29.
        public var toneMapped:Boolean;

        public var version:int;

        public function Material()
        {
            this.name = '';
            this.uuid = MathUtils.generateUUID();
            this.transparent = false;
            this.opacity = 1;
            this.alphaTest = 0;
            this.side = Material.FrontSide;
            this.blending = Material.NormalBlending;
            this.depthTest = true;
            this.depthWrite = true;
            this.visible = true;
            this.fog = true;
            this.toneMapped = true;
            this.version = 0;
        }

        // Write-only flag. three.js bumps `version` whenever needsUpdate is set
        // true (Material.js:1246); the renderer caches a material's compiled
        // program keyed on version, so an author setting needsUpdate = true asks
        // for a recompile on the next render. AS3 has no "set-only" property, so
        // the getter is omitted intentionally.
        public function set needsUpdate(value:Boolean):void
        {
            if (value) this.version++;
        }
    }
}
