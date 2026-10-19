// Portable part of the GPU compute grade (Vulkan GLSL and Direct3D 11 HLSL), written in the macro dialect of the Metal
// kernels (Sources/MpvfxMetal/Shaders/MpvfxColor.metal): float2/float3/float4, V2/V3/V4, FLOOR/FMAX/... The generator
// (gen-compute-shaders.py) splices three sections of this file around the Metal shading body.
//
// Every "texture" is a storage buffer: RGBA8 pictures as one packed uint per texel (byte 0 = red), the Kuwahara
// moments and the 1D/3D tables as float4 per texel. hdr[] carries the sizes: hdr[0..1] the output, hdr[2 + 2s] and
// hdr[3 + 2s] the input in slot s (0..3 pictures, 4 the moments).

// BEGIN MATH
// sin and cos within about one ulp of the CPU's sinf/cosf for every argument the shader produces (the hash noise
// feeds sin() arguments in the tens of millions, where a GPU's native sin is off by more than the hash tolerates):
// Cody-Waite reduction by pi/2 carried in two floats (exact Dekker products for the leading terms), then Taylor
// polynomials on [-pi/4, pi/4] with the final sum compensated. Measured against glibc on the grain-hash arguments:
// 97% identical, the rest one ulp. Needs IEEE arithmetic without contraction; the build decorates every float
// operation NoContraction (SPIR-V) or compiles with IEEE strictness (D3D).
inline float2 twoProd(float a, float b) {
    float p = a * b;
    float ta = 4097.0f * a, tb = 4097.0f * b;
    float ah = ta - (ta - a), bh = tb - (tb - b);
    float al = a - ah, bl = b - bh;
    float e = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
    return V2(p, e);
}
inline float2 twoSum(float a, float b) {
    float s = a + b;
    float bb = s - a;
    return V2(s, (a - (s - bb)) + (b - bb));
}
inline float quarterMod(float k) { return k - 4.0f * FLOOR(k * 0.25f); }
// (r_hi, r_lo, quadrant): x = r_hi + r_lo + quadrant * pi/2 (mod 2 pi), |r| <= pi/4 (+ rounding).
inline float3 reduceHalfPi(float x) {
    float k = FLOOR(x * TWO_OVER_PI + 0.5f);
    float2 a = twoProd(k, PIO2_1), b = twoProd(k, PIO2_2);
    float r0 = x - a.x;
    float2 s1 = twoSum(r0, -a.y);
    float2 s2 = twoSum(s1.x, -b.x);
    float lo = ((s1.y + s2.y) - b.y) - k * PIO2_3;
    float2 r = twoSum(s2.x, lo);
    // A second, small step when x * 2/pi rounded to the wrong integer (arguments past 2^24).
    float k2 = FLOOR(r.x * TWO_OVER_PI + 0.5f);
    float2 p = twoProd(k2, PIO2_1);
    float2 t = twoSum(r.x, -p.x);
    float2 rr = twoSum(t.x, t.y + (((r.y - p.y) - k2 * PIO2_2) - k2 * PIO2_3));
    return V3(rr.x, rr.y, quarterMod(quarterMod(k) + k2));
}
inline float sinReduced(float rh, float rl) {
    float z = rh * rh;
    float t = rh * z * (SIN_C3 + z * (SIN_C5 + z * (SIN_C7 + z * (SIN_C9 + z * SIN_C11))));
    float2 s = twoSum(rh, t);
    return s.x + (s.y + rl);
}
inline float cosReduced(float rh, float rl) {
    float2 p = twoProd(rh, rh);
    float z = p.x, zl = p.y + 2.0f * rh * rl;
    float2 s = twoSum(1.0f, -0.5f * z);
    float tail = z * z * (COS_C4 + z * (COS_C6 + z * (COS_C8 + z * (COS_C10 + z * COS_C12))));
    return s.x + ((s.y - 0.5f * zl) + tail);
}
inline float quadrantSin(float3 r) {
    float q = r.z;
    if (q < 0.5f) { return sinReduced(r.x, r.y); }
    if (q < 1.5f) { return cosReduced(r.x, r.y); }
    if (q < 2.5f) { return -sinReduced(r.x, r.y); }
    return -cosReduced(r.x, r.y);
}
inline float preciseSin(float x) { return quadrantSin(reduceHalfPi(x)); }
inline float preciseCos(float x) { float3 r = reduceHalfPi(x); return quadrantSin(V3(r.x, r.y, quarterMod(r.z + 1.0f))); }
inline float roundHalfAway(float x) {
    float a = FABS(x), f = FLOOR(a);
    float r = a - f >= 0.5f ? f + 1.0f : f;
    return x < 0.0f ? -r : r;
}
inline float4 roundHalfAway4(float4 v) { return V4(roundHalfAway(v.x), roundHalfAway(v.y), roundHalfAway(v.z), roundHalfAway(v.w)); }
// END MATH

