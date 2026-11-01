// asaot3d/probes/agal-m6-probe/AgalM6Probe.as -- M6 punctual AGAL assembly probe.
//
// Assembles the M6 point/spot fragment programs (copied from
// AGALRenderer._buildPunctualProgram) through AGALMiniAssembler to verify:
//   1. AGAL syntax parses (assembler error empty),
//   2. instruction count stays under the 200-instruction translator cap,
//   3. no temp register read-before-write (checked by as_agal_translate at
//      upload time -- here we only confirm the assembler accepted it).
//
// Run (from asaot3d/):
//   node ../as3compiler/src/index.ts probes/agal-m6-probe/AgalM6Probe.as \
//        seam/com/adobe/utils/AGALMiniAssembler.as \
//        -o temp/agal-m6-probe.exe --run
import com.adobe.utils.AGALMiniAssembler;
import flash.display3D.Context3DProgramType;
import flash.utils.ByteArray;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

// Point-light fragment program (no spot cone stage).
var pointFrag:String =
    'nrm ft0.xyz, v0.xyz\n' +
    'ddx ft4.xyz, v1.xyz\n' +
    'ddy ft5.xyz, v1.xyz\n' +
    'ddx ft6.xy, v2.xyzw\n' +
    'ddy ft6.zw, v3.xyzw\n' +
    'crs ft7.xyz, ft5.xyz, ft0.xyz\n' +
    'crs ft8.xyz, ft0.xyz, ft4.xyz\n' +
    'mul ft9.xyz, ft7.xyz, ft6.xxxx\n' +
    'mul ft10.xyz, ft8.xyz, ft6.zzzz\n' +
    'add ft9.xyz, ft9.xyz, ft10.xyz\n' +
    'mul ft10.xyz, ft7.xyz, ft6.yyyy\n' +
    'mul ft11.xyz, ft8.xyz, ft6.wwww\n' +
    'add ft10.xyz, ft10.xyz, ft11.xyz\n' +
    'dp3 ft11.x, ft9.xyz, ft9.xyz\n' +
    'dp3 ft11.y, ft10.xyz, ft10.xyz\n' +
    'max ft11.x, ft11.x, ft11.y\n' +
    'max ft11.x, ft11.x, fc0.wwww\n' +
    'sqt ft11.x, ft11.x\n' +
    'rcp ft11.x, ft11.x\n' +
    'mul ft9.xyz, ft9.xyz, ft11.xxxx\n' +
    'mul ft10.xyz, ft10.xyz, ft11.xxxx\n' +
    'tex ft11, v2.xy, fs1 <2d,clamp,linear,mipnone>\n' +
    'mul ft11.xyz, ft11.xyz, fc8.zzzz\n' +
    'sub ft11.xyz, ft11.xyz, fc6.wwww\n' +
    'mul ft11.xy, ft11.xy, fc8.xy\n' +
    'mul ft4.xyz, ft9.xyz, ft11.xxxx\n' +
    'mul ft5.xyz, ft10.xyz, ft11.yyyy\n' +
    'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
    'mul ft5.xyz, ft0.xyz, ft11.zzzz\n' +
    'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
    'nrm ft0.xyz, ft4.xyz\n' +
    'sub ft1.xyz, fc0.xyz, v1.xyz\n' +
    'nrm ft1.xyz, ft1.xyz\n' +
    'sub ft9.xyz, fc1.xyz, v1.xyz\n' +
    'dp3 ft10.x, ft9.xyz, ft9.xyz\n' +
    'sqt ft10.x, ft10.x\n' +
    'div ft9.xyz, ft9.xyz, ft10.xxxx\n' +
    'pow ft10.y, ft10.x, fc9.y\n' +
    'max ft10.y, ft10.y, fc9.z\n' +
    'rcp ft10.y, ft10.y\n' +
    'mul ft10.z, ft10.x, fc9.x\n' +
    'mul ft10.z, ft10.z, ft10.z\n' +
    'mul ft10.z, ft10.z, ft10.z\n' +
    'sub ft10.w, fc6.w, ft10.z\n' +
    'sat ft10.w, ft10.w\n' +
    'mul ft10.w, ft10.w, ft10.w\n' +
    'mul ft10.y, ft10.y, ft10.w\n' +
    'add ft2.xyz, ft9.xyz, ft1.xyz\n' +
    'nrm ft2.xyz, ft2.xyz\n' +
    'dp3 ft3.x, ft0.xyz, ft9.xyz\n' +
    'sat ft3.x, ft3.x\n' +
    'dp3 ft3.y, ft0.xyz, ft1.xyz\n' +
    'sat ft3.y, ft3.y\n' +
    'dp3 ft3.z, ft0.xyz, ft2.xyz\n' +
    'sat ft3.z, ft3.z\n' +
    'dp3 ft3.w, ft1.xyz, ft2.xyz\n' +
    'sat ft3.w, ft3.w\n' +
    'tex ft2, v2.xy, fs0 <2d,clamp,linear,mipnone>\n' +
    'mul ft2.xyz, ft2.xyz, fc4.xyz\n' +
    'tex ft4, v2.xy, fs2 <2d,clamp,linear,mipnone>\n' +
    'mul ft5.x, fc5.x, ft4.y\n' +
    'tex ft4, v2.xy, fs3 <2d,clamp,linear,mipnone>\n' +
    'mul ft5.y, fc5.y, ft4.z\n' +
    'sub ft5.z, fc6.w, ft5.y\n' +
    'mov ft5.w, fc5.w\n' +
    'mul ft6.xyz, fc6.xyz, ft5.zzz\n' +
    'mul ft7.xyz, ft2.xyz, ft5.yyy\n' +
    'add ft6.xyz, ft6.xyz, ft7.xyz\n' +
    'mul ft4.xyz, ft2.xyz, ft5.zzz\n' +
    'mul ft7.x, ft5.x, ft5.x\n' +
    'mul ft7.y, ft7.x, ft7.x\n' +
    'mul ft7.z, ft3.z, ft3.z\n' +
    'sub ft7.w, ft7.y, fc6.w\n' +
    'mul ft7.z, ft7.z, ft7.w\n' +
    'add ft7.z, ft7.z, fc6.w\n' +
    'mul ft7.z, ft7.z, ft7.z\n' +
    'mul ft8.x, fc5.w, ft7.y\n' +
    'div ft8.x, ft8.x, ft7.z\n' +
    'sub ft7.z, fc6.w, ft7.y\n' +
    'mul ft7.w, ft3.y, ft3.y\n' +
    'mul ft7.z, ft7.z, ft7.w\n' +
    'add ft7.z, ft7.z, ft7.y\n' +
    'sqt ft7.z, ft7.z\n' +
    'mul ft7.z, ft3.x, ft7.z\n' +
    'sub ft7.w, fc6.w, ft7.y\n' +
    'mul ft7.x, ft3.x, ft3.x\n' +
    'mul ft7.w, ft7.w, ft7.x\n' +
    'add ft7.w, ft7.w, ft7.y\n' +
    'sqt ft7.w, ft7.w\n' +
    'mul ft7.w, ft3.y, ft7.w\n' +
    'add ft7.z, ft7.z, ft7.w\n' +
    'max ft7.z, ft7.z, fc0.wwww\n' +
    'rcp ft7.z, ft7.z\n' +
    'mul ft7.z, ft7.z, fc1.wwww\n' +
    'mul ft4.w, ft7.z, ft8.x\n' +
    'mul ft7.xyz, ft4.xyz, fc5.wwww\n' +
    'sub ft8.y, fc6.w, ft3.w\n' +
    'mul ft8.z, ft8.y, ft8.y\n' +
    'mul ft8.z, ft8.z, ft8.z\n' +
    'mul ft8.z, ft8.z, ft8.y\n' +
    'sub ft8.w, fc6.w, ft8.z\n' +
    'mul ft8.w, fc6.x, ft8.w\n' +
    'add ft8.w, ft8.w, ft8.z\n' +
    'sub ft8.w, fc6.w, ft8.w\n' +
    'mul ft8.w, ft8.w, ft3.x\n' +
    'mul ft8.xyz, ft8.wwww, fc2.xyz\n' +
    'mul ft8.xyz, ft8.xyz, ft10.yyyy\n' +
    'mul ft8.xyz, ft8.xyz, ft7.xyz\n' +
    'mov ft4.xyz, ft8.xyz\n' +
    'sub ft7.w, fc6.w, ft3.w\n' +
    'mul ft8.y, ft7.w, ft7.w\n' +
    'mul ft8.y, ft8.y, ft8.y\n' +
    'mul ft8.y, ft8.y, ft7.w\n' +
    'sub ft8.z, fc6.w, ft8.y\n' +
    'mul ft7.xyz, ft6.xyz, ft8.zzz\n' +
    'add ft7.xyz, ft7.xyz, ft8.yyy\n' +
    'mul ft7.xyz, ft7.xyz, ft4.wwww\n' +
    'mul ft7.xyz, ft7.xyz, ft3.xxxx\n' +
    'mul ft7.xyz, ft7.xyz, fc2.xyz\n' +
    'mul ft7.xyz, ft7.xyz, ft10.yyyy\n' +
    'add ft4.xyz, ft4.xyz, ft7.xyz\n' +
    'sat ft4.xyz, ft4.xyz\n' +
    'pow ft4.x, ft4.x, fc3.w\n' +
    'pow ft4.y, ft4.y, fc3.w\n' +
    'pow ft4.z, ft4.z, fc3.w\n' +
    // AIR #3701: `oc` is written whole, once (a masked .xyz write plus a
    // separate .w write is refused at upload).
    'mov ft4.w, fc6.w\n' +
    'mov oc, ft4\n';

