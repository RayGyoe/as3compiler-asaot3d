#version 300 es
// sim_common.glsl -- constants and helpers the four FFT passes share. A faithful port
// of Ultra-Water src/water/OceanSim.js: N=256 per cascade, four cascades stacked in one
// 256x1024 atlas so every IFFT stage is a single draw.
precision highp float;
precision highp int;

#define N 256
#define PI 3.14159265359
#define G 9.81
#define ST 7.4e-5

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
// surface tension makes the dispersion relation non-linear in k: w^2 = g k + (sigma/rho) k^3
float omega(float k) { return sqrt(G * k + ST * k * k * k); }