// BEGIN TEXTURES
inline int slotWidth(int t) { return int(hdr[2 + 2 * t]); }
inline int slotHeight(int t) { return int(hdr[3 + 2 * t]); }
inline float4 unpackPx(uint v) {
    return V4(unorm8[int(v & 255u)], unorm8[int((v >> 8u) & 255u)], unorm8[int((v >> 16u) & 255u)], unorm8[int((v >> 24u) & 255u)]);
}
inline float4 fetchT(int t, int x, int y, bool flip) {
    int w = slotWidth(t), h = slotHeight(t);
    int cx = clampi(x, 0, w - 1), cy = clampi(y, 0, h - 1);
    return unpackPx(pxRead(t, (flip ? h - 1 - cy : cy) * w + cx));
}
inline float4 sampleT(int t, float2 uv, bool flip) {
    float tx = uv.x * float(slotWidth(t)) - 0.5f, ty = uv.y * float(slotHeight(t)) - 0.5f;
    float x0f = FLOOR(tx), y0f = FLOOR(ty);
    float fx = tx - x0f, fy = ty - y0f;
    int x0 = int(x0f), y0 = int(y0f);
    float4 a = fetchT(t, x0, y0, flip), b = fetchT(t, x0 + 1, y0, flip), c = fetchT(t, x0, y0 + 1, flip), d = fetchT(t, x0 + 1, y0 + 1, flip);
    float4 top = a + (b - a) * fx, bottom = c + (d - c) * fx;
    return top + (bottom - top) * fy;
}
// The Kuwahara moments (slot 4), nearest texel.
inline float4 nearestMoments(float2 uv) {
    int w = slotWidth(4), h = slotHeight(4);
    int x = clampi(int(FLOOR(uv.x * float(w))), 0, w - 1), y = clampi(int(FLOOR(uv.y * float(h))), 0, h - 1);
    return momRead(y * w + x);
}
inline float3 lutRead3(int t, int r, int g, int b) {
    int n = int(u[GU_lutSize]);
    return lutRead((b * n + g) * n + r).xyz;
}
inline uint packQ(float4 c) {
    float4 q = roundHalfAway4(clamp4(c) * 255.0f);
    return uint(q.x) | (uint(q.y) << 8u) | (uint(q.z) << 16u) | (uint(q.w) << 24u);
}
// END TEXTURES

// BEGIN KERNELS
constant float blurWeights[13] = {0.08077993f, 0.07918038f, 0.07456928f, 0.06747307f, 0.05865827f, 0.04899551f, 0.03931982f, 0.03031761f,
                                  0.02245983f, 0.01598624f, 0.01093238f, 0.00718308f, 0.00453456f};
constant float bloomWeights[5] = {0.227027f, 0.1945946f, 0.1216216f, 0.054054f, 0.016216f};

inline float4 blurRead(float2 uv, bool flip, bool bloomPass, float threshold) {
    float4 c = sampleT(0, clampUv(uv), flip);
    if (bloomPass) {
        float lum = c.x * 0.299f + c.y * 0.587f + c.z * 0.114f;
        if (threshold >= 0.0f && lum <= threshold) { c = V4(0.0f, 0.0f, 0.0f, c.w); }
        return V4(c.x, c.y, c.z, 1.0f);
    }
    return V4(c.x * c.w, c.y * c.w, c.z * c.w, c.w);
}

