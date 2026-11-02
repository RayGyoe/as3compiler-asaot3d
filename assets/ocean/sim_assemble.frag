#version 300 es
// sim_assemble.frag -- from the transformed gradients to the two textures the surface
// reads. displacement = (lambda*Dx, Dy, lambda*Dz, turbulence) and
// slope = (sx, sz, sx*sx, sz*sz); the slopes are divided out at full resolution so their
// mips give mean and second moment (that is what a LEAN-style roughness needs).
//
// turbulence is the Jacobian feedback term that makes foam follow a folding crest down
// instantly and recover at a fixed rate: it needs the previous frame, so the pair of
// targets ping-pongs and all four cascades share the parity.
uniform highp sampler2D uIn0;
uniform highp sampler2D uIn1;
uniform sampler2D uPrev;
uniform float uLambda;
uniform float uDt;
uniform float uFoamRecovery;
layout(location = 0) out vec4 outDisp;
layout(location = 1) out vec4 outSlope;

void main() {
  ivec2 id = ivec2(gl_FragCoord.xy);
  ivec2 p = id;
  // undo the centred-k frequency shift: a roll by N/2 multiplies the field by (-1)^(x+y)
  float s = ((id.x + id.y) & 1) == 0 ? 1.0 : -1.0;
  vec4 a = texelFetch(uIn0, p, 0) * s;   // Dx, Dz, Dy, Dxz
  vec4 b = texelFetch(uIn1, p, 0) * s;   // Dyx, Dyz, Dxx, Dzz
  float dxx = uLambda * b.z, dzz = uLambda * b.w, dxz = uLambda * a.w;
  float jac = (1.0 + dxx) * (1.0 + dzz) - dxz * dxz;
  // the geometric slope of a choppy surface: horizontal displacement compresses the grid,
  // so the visible slope is the height gradient divided by the local Jacobian
  vec2 slope = b.xy / max(vec2(1.0 + dxx, 1.0 + dzz), vec2(0.2));
  float prev = texelFetch(uPrev, id, 0).w;
  float turb = min(jac, prev + uDt * uFoamRecovery / max(jac, 0.5));
  outDisp = vec4(uLambda * a.x, a.z, uLambda * a.y, turb);
  outSlope = vec4(slope, slope * slope);
}