// Spot-light fragment program: point program + the cone attenuation stage.
var spotFrag:String =
    'nrm ft0.xyz, v0.xyz\n' +
    'ddx ft4.xyz, v1.xyz\n' +
    'ddy ft5.xyz, v1.xyz\n' +
    'ddx ft6.xy, v2.xyzw\n' +
    'ddy ft6.zw, v3.xyzw\n' +
    'crs ft7.xyz, ft5.xyz, ft0.xyz\n' +
    'crs ft8.xyz, ft0.xyz, ft4.xyz\n' +
    'mul ft9.xyz, ft7.xyz, ft6.xxxx\n' +
    'mul ft10.xyz, ft8.xyz, ft6.zzzz\n' +
    'add ft9.xyz, ft9.xyz, ft10.xyz\n' +
    'mul ft10.xyz, ft7.xyz, ft6.yyyy\n' +
    'mul ft11.xyz, ft8.xyz, ft6.wwww\n' +
    'add ft10.xyz, ft10.xyz, ft11.xyz\n' +
    'dp3 ft11.x, ft9.xyz, ft9.xyz\n' +
    'dp3 ft11.y, ft10.xyz, ft10.xyz\n' +
    'max ft11.x, ft11.x, ft11.y\n' +
    'max ft11.x, ft11.x, fc0.wwww\n' +
    'sqt ft11.x, ft11.x\n' +
    'rcp ft11.x, ft11.x\n' +
    'mul ft9.xyz, ft9.xyz, ft11.xxxx\n' +
    'mul ft10.xyz, ft10.xyz, ft11.xxxx\n' +
    'tex ft11, v2.xy, fs1 <2d,clamp,linear,mipnone>\n' +
    'mul ft11.xyz, ft11.xyz, fc8.zzzz\n' +
    'sub ft11.xyz, ft11.xyz, fc6.wwww\n' +
    'mul ft11.xy, ft11.xy, fc8.xy\n' +
    'mul ft4.xyz, ft9.xyz, ft11.xxxx\n' +
    'mul ft5.xyz, ft10.xyz, ft11.yyyy\n' +
    'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
    'mul ft5.xyz, ft0.xyz, ft11.zzzz\n' +
    'add ft4.xyz, ft4.xyz, ft5.xyz\n' +
    'nrm ft0.xyz, ft4.xyz\n' +
    'sub ft1.xyz, fc0.xyz, v1.xyz\n' +
    'nrm ft1.xyz, ft1.xyz\n' +
    'sub ft9.xyz, fc1.xyz, v1.xyz\n' +
    'dp3 ft10.x, ft9.xyz, ft9.xyz\n' +
    'sqt ft10.x, ft10.x\n' +
    'div ft9.xyz, ft9.xyz, ft10.xxxx\n' +
    'pow ft10.y, ft10.x, fc9.y\n' +
    'max ft10.y, ft10.y, fc9.z\n' +
    'rcp ft10.y, ft10.y\n' +
    'mul ft10.z, ft10.x, fc9.x\n' +
    'mul ft10.z, ft10.z, ft10.z\n' +
    'mul ft10.z, ft10.z, ft10.z\n' +
    'sub ft10.w, fc6.w, ft10.z\n' +
    'sat ft10.w, ft10.w\n' +
    'mul ft10.w, ft10.w, ft10.w\n' +
    'mul ft10.y, ft10.y, ft10.w\n' +
    'dp3 ft11.x, ft9.xyz, fc3.xyz\n' +
    'sub ft11.x, ft11.x, fc10.x\n' +
    'sub ft11.y, fc10.y, fc10.x\n' +
    'max ft11.y, ft11.y, fc0.wwww\n' +
    'div ft11.x, ft11.x, ft11.y\n' +
    'sat ft11.x, ft11.x\n' +
    'mul ft11.y, ft11.x, ft11.x\n' +
    'mul ft11.w, ft11.x, fc10.w\n' +
    'sub ft11.z, fc10.z, ft11.w\n' +
    'mul ft11.y, ft11.y, ft11.z\n' +
    'mul ft10.y, ft10.y, ft11.y\n' +
    'add ft2.xyz, ft9.xyz, ft1.xyz\n' +
    'nrm ft2.xyz, ft2.xyz\n' +
    'dp3 ft3.x, ft0.xyz, ft9.xyz\n' +
    'sat ft3.x, ft3.x\n' +
    'dp3 ft3.y, ft0.xyz, ft1.xyz\n' +
    'sat ft3.y, ft3.y\n' +
    'dp3 ft3.z, ft0.xyz, ft2.xyz\n' +
    'sat ft3.z, ft3.z\n' +
    'dp3 ft3.w, ft1.xyz, ft2.xyz\n' +
    'sat ft3.w, ft3.w\n' +
    'tex ft2, v2.xy, fs0 <2d,clamp,linear,mipnone>\n' +
    'mul ft2.xyz, ft2.xyz, fc4.xyz\n' +
    'tex ft4, v2.xy, fs2 <2d,clamp,linear,mipnone>\n' +
    'mul ft5.x, fc5.x, ft4.y\n' +
    'tex ft4, v2.xy, fs3 <2d,clamp,linear,mipnone>\n' +
    'mul ft5.y, fc5.y, ft4.z\n' +
    'sub ft5.z, fc6.w, ft5.y\n' +
    'mov ft5.w, fc5.w\n' +
    'mul ft6.xyz, fc6.xyz, ft5.zzz\n' +
    'mul ft7.xyz, ft2.xyz, ft5.yyy\n' +
    'add ft6.xyz, ft6.xyz, ft7.xyz\n' +
    'mul ft4.xyz, ft2.xyz, ft5.zzz\n' +
    'mul ft7.x, ft5.x, ft5.x\n' +
    'mul ft7.y, ft7.x, ft7.x\n' +
    'mul ft7.z, ft3.z, ft3.z\n' +
    'sub ft7.w, ft7.y, fc6.w\n' +
    'mul ft7.z, ft7.z, ft7.w\n' +
    'add ft7.z, ft7.z, fc6.w\n' +
    'mul ft7.z, ft7.z, ft7.z\n' +
    'mul ft8.x, fc5.w, ft7.y\n' +
    'div ft8.x, ft8.x, ft7.z\n' +
    'sub ft7.z, fc6.w, ft7.y\n' +
    'mul ft7.w, ft3.y, ft3.y\n' +
    'mul ft7.z, ft7.z, ft7.w\n' +
    'add ft7.z, ft7.z, ft7.y\n' +
    'sqt ft7.z, ft7.z\n' +
    'mul ft7.z, ft3.x, ft7.z\n' +
    'sub ft7.w, fc6.w, ft7.y\n' +
    'mul ft7.x, ft3.x, ft3.x\n' +
    'mul ft7.w, ft7.w, ft7.x\n' +
    'add ft7.w, ft7.w, ft7.y\n' +
    'sqt ft7.w, ft7.w\n' +
    'mul ft7.w, ft3.y, ft7.w\n' +
    'add ft7.z, ft7.z, ft7.w\n' +
    'max ft7.z, ft7.z, fc0.wwww\n' +
    'rcp ft7.z, ft7.z\n' +
    'mul ft7.z, ft7.z, fc1.wwww\n' +
    'mul ft4.w, ft7.z, ft8.x\n' +
    'mul ft7.xyz, ft4.xyz, fc5.wwww\n' +
    'sub ft8.y, fc6.w, ft3.w\n' +
    'mul ft8.z, ft8.y, ft8.y\n' +
    'mul ft8.z, ft8.z, ft8.z\n' +
    'mul ft8.z, ft8.z, ft8.y\n' +
    'sub ft8.w, fc6.w, ft8.z\n' +
    'mul ft8.w, fc6.x, ft8.w\n' +
    'add ft8.w, ft8.w, ft8.z\n' +
    'sub ft8.w, fc6.w, ft8.w\n' +
    'mul ft8.w, ft8.w, ft3.x\n' +
    'mul ft8.xyz, ft8.wwww, fc2.xyz\n' +
    'mul ft8.xyz, ft8.xyz, ft10.yyyy\n' +
    'mul ft8.xyz, ft8.xyz, ft7.xyz\n' +
    'mov ft4.xyz, ft8.xyz\n' +
    'sub ft7.w, fc6.w, ft3.w\n' +
    'mul ft8.y, ft7.w, ft7.w\n' +
    'mul ft8.y, ft8.y, ft8.y\n' +
    'mul ft8.y, ft8.y, ft7.w\n' +
    'sub ft8.z, fc6.w, ft8.y\n' +
    'mul ft7.xyz, ft6.xyz, ft8.zzz\n' +
    'add ft7.xyz, ft7.xyz, ft8.yyy\n' +
    'mul ft7.xyz, ft7.xyz, ft4.wwww\n' +
    'mul ft7.xyz, ft7.xyz, ft3.xxxx\n' +
    'mul ft7.xyz, ft7.xyz, fc2.xyz\n' +
    'mul ft7.xyz, ft7.xyz, ft10.yyyy\n' +
    'add ft4.xyz, ft4.xyz, ft7.xyz\n' +
    'sat ft4.xyz, ft4.xyz\n' +
    'pow ft4.x, ft4.x, fc3.w\n' +
    'pow ft4.y, ft4.y, fc3.w\n' +
    'pow ft4.z, ft4.z, fc3.w\n' +
    // AIR #3701: `oc` is written whole, once (a masked .xyz write plus a
    // separate .w write is refused at upload).
    'mov ft4.w, fc6.w\n' +
    'mov oc, ft4\n';