// u: MpvfxBlurParam (direction, radius, bloom pass 0/1, threshold < 0 for none, source image-oriented 0/1).
// Input slot 0, output packed in GL orientation.
void kernelBlur(int2 gid) {
    int width = int(hdr[0]), height = int(hdr[1]);
    if (gid.x >= width || gid.y >= height) { return; }
    bool bloomPass = u[BLUR_BLOOM_PASS] > 0.5f, flip = u[BLUR_SOURCE_FLIPPED] > 0.5f;
    float threshold = u[BLUR_THRESHOLD];
    float2 res = V2(float(width), float(height));
    float r = FMAX(u[BLUR_RADIUS], 0.0f);
    float2 stepUv = V2(u[BLUR_DIR_X] * r / FMAX(res.x, 1.0f), u[BLUR_DIR_Y] * r / FMAX(res.y, 1.0f)) * (bloomPass ? 0.5f : 1.0f / 12.0f);
    float2 vuv = V2((float(gid.x) + 0.5f) / res.x, (float(gid.y) + 0.5f) / res.y);
    int n = bloomPass ? 5 : 13;
    float4 c = blurRead(vuv, flip, bloomPass, threshold) * (bloomPass ? bloomWeights[0] : blurWeights[0]);
    for (int k = 1; k < n; k++) {
        float w = bloomPass ? bloomWeights[k] : blurWeights[k];
        c += blurRead(vuv + stepUv * float(k), flip, bloomPass, threshold) * w;
        c += blurRead(vuv - stepUv * float(k), flip, bloomPass, threshold) * w;
    }
    if (!bloomPass && c.w > 0.0001f) { c = V4(c.x / c.w, c.y / c.w, c.z / c.w, c.w); }
    outPxWrite(gid.y * width + gid.x, packQ(c));
}

// u: MpvfxMomentsParam. Horizontal moments: mean colour and mean squared magnitude / 3 over x..x+radius.
// Source in slot 0 (image-oriented), the blur in slot 1.
void kernelMoments(int2 gid) {
    int w = int(hdr[0]), h = int(hdr[1]);
    if (gid.x >= w || gid.y >= h) { return; }
    int radius = int(u[MOMENTS_RADIUS]);
    float blurAmount = u[MOMENTS_BLUR_AMOUNT];
    float2 texel = V2(1.0f / float(w), 1.0f / float(h));
    float3 sum = V3S(0.0f);
    float sq = 0.0f;
    for (int o = 0; o <= radius; o++) {
        float2 uv = V2((float(gid.x) + 0.5f) / float(w) + float(o) * texel.x, (float(gid.y) + 0.5f) / float(h));
        float4 c = sampleT(0, clampUv(uv), true);
        if (blurAmount > 0.0f) { c = c + (sampleT(1, clampUv(uv), false) - c) * blurAmount; }
        float3 rgb = c.xyz;
        sum += rgb; sq += dot3(rgb, rgb) / 3.0f;
    }
    float n = float(radius + 1);
    outMomWrite(gid.y * w + gid.x, V4(sum.x / n, sum.y / n, sum.z / n, sq / n));
}

// u: MpvfxResolveParam. Moments in slot 4.
void kernelResolve(int2 gid) {
    int w = int(hdr[0]), h = int(hdr[1]);
    if (gid.x >= w || gid.y >= h) { return; }
    int radius = int(u[RESOLVE_RADIUS]);
    float exponent = u[RESOLVE_EXPONENT], satAmount = u[RESOLVE_SATURATION];
    float2 texel = V2(1.0f / float(w), 1.0f / float(h));
    float2 vuv = V2((float(gid.x) + 0.5f) / float(w), (float(gid.y) + 0.5f) / float(h));
    float rr = float(radius);
    float3 means[4];
    float variances[4];
    float minVariance = 1.0f;
    for (int q = 0; q < 4; q++) {
        float2 origin = V2(q == 0 || q == 2 ? -rr : 0.0f, q < 2 ? -rr : 0.0f);
        float4 moment = V4(0.0f, 0.0f, 0.0f, 0.0f);
        for (int o = 0; o <= radius; o++) {
            float2 off = origin + V2(0.0f, float(o));
            moment += nearestMoments(clampUv(vuv + off * texel));
        }
        moment /= float(radius + 1);
        float3 mean = moment.xyz;
        float variance = FMAX(moment.w * 3.0f - dot3(mean, mean), 0.0f);
        means[q] = mean; variances[q] = variance;
        minVariance = FMIN(minVariance, variance);
    }
    float3 result = V3S(0.0f);
    float total = 0.0f;
    for (int q = 0; q < 4; q++) {
        float weight = POW((minVariance + 0.0001f) / (variances[q] + 0.0001f), exponent);
        result += means[q] * weight; total += weight;
    }
    result /= FMAX(total, 0.0001f);
    float l = lumaOf(result);
    float3 c = clamp3(mix3(V3S(l), result, satAmount), 0.0f, 1.0f);
    outPxWrite(gid.y * w + gid.x, packQ(V43(c, 1.0f)));
}

