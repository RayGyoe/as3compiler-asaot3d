#version 300 es
// spray.vert -- spindrift off the crests, drawn as camera-facing quads.
//
// There is no particle system here on purpose: each quad carries a FIXED emitter in xz
// and a phase in .zw, and the whole trajectory (launch height, arc, drift, fade) is a
// function of that phase. The CPU uploads the emitter table once, the vertex program
// decides which droplets are alive this frame by looking up the surface height at the
// emitter -- so a passing wave lights up a whole band of spray without a single buffer
// update. That is the same "the sea is a function, sample it" trick the rest of the
// pipeline uses.
layout(location = 0) in vec3 aPos;    // quad corner, -1..1
layout(location = 1) in vec4 aColor;  // emitter xz (box coords), seed, phase
uniform sampler2D uDisp0;
uniform sampler2D uDisp1;
uniform vec4 uLength;
uniform mat4 projectionMatrix;
uniform mat4 viewMatrix;
uniform vec4 uSpray;      // size (m), lifetime (s), launch speed (m/s), threshold (m)
uniform vec4 uSprayBox;   // origin xz, radius (m), rate (1/s)
uniform vec2 uWind;
uniform float uTime;
out vec2 vCorner;
out float vFade;

void main() {
  vec2 p0 = uSprayBox.xy + aColor.xy * uSprayBox.z;
  float ph = fract(uTime * uSprayBox.w + aColor.w);
  vec3 d = textureLod(uDisp0, p0 / uLength.x, 0.0).xyz
         + textureLod(uDisp1, p0 / uLength.y, 0.0).xyz;
  // only crests throw spray; the ramp keeps the population from popping on all at once
  float amp = smoothstep(uSpray.w, uSpray.w + 0.9, d.y);

  float t = ph * uSpray.y;
  vec3 w = vec3(p0.x + d.x, d.y, p0.y + d.z);
  w.y += uSpray.z * t - 4.9 * t * t;
  w.xz += uWind * (t * t * 1.2);

  float size = uSpray.x * (1.0 - ph * 0.7) * amp;
  // billboard from the view matrix's own axes (its rows are the camera's world axes)
  vec3 camRight = vec3(viewMatrix[0][0], viewMatrix[1][0], viewMatrix[2][0]);
  vec3 camUp    = vec3(viewMatrix[0][1], viewMatrix[1][1], viewMatrix[2][1]);
  w += camRight * aPos.x * size + camUp * aPos.y * size;

  vCorner = aPos.xy;
  vFade = amp * (1.0 - ph) * (1.0 - ph);
  gl_Position = projectionMatrix * viewMatrix * vec4(w, 1.0);
}