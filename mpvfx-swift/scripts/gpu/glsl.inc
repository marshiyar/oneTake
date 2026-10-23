// Vulkan GLSL prelude of the compute grade: the Metal dialect's types and math macros, the storage buffers (set 0)
// and the slot accessors portable.inc reads through. Bindings: 0 hdr, 1 u, 2..5 packed RGBA8 slots 0..3, 6 moments
// in, 7 curves, 8 hue curves, 9 secondaries, 10 LUT, 11 packed output, 12 moments output, 13 the 8-bit unorm table, 14 Sat/Sat
// (k / 255 for every byte, correctly rounded: the CPU reference's Float(k) / 255, whatever the device's division).
#version 450
#define float2 vec2
#define float3 vec3
#define float4 vec4
#define int2 ivec2
#define inline
#define FLOOR(x) floor(x)
#define CEIL(x) ceil(x)
#define FABS(x) abs(x)
#define FMAX(a, b) max(a, b)
#define FMIN(a, b) min(a, b)
#define SQRT(x) sqrt(x)
#define POW(x, y) pow(x, y)
#define ATAN2(y, x) atan(y, x)
#define SIN(x) preciseSin(x)
#define COS(x) preciseCos(x)
#define ROUND(x) roundHalfAway4(x)
#define LOOP
layout(local_size_x = 16, local_size_y = 8, local_size_z = 1) in;
layout(std430, set = 0, binding = 0) readonly buffer Hdr { float hdr[]; };
layout(std430, set = 0, binding = 1) readonly buffer Uni { float u[]; };
layout(std430, set = 0, binding = 2) readonly buffer In0 { uint in0[]; };
layout(std430, set = 0, binding = 3) readonly buffer In1 { uint in1[]; };
layout(std430, set = 0, binding = 4) readonly buffer In2 { uint in2[]; };
layout(std430, set = 0, binding = 5) readonly buffer In3 { uint in3[]; };
layout(std430, set = 0, binding = 6) readonly buffer MomIn { vec4 momIn[]; };
layout(std430, set = 0, binding = 7) readonly buffer CurvesTab { vec4 curvesTab[]; };
layout(std430, set = 0, binding = 8) readonly buffer HueTab { vec4 hueTab[]; };
layout(std430, set = 0, binding = 14) readonly buffer SaturationTab { vec4 saturationTab[]; };
layout(std430, set = 0, binding = 9) readonly buffer SecTab { vec4 secTab[]; };
layout(std430, set = 0, binding = 10) readonly buffer LutTab { vec4 lutTab[]; };
layout(std430, set = 0, binding = 11) writeonly buffer OutPx { uint outPx[]; };
layout(std430, set = 0, binding = 12) writeonly buffer OutMom { vec4 outMom[]; };
layout(std430, set = 0, binding = 13) readonly buffer Unorm8 { float unorm8[]; };
vec2 V2(float a, float b) { return vec2(a, b); }
vec3 V3(float a, float b, float c) { return vec3(a, b, c); }
vec3 V3S(float a) { return vec3(a, a, a); }
vec4 V4(float a, float b, float c, float d) { return vec4(a, b, c, d); }
vec4 V43(vec3 a, float d) { return vec4(a, d); }
uint pxRead(int t, int i) {
    if (t == 0) { return in0[i]; }
    if (t == 1) { return in1[i]; }
    if (t == 2) { return in2[i]; }
    return in3[i];
}
vec4 momRead(int i) { return momIn[i]; }
vec4 tex1Read(int t, int i) {
    if (t == 9) { return saturationTab[i]; }
    if (t == 5) { return curvesTab[i]; }
    if (t == 6) { return hueTab[i]; }
    return secTab[i];
}
vec4 lutRead(int i) { return lutTab[i]; }
void outPxWrite(int i, uint v) { outPx[i] = v; }
void outMomWrite(int i, vec4 v) { outMom[i] = v; }