// The grade: GL frag row gid.y is written to image row height - 1 - gid.y. Slots: 0 source (image-oriented),
// 1 blur, 2 Kuwahara, 3 bloom; tables 5 curves, 6 hue curves, 7 secondaries, 8 LUT.
void kernelGrade(int2 gid) {
    int w = int(hdr[0]), h = int(hdr[1]);
    if (gid.x >= w || gid.y >= h) { return; }
    int src = 0, blurT = 1, kuwT = 2, bloomT = 3, curvesT = 5, hueT = 6, secT = 7, lutT = 8, uArg_ = 0;
    float4 c = shade(V2(float(gid.x) + 0.5f, float(gid.y) + 0.5f), A_ALL);
    outPxWrite((h - 1 - gid.y) * w + gid.x, packQ(c));
}
// END KERNELS

// BEGIN OVERRIDES
// Loop forms of the Metal body's five heaviest call sites. Direct3D's compiler (and glslang's HLSL front end) inline
// every call, so each sampleMedia / samplePrepared call site is a full copy of the sampling code: written as loops
// ([loop] in HLSL) the grade kernel is about ten times smaller. Every value is computed by the same operations in the
// same order as the Metal function it replaces. The generator replaces a function only while the Metal text still
// has the hash recorded on its OVERRIDE line; a changed Metal function stops the build until this copy is updated.

