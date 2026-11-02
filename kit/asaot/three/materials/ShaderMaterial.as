// asaot.three.materials.ShaderMaterial -- author-written GLSL ES 3.00, three.js
// ShaderMaterial shape (src/materials/ShaderMaterial.js, r187).
//
// WHY THIS CLASS IS PURE DATA. The engine has two renderer backends (IRenderer):
// AGALRenderer, which machine-generates AGAL and runs anywhere AIR runs, and
// NativeShaderRenderer (E6, opt-in), which hands the author's source to glslang +
// SPIRV-Cross and can therefore do what AGAL cannot -- texelFetch, integer ops,
// compute-style loops, MRT, float render targets. A ShaderMaterial is the SAME
// AS3 object under both: it carries source text and uniform values, nothing more.
// That is what keeps an Ultra-Water-class port expressible in a language that
// compiles under mxmlc, and it is why this file has no flash.display3D imports
// at all -- a static reference to Context3DNative here would make the whole
// engine uncompilable on AIR (type position = #1046, see three-api-design.md
// §7 of native-shader.md).
//
// WHAT AN AUTHOR MUST EXPECT WHEN THE CHANNEL IS ABSENT. Nothing degrades. A
// backend without the native channel (AIR/adl, or a default AOT build, which
// does not even contain the class) refuses to draw this material with a thrown
// Error naming the material and the exact switch. There is no AGAL fallback on
// purpose: silently rendering an approximation of an FFT ocean would be a wrong
// answer wearing a plausible picture (AGENTS.md §0 -- a wrong translation is
// worse than a missing feature).
//
// UNIFORM SHAPE. three.js stores each uniform as an object with a `value` field
// (`{ uTime: { value: 0 } }`) so an animation loop can mutate it without
// re-assigning the table. The same shape is used here, and `setUniformValue`
// exists for the common case so a demo does not have to spell `uniforms.uTime.value`
// four times. A uniform name the program does not declare throws
// ArgumentError #2008 from the backend rather than being ignored: a misspelled
// uniform is the single most common bug in this channel and silence looks
// exactly like "the shader ignores my light".
package asaot.three.materials
{
    public class ShaderMaterial extends Material
    {
        // GLSL ES 3.00 source. The backend upgrades the version directive to
        // `310 es` internally for SPIR-V, and rejects `#version 100` / legacy
        // `attribute`/`varying` with glslang's own message -- an ES 1.00 shader
        // is NOT silently accepted here (native-shader.md §4.1).
        public var vertexShader:String;
        public var fragmentShader:String;

        // name -> { value: ... } (see the class comment). Deliberately a plain
        // Object, not a Dictionary: three.js allows an object literal, and every
        // demo writes one. Keys are uniform NAMES, which is how the backend
        // binds them (SPIRV-Cross gives each uniform its own [[buffer(N)]], so
        // no std140 offset arithmetic is needed).
        public var uniforms:Object;

        // name -> literal, prepended as `#define` lines by the backend. Values
        // must be strings or numbers; a Boolean becomes 1/0 because GLSL has no
        // bool in a preprocessor expression.
        public var defines:Object;

        // Sampler state, keyed by uniform NAME, for the samplers that are not
        // clamp/linear/no-mip. three.js keeps wrap/filter on the Texture; a raw render
        // target from Context3DNative.createTexture has no Texture wrapper, so the
        // material carries it here instead. Values: 'repeat' (tiling, mipmapped) and
        // 'repeat-nearest'; anything else -- or an absent key -- means the channel
        // default, clamp + linear + no mip filtering. See NativeShaderRenderer
        // ._applySamplerStates for why an ocean cannot be built without this.
        public var samplers:Object;

        // three.js ShaderMaterial.lights: whether the backend should inject the
        // engine's lighting uniforms. Not implemented by the Metal backend yet --
        // reading it is safe, and a caller that sets it true is told so once by
        // NativeShaderRenderer rather than silently getting an unlit shader.
        public var lights:Boolean;

        public function ShaderMaterial(parameters:Object = null)
        {
            super();
            this.vertexShader = '';
            this.fragmentShader = '';
            this.uniforms = {};
            this.defines = {};
            this.samplers = {};
            // three.js ShaderMaterial defaults for the two flags whose value is
            // not the Material base default: a shader material is usually a
            // post-process / water / sky pass that writes its own output.
            this.lights = false;
            if (parameters != null) this.setValues(parameters);
        }

        // Copy three.js setValues semantics for the fields this port models:
        // assignment only, no coercion. Kept deliberately small -- a full
        // reflection-based copy would hide a typo in the parameters object,
        // which is the opposite of what §0 asks for.
        public function setValues(values:Object):void
        {
            if (values == null) return;
            for (var key:String in values)
            {
                var v:* = values[key];
                switch (key)
                {
                    case 'vertexShader': this.vertexShader = v; break;
                    case 'fragmentShader': this.fragmentShader = v; break;
                    case 'uniforms': this.uniforms = v; break;
                    case 'defines': this.defines = v; break;
                    case 'lights': this.lights = v; break;
                    case 'transparent': this.transparent = v; break;
                    case 'opacity': this.opacity = v; break;
                    case 'side': this.side = v; break;
                    case 'blending': this.blending = v; break;
                    case 'depthTest': this.depthTest = v; break;
                    case 'depthWrite': this.depthWrite = v; break;
                    case 'visible': this.visible = v; break;
                    case 'fog': this.fog = v; break;
                    case 'toneMapped': this.toneMapped = v; break;
                    case 'name': this.name = v; break;
                    default:
                        // three.js assigns anything. We refuse instead: a
                        // misnamed parameter (e.g. `vertexShader:` spelled
                        // `vertexshader:`) would otherwise render a blank mesh
                        // with no diagnostic at all.
                        throw new ArgumentError("ShaderMaterial: unknown parameter '" + key + "'");
                }
            }
        }

        // ---- uniforms -----------------------------------------------------
        //
        // Every accessor tolerates a missing entry by ADDING it: an author
        // typically builds the table once at construction and then mutates it
        // per frame, and a `null` DereferenceError at frame 2 is a worse
        // diagnosis than a uniform that was never declared (the backend reports
        // that case as #2008 with the name).
        public function setUniformValue(name:String, value:*):void
        {
            var slot:* = this.uniforms[name];
            if (slot == null)
            {
                this.uniforms[name] = { value: value };
                return;
            }
            slot.value = value;
        }

        public function getUniformValue(name:String):*
        {
            var slot:* = this.uniforms[name];
            return (slot == null) ? null : slot.value;
        }

        public function dispose():void
        {
            this.uniforms = {};
            this.defines = {};
            this.samplers = {};
        }
    }
}