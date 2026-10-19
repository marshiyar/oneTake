// Direct3D 11 HLSL (shader model 5.0) prelude of the compute grade: the Metal dialect's math macros, the buffers and
// the slot accessors portable.inc reads through. Registers: t0 hdr, t1 u, t2..t5 packed RGBA8 slots 0..3, t6 moments
// in, t7 curves, t8 hue curves, t9 secondaries, t10 LUT, t11 the 8-bit unorm table (k / 255, correctly rounded), u0
// packed output, u1 moments output. With MPVFX_VK defined
// (glslang's HLSL front end, used by the Linux tests to run this exact source on Vulkan) the same resources carry the
// Vulkan bindings of glsl.inc.
#ifdef MPVFX_VK
#define BIND(n) [[vk::binding(n, 0)]]
#else
#define BIND(n)
#endif
#define FLOOR(x) floor(x)
#define CEIL(x) ceil(x)
#define FABS(x) abs(x)
#define FMAX(a, b) max(a, b)
#define FMIN(a, b) min(a, b)
#define SQRT(x) sqrt(x)
#define POW(x, y) pow(x, y)
#define ATAN2(y, x) atan2(y, x)
#define SIN(x) preciseSin(x)
#define COS(x) preciseCos(x)
#define ROUND(x) roundHalfAway4(x)
#define LOOP [loop]
BIND(0) StructuredBuffer<float> hdr : register(t0);
BIND(1) StructuredBuffer<float> u : register(t1);
BIND(2) StructuredBuffer<uint> in0 : register(t2);
BIND(3) StructuredBuffer<uint> in1 : register(t3);
BIND(4) StructuredBuffer<uint> in2 : register(t4);
BIND(5) StructuredBuffer<uint> in3 : register(t5);
BIND(6) StructuredBuffer<float4> momIn : register(t6);
BIND(7) StructuredBuffer<float4> curvesTab : register(t7);
BIND(8) StructuredBuffer<float4> hueTab : register(t8);
BIND(9) StructuredBuffer<float4> secTab : register(t9);
BIND(10) StructuredBuffer<float4> lutTab : register(t10);
BIND(11) RWStructuredBuffer<uint> outPx : register(u0);
BIND(12) RWStructuredBuffer<float4> outMom : register(u1);
BIND(13) StructuredBuffer<float> unorm8 : register(t11);
float2 V2(float a, float b) { return float2(a, b); }
float3 V3(float a, float b, float c) { return float3(a, b, c); }
float3 V3S(float a) { return float3(a, a, a); }
float4 V4(float a, float b, float c, float d) { return float4(a, b, c, d); }
float4 V43(float3 a, float d) { return float4(a, d); }
uint pxRead(int t, int i) {
    if (t == 0) { return in0[i]; }
    if (t == 1) { return in1[i]; }
    if (t == 2) { return in2[i]; }
    return in3[i];
}
float4 momRead(int i) { return momIn[i]; }
float4 tex1Read(int t, int i) {
    if (t == 5) { return curvesTab[i]; }
    if (t == 6) { return hueTab[i]; }
    return secTab[i];
}
float4 lutRead(int i) { return lutTab[i]; }
void outPxWrite(int i, uint v) { outPx[i] = v; }
void outMomWrite(int i, float4 v) { outMom[i] = v; }