// OVERRIDE sampleMedia metal-sha256=76f4da28a0250a98
float4 sampleMedia(float2 uv, float2 frag, P_ALL) {
    float pixelate = clampf(E(pixelate), 0.0f, 1.0f), tapeDamage = clampf(E(tapeDamage), 0.0f, 1.0f);
    float tapeTracking = clampf(E(tapeTracking), 0.0f, 1.0f), tapeNoise = clampf(E(tapeNoise), 0.0f, 1.0f);
    float tapeSpeed = clampf(E(tapeSpeed), 0.0f, 1.0f), chromaBleed = clampf(E(chromaBleed), 0.0f, 1.0f);
    float2 res = V2(U(resX), U(resY));
    float2 sampleUv = uv;
    if (pixelate > 0.0f) {
        float blockSize = mixf(1.0f, 48.0f, pixelate);
        float2 cells = V2(FMAX(res.x / blockSize, 1.0f), FMAX(res.y / blockSize, 1.0f));
        float2 c = V2(clampf(uv.x, 0.0f, 0.999999f), clampf(uv.y, 0.0f, 0.999999f));
        sampleUv = V2((FLOOR(c.x * cells.x) + 0.5f) / cells.x, (FLOOR(c.y * cells.y) + 0.5f) / cells.y);
    }
    float texelX = 1.0f / FMAX(res.x, 1.0f);
    if (tapeDamage <= 0.0f && chromaBleed <= 0.0f) { return samplePrepared(sampleUv, A_ALL); }
    float tapeTime = U(effectTime) * mixf(0.0f, 2.0f, tapeSpeed);
    float tapeFrame = FLOOR(tapeTime * 60.0f);
    float tapeLine = FLOOR(sampleUv.y * res.y * 0.5f);
    float2 tapeUv = sampleUv;
    if (tapeDamage > 0.0f) {
        float lineJitter = (digitalHash(V2(tapeLine, FLOOR(tapeFrame * 0.5f))) - 0.5f) * 1.8f * tapeNoise;
        float slowWobble = SIN(sampleUv.y * 32.0f + tapeTime * 2.6f) * 0.55f;
        float headSwitch = smoothstepf(0.88f, 1.0f, sampleUv.y) * SIN(sampleUv.y * 240.0f + tapeTime * 8.0f) * 4.0f;
        float trackingShift = tapeTrackingBand(sampleUv.y, fractf(0.08f + tapeTime * 0.083f), 0.035f);
        trackingShift -= tapeTrackingBand(sampleUv.y, fractf(0.28f + tapeTime * 0.061f), 0.03f) * 0.8f;
        trackingShift += tapeTrackingBand(sampleUv.y, fractf(0.5f + tapeTime * 0.047f), 0.04f) * 0.75f;
        trackingShift -= tapeTrackingBand(sampleUv.y, fractf(0.72f + tapeTime * 0.037f), 0.028f) * 0.65f;
        trackingShift += tapeTrackingBand(sampleUv.y, fractf(0.89f + tapeTime * 0.029f), 0.032f) * 0.55f;
        trackingShift *= tapeTracking * 48.0f;
        float tapeShift = (lineJitter + slowWobble + headSwitch + trackingShift) * tapeDamage;
        tapeUv = sampleUv + V2(tapeShift * texelX, 0.0f);
    }
    float4 base = samplePrepared(tapeUv, A_ALL);
    if (tapeDamage > 0.0f) {
        float2 lumaStep = V2(texelX * mixf(1.0f, 3.5f, tapeDamage), 0.0f);
        // left, right, ghost
        float4 taps[3];
        LOOP for (int i = 0; i < 3; i++) {
            float2 at = i == 0 ? tapeUv - lumaStep : (i == 1 ? tapeUv + lumaStep : tapeUv - V2(texelX * 12.0f, 0.0f));
            taps[i] = samplePrepared(at, A_ALL);
        }
        float4 left = taps[0], right = taps[1];
        float3 b3 = base.xyz;
        float tapeLuma = (bt601Luma(left.xyz) + bt601Luma(b3) * 2.0f + bt601Luma(right.xyz)) * 0.25f;
        float3 centerChroma = b3 - V3S(bt601Luma(b3));
        float3 tapeColor = V3S(tapeLuma) + centerChroma;
        float4 ghost = taps[2];
        tapeColor = mix3(tapeColor, ghost.xyz, 0.045f * tapeDamage);
        float fineNoise = digitalHash(V2(FLOOR(frag.x), FLOOR(frag.y)) + V2(tapeFrame * 17.0f, tapeFrame * 3.0f)) - 0.5f;
        float band = digitalHash(V2(FLOOR(sampleUv.y * 92.0f), FLOOR(tapeFrame / 3.0f)));
        float dropout = smoothstepf(0.985f, 1.0f, band) * (digitalHash(V2(FLOOR(sampleUv.x * 18.0f), tapeLine)) - 0.5f);
        tapeColor += V3S((fineNoise * 0.035f + dropout * 0.12f) * tapeDamage * tapeNoise);
        float3 m = mix3(b3, clamp3(tapeColor, 0.0f, 1.0f), tapeDamage);
        base = V43(m, base.w);
    }
    if (chromaBleed > 0.0f) {
        float radius = mixf(1.0f, 4.0f, chromaBleed);
        float2 stepUv = V2(texelX * radius, 0.0f);
        float3 c0 = base.xyz;
        // c1 .. c4: one and two steps left and right
        float3 cs[4];
        LOOP for (int i = 0; i < 4; i++) {
            float2 at = i == 0 ? tapeUv - stepUv : (i == 1 ? tapeUv + stepUv : (i == 2 ? tapeUv - stepUv * 2.0f : tapeUv + stepUv * 2.0f));
            cs[i] = samplePrepared(at, A_ALL).xyz;
        }
        float3 c1 = cs[0], c2 = cs[1], c3 = cs[2], c4 = cs[3];
        float centerLuma = lumaOf(c0);
        float3 blurred = ((c0 - V3S(lumaOf(c0))) * 6.0f + (c1 - V3S(lumaOf(c1))) * 4.0f + (c2 - V3S(lumaOf(c2))) * 4.0f
                          + (c3 - V3S(lumaOf(c3))) + (c4 - V3S(lumaOf(c4)))) / 16.0f;
        float3 m = mix3(c0, clamp3(V3S(centerLuma) + blurred, 0.0f, 1.0f), chromaBleed);
        base = V43(m, base.w);
    }
    return base;
}
// END OVERRIDE