var asm:AGALMiniAssembler = new AGALMiniAssembler();
var code:ByteArray = asm.assemble(Context3DProgramType.FRAGMENT, pointFrag, 2);
check("point fragment assembles clean", asm.error == "");
trace("point fragment instructions: " + (code.length / 24));
check("point fragment < 200 instrs", (code.length / 24) < 200);

asm = new AGALMiniAssembler();
code = asm.assemble(Context3DProgramType.FRAGMENT, spotFrag, 2);
check("spot fragment assembles clean", asm.error == "");
trace("spot fragment instructions: " + (code.length / 24));
check("spot fragment < 200 instrs", (code.length / 24) < 200);

// ---------------------------------------------------------------------------
// E. The AIR-only operand shapes the assembler has to repair.
//
// AIR rejects both of these at upload with #3625, and as-aot's translator
// accepts them -- so the assembler is the one place that keeps a single bytecode
// stream valid for BOTH runtimes (AGALMiniAssembler.hoistConstantOperands).
// ---------------------------------------------------------------------------
var hops:AGALMiniAssembler = new AGALMiniAssembler();
var hop:ByteArray = hops.assemble(Context3DProgramType.FRAGMENT,
    'mov ft0, fc0\n' +                 // 1
    'mul ft1.xy, fc24.xy, fc27.xy\n' + // 2: two constants -> hoisted
    'mul ft1.zw, fc24.xy, fc28.xy\n' + // 3: SAME first constant -> reuse the temp
    'mov oc, ft0\n', 2);               // 4
check("two-constant sources assemble", hops.error == "");
check("the constant is hoisted ONCE and reused (4 src -> 5 instrs, got "
      + (hop.length - 7) / 24 + ")", (hop.length - 7) / 24 == 5);

hops = new AGALMiniAssembler();
hop = hops.assemble(Context3DProgramType.FRAGMENT,
    'mov ft0, fc0\n' +
    'rcp ft1.x, fc4.x\n' +             // single-source math on a constant
    'mov oc, ft0\n', 2);
check("a single-source rcp on a constant assembles", hops.error == "");
check("it costs one extra move (3 src -> 4 instrs, got "
      + (hop.length - 7) / 24 + ")", (hop.length - 7) / 24 == 4);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));
