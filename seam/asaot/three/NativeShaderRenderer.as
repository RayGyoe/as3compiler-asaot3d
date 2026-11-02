// asaot.three.NativeShaderRenderer -- the E6 renderer backend.
//
// It is AGALRenderer with ONE overridden extension point: a mesh whose material is
// a ShaderMaterial is drawn through Context3DNative, where the author's GLSL ES
// 3.00 runs as written. Everything else in the engine -- the scene walk, lights,
// shadows, sorting, line/basic/standard materials, fog, background -- is the base
// class, untouched. That is deliberate: a second renderer that re-implemented the
// walk would drift from the AGAL path one scene at a time, and the two backends
// would stop being comparable.
//
// WHY EVERY flash.display3D.NATIVE MEMBER IS TYPED `Object` AND CALLED WITH
// BRACKETS. Under `adl` there is no Context3DNative class. A field typed
// `Context3DNative` is a compile error at mxmlc (#1046, type position); a
// `new Context3DNative(...)` expression compiles but throws #1065 at run time --
// and this build has to survive being compiled by BOTH compilers, because the demos
// build with `./build.sh air` as their AIR reference. So the class is resolved once
// by name and every call goes through bracket access (typed `*`). This is the same
// technique AGALRenderer.translatorClass() uses for AGALTranslator, and it costs
// exactly one cast per call. Note that the file therefore contains NO
// `import flash.display3D.Context3DNative;` either: an unused import is harmless,
// but writing it would suggest the type is usable here, which is precisely the
// mistake this comment exists to prevent.
//
// THREE.js PARITY: WHICH UNIFORMS ARE FREE. three.js hands every ShaderMaterial the
// same default uniforms without the author declaring them -- projectionMatrix,
// modelViewMatrix, modelMatrix, normalMatrix, cameraPosition, viewMatrix,
// isOrthographic. They are supplied here too (see AUTO_UNIFORMS), except
// normalMatrix / isOrthographic, which need a mat3 upload the channel does not have
// yet; a shader that declares one gets the backend's #2008 "not reflected" error
// rather than a silently zeroed matrix.
//
// ATTRIBUTE BINDING. SPIRV-Cross numbers attributes by their reflected location,
// and we bind the geometry's position/normal/uv/color onto those slots by name
// (ALIASES), falling back to declaration order (0=position, 1=normal, 2=uv, 3=color)
// for an author who used `aFoo`-style names. A custom attribute the geometry does
// not carry is left unbound and the draw proceeds -- the shader reads zeros, which
// is what an unbound Stage3D stream does too -- but the first occurrence is
// reported once with the name, because "my vertex animation does nothing" is
// otherwise indistinguishable from a math bug.
package asaot.three
{
    import flash.display3D.Context3D;
    import flash.display3D.Context3DTextureFormat;
    import flash.display3D.Context3DVertexBufferFormat;
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.VertexBuffer3D;
    import flash.display3D.textures.TextureBase;
    import flash.utils.Dictionary;
    import flash.utils.getDefinitionByName;

    import asaot.three.cameras.Camera;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.materials.ShaderMaterial;
    import asaot.three.math.Matrix4;
    import asaot.three.objects.Mesh;
    import asaot.three.textures.Texture;

    public class NativeShaderRenderer extends AGALRenderer
    {
        // Uniform names three.js supplies for free (WebGLRenderer's
        // getUniforms / programCache). Kept as a lookup so the per-draw loop can
        // skip an author override of the same name instead of fighting it.
        public static const AUTO_UNIFORMS:Array = [
            "projectionMatrix", "modelViewMatrix", "modelMatrix", "viewMatrix", "cameraPosition"
        ];

        // Reflected attribute name -> geometry attribute name. Only the four the
        // engine's BufferGeometry is guaranteed to carry.
        private static const ALIASES:Object = {
            position: "position", aPos: "position", aPosition: "position", aVertex: "position",
            normal: "normal", aNormal: "normal", aNormalDir: "normal",
            uv: "uv", aUV: "uv", aUv: "uv", aTexCoord: "uv", aTextureCoord: "uv",
            color: "color", aColor: "color"
        };

        // Declaration-order fallback for a name not in ALIASES.
        private static const BY_LOCATION:Array = ["position", "normal", "uv", "color"];

        private var _native:Object = null;                  // the Context3DNative instance
        private var _programs:Dictionary = null;            // ShaderMaterial -> entry Object
        private var _meshes:Dictionary = null;              // Mesh -> buffer entry Object
        private var _textures:Dictionary = null;            // asaot Texture -> flash TextureBase
        private var _warned:Dictionary = null;              // String -> true (report once per key)
        private var _attrCache:Dictionary = null;           // BufferGeometry -> { name -> {buffer,version,count} }
        // What this context ACTUALLY has installed per (stage, unit), keyed by
        // `stage * 32 + unit`. The sampler state is context state, not draw state: once
        // "fragment unit 3 = clamp/linear/none" is installed it stays installed until
        // somebody writes that slot. Re-sending it on every draw is pure cost -- and
        // measured cost at that: a 72-pass FFT frame issued ~150 redundant
        // setSamplerStateAtStage calls, each a dynamic AS3->native call carrying three
        // string arguments, which was ~13 ms of an 19 ms frame (the demo ran at 33 fps
        // with one core pegged while the same pass count costs Chrome a few ms).
        //
        // WHY A CACHE IS SAFE. Every writer of this state is either this method or
        // Context3D.setProgram (the AGAL path re-applies its `tex` flags in the runtime),
        // and AGALRenderer invalidates this table at each of those binds. So the table
        // is only ever stale if something writes a unit behind both paths' backs.
        private var _samplerInstalled:Object = null;

        // Every native entry point this backend calls, resolved ONCE.
        //
        // WHY THESE ARE FIELDS AND NOT `_native["name"](...)`. A bracket call on an
        // Object-typed receiver is a dynamic call: the runtime walks the instance's
        // method table by name to find the function, then invokes it. Measured on
        // this machine (arm64, -O2): 25 us per such call, versus under 0.5 us once
        // the function value is held in a field. A draw makes six of them (useProgram,
        // bindTexture, the uniform setters, drawTriangles), which is why one 256x256
        // FFT pass cost ~200 us of CPU while the Metal encode inside it measured
        // 10 us -- 72 passes a frame put ~14 ms of pure dispatch into a 19 ms frame.
        //
        // The values are FROZEN at construction. That is correct because they are
        // methods of exactly one Context3DNative instance, whose method set never
        // changes; nothing here rebinds _native to a different object.
        private var _fnUseProgram:Function = null;
        private var _fnUploadProgram:Function = null;
        private var _fnBindTexture:Function = null;
        private var _fnDrawTriangles:Function = null;
        private var _fnSetSamplerState:Function = null;
        private var _fnU1f:Function = null;
        private var _fnU2f:Function = null;
        private var _fnU3f:Function = null;
        private var _fnU4f:Function = null;
        private var _fnUInts:Function = null;
        private var _fnUFloats:Function = null;
        private var _fnUMatrix4:Function = null;
        // Scratch matrix for modelViewMatrix. NOT the base class's `_mvp`: that one
        // is reused later in the frame by the AGAL path, and a native draw that
        // scribbled on it would corrupt the next standard draw.
        private var _modelViewM:Matrix4 = null;

        public function NativeShaderRenderer(context:Context3D)
        {
            super(context);
            var cls:Class = Class(getDefinitionByName(RendererFactory.NATIVE_CONTEXT));
            // Built through the class's named factory, not `new cls(context)`:
            // in this runtime a built-in is deliberately NOT constructible through
            // a Class value (#1063 -- the registry wires no uniform ctor for one),
            // and `fromContext` says what the constructor cannot, namely that the
            // native channel is bound to exactly ONE Context3D. Passing the same
            // context matters: a second Context3DNative would own a second back
            // buffer and draw into a surface nobody presents.
            _native = cls["fromContext"](context);
            _programs = new Dictionary();
            _meshes = new Dictionary();
            _textures = new Dictionary();
            _warned = new Dictionary();
            _modelViewM = new Matrix4();
            _samplerInstalled = {};
            _fnUseProgram = _native["useProgram"];
            _fnUploadProgram = _native["uploadProgram"];
            _fnBindTexture = _native["bindTexture"];
            _fnDrawTriangles = _native["drawTriangles"];
            _fnSetSamplerState = _native["setSamplerStateAtStage"];
            _fnU1f = _native["setUniform1f"];
            _fnU2f = _native["setUniform2f"];
            _fnU3f = _native["setUniform3f"];
            _fnU4f = _native["setUniform4f"];
            _fnUInts = _native["setUniformInts"];
            _fnUFloats = _native["setUniformFloats"];
            _fnUMatrix4 = _native["setUniformMatrix4"];
        }

        // Answers the question a demo asks when it wants to print its backend.
        public function get context3DNative():Object
        {
            return _native;
        }

        // Draw one mesh through the native channel, WITHOUT a scene walk.
        //
        // Exists for the caller that owns its render target (M7's FFT passes: bind
        // two float attachments, draw a full-screen quad, repeat 16 times). Those
        // passes have no Scene and no frustum, so `render()` cannot express them --
        // but they still must go through the SAME code the scene walk uses, or the
        // pass path and the mesh path would drift on uniform/attribute binding.
        // The caller is responsible for the target (setRenderTargets/setBackBuffer)
        // and for `_camera` being current, which any preceding render() provides.
        public function drawNative(mesh:Mesh, material:ShaderMaterial):void
        {
            this._drawShaderMaterial(mesh, material);
        }

        // ------------------------------------------------------------------
        // The one overridden step.
        // ------------------------------------------------------------------
        override protected function _drawShaderMaterial(mesh:Mesh, material:ShaderMaterial):void
        {
            if (material.lights)
            {
                this._warn("lights", "ShaderMaterial.lights = true is not implemented by the native " +
                    "backend: no engine lighting uniforms are injected, the draw is unlit");
            }

            var entry:Object = this._ensureProgram(material);
            if (entry == null || entry["dead"] == true) return;   // reported once already

            var program:Object = entry["program"];
            _fnUseProgram(program);
            this._applySamplerStates(entry, material);

            this._uploadAutoUniforms(entry, mesh, program);
            this._uploadAuthorUniforms(entry, material, program);

            var buffers:Object = this._ensureBuffers(mesh);
            if (buffers == null) return;                     // geometry without position

            this._bindAttributes(entry, buffers, mesh);
            _fnDrawTriangles(program, buffers["ibo"], 0, -1);
        }

        // ------------------------------------------------------------------
        // Sampler state
        // ------------------------------------------------------------------
        // three.js puts wrap/filter on the TEXTURE; a render target obtained from
        // Context3DNative.createTexture is a bare TextureBase with nowhere to put them.
        // So the material carries the table instead: `samplers: { uDisp0: 'repeat',
        // uSlope1: 'repeat' }`, i.e. only the names that need something other than the
        // clamp/linear/no-mip default.
        //
        // WHY THIS MATTERS. Without it a native sampler gets clamp-to-edge and
        // MTLMipFilterNotMipmapped (stage3d_glue s3d_native_bind_texture), so a
        // textureLod(uSlope0, uv, 8.0) -- how a mean-square-slope average is read --
        // silently returns level 0 and an ocean tile cannot repeat at all. Both are
        // invisible in a screenshot and fatal to the model, so the state is applied
        // from the reflection's own unit numbers instead of guessed.
        //
        // STATE IS PER (STAGE, UNIT), not per unit: SPIRV-Cross numbers samplers per
        // stage, so an ocean surface has repeat-wrapped displacement atlases at vertex
        // unit 0..2 and a clamp-wrapped screen texture at fragment unit 0. Those are
        // different Metal samplers that merely share a number, so each is configured on
        // its own stage instead of forcing one mode onto both.
        // Called by AGALRenderer whenever an AGAL program is bound: the runtime applies
        // that program's `tex` flags to the per-unit sampler state, so whatever this
        // table remembers about those slots is no longer true. Cheap (it is one object
        // literal), and it runs once per AGAL draw, not per native one.
        override protected function invalidateSamplerCache():void
        {
            _samplerInstalled = {};
        }

        private function _applySamplerStates(entry:Object, material:ShaderMaterial):void
        {
            var list:Array = entry["texList"];
            if (list == null) return;
            var declared:Object = material.samplers != null ? material.samplers : {};
            var n:int = list.length;
            for (var i:int = 0; i < n; i++)
            {
                var t:Object = list[i];
                var mode:String = declared[t["name"]] != null ? String(declared[t["name"]]) : "";
                var stage:int = int(t["stage"]);
                var unit:int = int(t["slot"]);
                // One canonical token per state, so the comparison is a string identity
                // check rather than three branches.
                var state:String;
                if (mode == "repeat") state = "repeat";
                else if (mode == "repeat-nearest") state = "repeat-nearest";
                else state = "clamp";
                var key:int = stage * 32 + unit;
                if (_samplerInstalled[key] == state) continue;
                _samplerInstalled[key] = state;
                if (mode == "repeat")
                    _fnSetSamplerState(stage, unit, "repeat", "linear", "linear");
                else if (mode == "repeat-nearest")
                    _fnSetSamplerState(stage, unit, "repeat", "nearest", "nearest");
                else
                    _fnSetSamplerState(stage, unit, "clamp", "linear", "none");
            }
        }

        // Debug aid: the reflected binding table of a material's program, one line per
        // binding. Kept because "the uniform is 0" and "the program never declared it"
        // are indistinguishable from outside, and this answers it in one log line.
        public function describeProgram(material:ShaderMaterial):String
        {
            var entry:Object = _ensureProgram(material);
            if (entry == null) return "(no program)";
            var p:Object = entry["program"];
            if (p == null) return "(no program object)";
            // A dead program draws nothing and says nothing: the compile log is the only
            // way to tell "the shader is wrong" apart from "the pass never ran".
            if (p["ok"] != true) return "(COMPILE FAILED) " + p["infoLog"];
            if (p["bindingNames"] == null) return "(no reflection)";
            var names:Array = p["bindingNames"];
            var kinds:Array = p["bindingKinds"];
            var slots:Array = p["bindingSlots"];
            var stages:Array = p["bindingStages"];
            var bases:Array = p["bindingBaseTypes"];
            var comps:Array = p["bindingComponents"];
            var out:String = "";
            for (var i:int = 0; i < names.length; i++)
            {
                out = out + "    " + int(stages == null ? 0 : stages[i]) + "/" + kinds[i] + " slot " +
                    int(slots[i]) + " base " + int(bases == null ? 0 : bases[i]) + " x" +
                    int(comps == null ? 1 : comps[i]) + " " + String(names[i]) + "\n";
            }
            return out;
        }

        private function _ensureProgram(material:ShaderMaterial):Object
        {
            var entry:Object = _programs[material];
            if (entry != null && entry["version"] == material.version) return entry;

            var vs:String = this._withDefines(material.vertexShader, material.defines);
            var fs:String = this._withDefines(material.fragmentShader, material.defines);
            var program:Object = _fnUploadProgram(vs, fs);
            entry = {
                program: program,
                version: material.version,
                uniforms: {},
                attributes: []
            };
            _programs[material] = entry;

            if (!program["ok"])
            {
                // Loud and actionable: the glslang text has the file:line:col in
                // it, which is the only thing that makes a shader bug findable.
                this._warn("prog:" + program["infoLog"],
                    "ShaderMaterial '" + labelOf(material) + "' failed to compile:\n" + program["infoLog"]);
                entry["dead"] = true;
                return entry;
            }
            entry["dead"] = false;
            this._indexReflection(entry, program);
            return entry;
        }

        // `defines` become `#define` lines right after the version directive. GLSL
        // requires the version line to be first, so inserting at the top would
        // break every shader; the version line is skipped when present.
        private function _withDefines(source:String, defines:Object):String
        {
            if (defines == null) return source;
            var lines:String = "";
            var any:Boolean = false;
            for (var key:String in defines)
            {
                var v:* = defines[key];
                lines += "#define " + key + " " + (v == true ? "1" : (v == false ? "0" : v)) + "\n";
                any = true;
            }
            if (!any) return source;

            var nl:int = source.indexOf("\n");
            if (nl >= 0 && source.substr(0, nl).indexOf("#version") >= 0)
            {
                return source.substr(0, nl + 1) + lines + source.substr(nl + 1);
            }
            return lines + source;
        }

        // Split the reflection table into "attributes, by location" and "uniforms,
        // by name + scalar category", once per compile. Doing it per draw would walk
        // six arrays on every mesh.
        //
        // The category matters: feeding a float to `uniform int uSub` stores the BIT
        // PATTERN of 2.0 (1073741824), which Metal accepts and the shader then uses as
        // a loop bound. The FFT passes are almost entirely integer uniforms (uSub,
        // uVertical, uCascade, uSeed), so this is the difference between an ocean and
        // a black screen.
        private function _indexReflection(entry:Object, program:Object):void
        {
            var names:Array = program["bindingNames"];
            var kinds:Array = program["bindingKinds"];
            var slots:Array = program["bindingSlots"];
            var comps:Array = program["bindingComponents"];
            var bases:Array = program["bindingBaseTypes"];
            var sizes:Array = program["bindingSizes"];
            var stages:Array = program["bindingStages"];
            var attrs:Object = {};
            var uniforms:Object = {};
            var textures:Object = {};
            var texList:Array = [];
            if (names == null) return;
            for (var i:int = 0; i < names.length; i++)
            {
                var kind:int = kinds[i];
                if (kind == 3)                                 // ASC_SHADER_KIND_ATTRIBUTE
                {
                    attrs[String(slots[i])] = String(names[i]);
                }
                else if (kind == 2)                            // ASC_SHADER_KIND_TEXTURE
                {
                    // [name] -> sampler unit. Kept apart from `uniforms` because it is
                    // the unit -- not the value -- that carries the filter/wrap state
                    // (see _applySamplerStates).
                    textures[String(names[i])] = int(slots[i]);
                    texList.push({ name: String(names[i]), slot: int(slots[i]),
                                   stage: stages == null ? 0 : int(stages[i]) });
                }
                else
                {
                    uniforms[String(names[i])] = {
                        components: comps == null ? 1 : int(comps[i]),
                        baseType: bases == null ? 0 : int(bases[i]),
                        size: sizes == null ? 1 : int(sizes[i])
                    };
                }
            }
            entry["attrs"] = attrs;
            entry["uniforms"] = uniforms;
            entry["textures"] = textures;
            entry["texList"] = texList;
        }

        // ------------------------------------------------------------------
        // Uniforms
        // ------------------------------------------------------------------
        private function _uploadAutoUniforms(entry:Object, mesh:Mesh, program:Object):void
        {
            var camera:Camera = this._camera;
            if (camera == null) return;

            this._setMatrixIfDeclared(entry, program, "projectionMatrix", camera.projectionMatrix.elements);
            this._setMatrixIfDeclared(entry, program, "viewMatrix", camera.matrixWorldInverse.elements);
            this._setMatrixIfDeclared(entry, program, "modelMatrix", mesh.matrixWorld.elements);

            var mv:Matrix4 = this._modelViewM;
            mv.multiplyMatrices(camera.matrixWorldInverse, mesh.matrixWorld);
            this._setMatrixIfDeclared(entry, program, "modelViewMatrix", mv.elements);

            var e:Vector.<Number> = camera.matrixWorld.elements;
            this._setUniformIfDeclared(entry, program, "cameraPosition", [e[12], e[13], e[14]]);
        }

        private function _uploadAuthorUniforms(entry:Object, material:ShaderMaterial, program:Object):void
        {
            var table:Object = material.uniforms;
            if (table == null) return;
            for (var name:String in table)
            {
                if (AUTO_UNIFORMS.indexOf(name) >= 0) continue;   // the auto value wins
                var slot:* = table[name];
                if (slot == null) continue;
                var value:* = slot.value;
                if (value == null) continue;
                this._setUniformIfDeclared(entry, program, name, value);
            }
        }

        private function _setMatrixIfDeclared(entry:Object, program:Object, name:String, data:Vector.<Number>):void
        {
            this._setUniformIfDeclared(entry, program, name, data);
        }

        // Dispatch by the REFLECTED shape, not by the AS3 value alone. The reflection
        // table now carries `components` (scalars per element), `size` (array length)
        // and `baseType` (float/int/uint/bool), which is exactly what is needed to
        // choose both the entry point and the bit pattern:
        //
        //   int/uint/bool  -> setUniformInts    (a float would be reinterpreted)
        //   float, >4 words-> setUniformFloats  (a vec4[2] is one 8-word payload)
        //   float, 1..4    -> setUniform1f..4f
        //
        // A name the program does not declare is dropped HERE (the shader does not
        // need it); an author-visible mistake is caught by the backend's #2008 only
        // when the program does declare it, so a typo inside material.uniforms is
        // reported by the first draw, not swallowed.
        private function _setUniformIfDeclared(entry:Object, program:Object, name:String, value:*):void
        {
            var spec:Object = (entry != null && entry["uniforms"] != null) ? entry["uniforms"][name] : null;
            // Samplers live in their own table (that is where the sampler UNIT is kept),
            // so "not in `uniforms`" does NOT mean "not declared". Testing only `uniforms`
            // dropped every texture the material carried -- the bind never happened and
            // the sample read an unbound unit, which is black, not an error.
            var units:Object = (entry != null && entry["textures"] != null) ? entry["textures"] : null;
            var isSampler:Boolean = (spec == null && units != null && units[name] != null);
            if (spec == null && !isSampler)
            {
                // The program does not declare it. For an AUTO uniform that is normal
                // (the shader uses none of them); for an author uniform it is almost
                // always a typo, and the backend would answer #2008 -- which is right
                // for a hand-written call and wrong to throw from inside a frame.
                if (AUTO_UNIFORMS.indexOf(name) < 0)
                {
                    this._warn("u2:" + name, "material.uniforms carries '" + name +
                        "' but the program does not declare it (typo, or a uniform another " +
                        "program of this material uses); it is not uploaded");
                }
                return;
            }

            if (value is Texture)
            {
                var tex:TextureBase = this._ensureTexture(Texture(value));
                if (tex != null) _fnBindTexture(program, name, tex);
                return;
            }
            // A render target created by Context3DNative.createTexture IS already a
            // flash Texture, so there is nothing to upload: bind it as-is. Without
            // this branch an offscreen pass could not read what the previous pass
            // wrote, which is the whole shape of an FFT ocean.
            if (value is TextureBase)
            {
                _fnBindTexture(program, name, TextureBase(value));
                return;
            }

            if (spec == null)
            {
                // declared as a sampler but handed something that is not a texture
                this._warn("s:" + name, "shader sampler '" + name +
                    "' was given a non-texture value; the unit stays unbound");
                return;
            }

            var baseType:int = int(spec["baseType"]);
            var want:int = int(spec["components"]) * int(spec["size"]);

            if (value is Vector.<Number> || value is Array)
            {
                var v:Vector.<Number> = (value is Vector.<Number>) ? Vector.<Number>(value) : this._toNumbers(value);
                if (baseType != 0)
                {
                    _fnUInts(program, name, this._toInts(v));
                    return;
                }
                if (want == 16) { _fnUMatrix4(program, name, v); return; }
                if (want > 4 || v.length > 4) { _fnUFloats(program, name, v); return; }
                if (v.length == 4) { _fnU4f(program, name, v[0], v[1], v[2], v[3]); return; }
                if (v.length == 3) { _fnU3f(program, name, v[0], v[1], v[2]); return; }
                if (v.length == 2) { _fnU2f(program, name, v[0], v[1]); return; }
                if (v.length == 1) { _fnU1f(program, name, v[0]); return; }
                this._warn("u:" + name, "ShaderMaterial uniform '" + name + "' has " + v.length +
                    " components; the native channel takes 1, 2, 3, 4 or 16");
                return;
            }
            if (value is Number || value is Boolean || value is int || value is uint)
            {
                if (baseType != 0)
                {
                    var iv:Vector.<int> = new Vector.<int>(1, false);
                    iv[0] = int(Number(value));
                    _fnUInts(program, name, iv);
                    return;
                }
                _fnU1f(program, name, value ? Number(value) : 0);
                return;
            }
            // A type the channel cannot express (Object, String...). Report once:
            // silently skipping this is how "my uniform is always 0" starts.
            this._warn("t:" + name, "ShaderMaterial uniform '" + name +
                "' is not a Number/Vector/Texture, which is all the native channel binds");
        }

        // Flatten nested arrays ([Vector4, Vector4] for a vec4[2]) into one run, so a
        // GLSL array uniform can be written the way three.js writes it.
        private function _toNumbers(list:Array):Vector.<Number>
        {
            var out:Vector.<Number> = new Vector.<Number>(0, false);
            for (var i:int = 0; i < list.length; i++)
            {
                var e:* = list[i];
                if (e is Array || e is Vector.<Number>)
                {
                    var inner:Vector.<Number> = this._toNumbers(e as Array);
                    for (var k:int = 0; k < inner.length; k++) out.push(inner[k]);
                }
                else
                {
                    out.push(Number(e));
                }
            }
            return out;
        }

        private function _toInts(list:Vector.<Number>):Vector.<int>
        {
            var out:Vector.<int> = new Vector.<int>(list.length, false);
            for (var i:int = 0; i < list.length; i++) out[i] = int(list[i]);
            return out;
        }

        // ------------------------------------------------------------------
        // Geometry
        // ------------------------------------------------------------------
        private function _ensureBuffers(mesh:Mesh):Object
        {
            var geometry:BufferGeometry = mesh.geometry;
            if (geometry == null) return null;
            var position:BufferAttribute = geometry.getAttribute("position");
            if (position == null) return null;

            var b:Object = _meshes[mesh];
            var index:BufferAttribute = geometry.getIndex();
            if (b == null)
            {
                b = { vbo: null, ibo: null, positionVersion: -1, indexVersion: -1, count: 0 };
                _meshes[mesh] = b;
            }

            if (b["vbo"] == null || b["positionVersion"] != position.version || b["count"] != position.count)
            {
                var vbo:VertexBuffer3D = _context.createVertexBuffer(position.count, position.itemSize);
                vbo.uploadFromVector(position.array, 0, position.count);
                b["vbo"] = vbo;
                b["positionVersion"] = position.version;
                b["count"] = position.count;
            }

            // Non-indexed geometry: Stage3D has no drawArrays, so the implicit
            // 0..n-1 sequence is uploaded as a real index buffer once. Doing this
            // per draw would allocate a buffer per frame.
            if (index == null)
            {
                if (b["ibo"] == null)
                {
                    var seq:Vector.<uint> = new Vector.<uint>(position.count, false);
                    for (var i:int = 0; i < position.count; i++) seq[i] = i;
                    var gen:IndexBuffer3D = _context.createIndexBuffer(position.count, "staticDraw");
                    gen.uploadFromVector(seq, 0, position.count);
                    b["ibo"] = gen;
                    b["indexVersion"] = -1;
                }
            }
            else if (b["ibo"] == null || b["indexVersion"] != index.version || b["indexCount"] != index.count)
            {
                var ibo:IndexBuffer3D = _context.createIndexBuffer(index.count, "staticDraw");
                ibo.uploadFromVector(this._toUints(index.array), 0, index.count);
                b["ibo"] = ibo;
                b["indexVersion"] = index.version;
                b["indexCount"] = index.count;
            }
            return b;
        }

        private function _toUints(list:Vector.<Number>):Vector.<uint>
        {
            var out:Vector.<uint> = new Vector.<uint>(list.length, false);
            for (var i:int = 0; i < list.length; i++) out[i] = uint(list[i]);
            return out;
        }

        private function _bindAttributes(entry:Object, buffers:Object, mesh:Mesh):void
        {
            var attrs:Object = entry["attrs"];
            if (attrs == null) return;
            var geometry:BufferGeometry = mesh.geometry;
            for (var slot:String in attrs)
            {
                var name:String = String(attrs[slot]);
                var target:String = ALIASES[name];
                if (target == null)
                {
                    var byLoc:int = int(slot);
                    target = (byLoc >= 0 && byLoc < BY_LOCATION.length) ? BY_LOCATION[byLoc] : null;
                }
                if (target == null)
                {
                    this._warn("a:" + name, "shader attribute '" + name + "' has no engine equivalent " +
                        "(expected position/normal/uv/color); it stays unbound and reads zeros");
                    continue;
                }
                if (target == "position")
                {
                    var p:BufferAttribute = geometry.getAttribute("position");
                    _context.setVertexBufferAt(int(slot), buffers["vbo"], 0, this._formatOf(p.itemSize));
                    continue;
                }
                var attr:BufferAttribute = geometry.getAttribute(target);
                if (attr == null)
                {
                    this._warn("a2:" + name, "shader attribute '" + name + "' wants geometry '" + target +
                        "', which this geometry does not carry; it stays unbound and reads zeros");
                    continue;
                }
                var buf:VertexBuffer3D = this._ensureAttributeBuffer(geometry, target, attr);
                _context.setVertexBufferAt(int(slot), buf, 0, this._formatOf(attr.itemSize));
            }
        }

        // One extra stream buffer per (geometry, attribute) pair. The base class
        // keeps its own cache for the AGAL layout (position in stream 0, normal 1,
        // uv 2); the native layout is driven by the shader's own locations, so the
        // buffers cannot be shared without knowing whether the two layouts agree.
        private function _ensureAttributeBuffer(geometry:BufferGeometry, key:String, attr:BufferAttribute):VertexBuffer3D
        {
            if (_attrCache == null) _attrCache = new Dictionary();
            var perGeometry:Object = _attrCache[geometry];
            if (perGeometry == null) { perGeometry = {}; _attrCache[geometry] = perGeometry; }
            var rec:Object = perGeometry[key];
            if (rec != null && rec["version"] == attr.version && rec["count"] == attr.count)
            {
                return rec["buffer"];
            }
            var buf:VertexBuffer3D = _context.createVertexBuffer(attr.count, attr.itemSize);
            buf.uploadFromVector(attr.array, 0, attr.count);
            perGeometry[key] = { buffer: buf, version: attr.version, count: attr.count };
            return buf;
        }

        private function _formatOf(itemSize:int):String
        {
            switch (itemSize)
            {
                case 1: return Context3DVertexBufferFormat.FLOAT_1;
                case 2: return Context3DVertexBufferFormat.FLOAT_2;
                case 3: return Context3DVertexBufferFormat.FLOAT_3;
                default: return Context3DVertexBufferFormat.FLOAT_4;
            }
        }

        // ------------------------------------------------------------------
        // Textures
        // ------------------------------------------------------------------
        // The engine's Texture carries a BitmapData, not a GPU handle (that is the
        // whole point of the texture layer -- it is backend-agnostic). So a native
        // sampler needs the same upload the AGAL path does, keyed on
        // Texture.version so a `needsUpdate` re-uploads.
        private function _ensureTexture(tex:Texture):TextureBase
        {
            if (tex == null || tex.image == null) return null;
            var rec:Object = _textures[tex];
            if (rec != null && rec["version"] == tex.version) return TextureBase(rec["gpu"]);

            var gpu:flash.display3D.textures.Texture = _context.createTexture(
                tex.image.width, tex.image.height, Context3DTextureFormat.BGRA, false);
            gpu.uploadFromBitmapData(tex.image, 0);
            _textures[tex] = { gpu: gpu, version: tex.version };
            return gpu;
        }

        // ------------------------------------------------------------------
        // Diagnostics
        // ------------------------------------------------------------------
        private function _warn(key:String, message:String):void
        {
            if (_warned[key] == true) return;
            _warned[key] = true;
            trace("[NativeShaderRenderer] " + message);
        }
    }
}