// OVERRIDE sampleChromaticMedia metal-sha256=ab3db8f52174497c
float4 sampleChromaticMedia(float2 uv, float4 center, float2 frag, P_ALL) {
    float chromaticAberration = clampf(E(chromaticAberration), 0.0f, 1.0f);
    if (!(chromaticAberration > 0.0f)) { return center; }
    float angle = clampf(E(chromaticAngle), 0.0f, 1.0f) * PI * 2.0f;
    float2 offset = V2(COS(angle), SIN(angle)) * chromaticAberration * 0.02f;
    // positive, negative
    float4 s[2];
    LOOP for (int i = 0; i < 2; i++) { s[i] = sampleMedia(i == 0 ? uv + offset : uv - offset, frag, A_ALL); }
    return V4(s[0].x, center.y, s[1].z, center.w);
}
// END OVERRIDE

// OVERRIDE sampleDigitalSplit metal-sha256=d10653348720ac1f
float3 sampleDigitalSplit(float2 uv, float2 block, float time, float amount, float2 frag, P_ALL) {
    float split = amount * 0.06f;
    float direction = digitalHash(block * 0.4f + V2(FLOOR(time * 3.7f), FLOOR(time * 5.3f)));
    float2 axis = direction > 0.66f ? V2(1.0f, 0.0f) : (direction > 0.33f ? V2(0.0f, 1.0f) : V2(0.7071f, 0.7071f));
    // center, along the axis, against it
    float4 s[3];
    LOOP for (int i = 0; i < 3; i++) { s[i] = sampleMedia(i == 0 ? uv : (i == 1 ? uv + axis * split : uv - axis * split), frag, A_ALL); }
    return V3(s[1].x, s[0].y, s[2].z);
}
// END OVERRIDE

// OVERRIDE crosshatchEdge metal-sha256=32c24fe4aa05765c
float crosshatchEdge(float2 uv, float2 frag, P_ALL) {
    float2 texel = V2(1.0f / FMAX(U(resX), 1.0f), 1.0f / FMAX(U(resY), 1.0f));
    // tl, tc, tr, ml, mr, bl, bc, br
    float l[8];
    LOOP for (int i = 0; i < 8; i++) {
        int k = i < 4 ? i : i + 1;
        float2 d = V2(float(k - 3 * (k / 3)) - 1.0f, float(k / 3) - 1.0f);
        l[i] = lumaOf(sampleMedia(uv + texel * d, frag, A_ALL).xyz);
    }
    float tl = l[0], tc = l[1], tr = l[2], ml = l[3], mr = l[4], bl = l[5], bc = l[6], br = l[7];
    float gx = -tl - 2.0f * ml - bl + tr + 2.0f * mr + br;
    float gy = -tl - 2.0f * tc - tr + bl + 2.0f * bc + br;
    return SQRT(gx * gx + gy * gy);
}
// END OVERRIDE

// OVERRIDE asciiEdgeDirection metal-sha256=b30a05af1877bfa9
float2 asciiEdgeDirection(float2 uv, float2 stepUv, float2 frag, P_ALL) {
    // tl, t, tr, le, r, bl, b, br
    float l[8];
    LOOP for (int i = 0; i < 8; i++) {
        int k = i < 4 ? i : i + 1;
        float dx = float(k - 3 * (k / 3)) - 1.0f, dy = float(k / 3) - 1.0f;
        l[i] = bt601Luma(sampleMedia(uv + V2(dx * stepUv.x, dy * stepUv.y), frag, A_ALL).xyz);
    }
    float tl = l[0], t = l[1], tr = l[2], le = l[3], r = l[4], bl = l[5], b = l[6], br = l[7];
    return V2(-tl - 2.0f * le - bl + tr + 2.0f * r + br, -tl - 2.0f * t - tr + bl + 2.0f * b + br);
}
// END OVERRIDE
// END OVERRIDES
