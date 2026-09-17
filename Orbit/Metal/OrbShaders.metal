#include <metal_stdlib>
using namespace metal;

// Kept in sync (field order + packing) with `OrbUniforms` in OrbRenderer.swift.
// `color` is first so its 16-byte alignment doesn't insert padding.
struct OrbUniforms {
    float3 color;
    float2 resolution;
    float2 center;
    float  radius;
    float  time;
    float  energy;
    float  glow;
};

// --- value noise + fbm, cheap enough to run per-pixel every frame ---

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 3; i++) {   // 3 octaves — see the perf note for why
        v += amp * valueNoise(p);
        p *= 2.02;
        amp *= 0.5;
    }
    return v;
}

// Full-screen triangle; no vertex buffer needed.
vertex float4 orb_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 orb_fragment(float4 fragCoord [[position]],
                             constant OrbUniforms &u [[buffer(0)]]) {
    float2 px = fragCoord.xy;
    float2 d  = px - u.center;
    float dist = length(d);
    float r = u.radius;

    // Background: near-black with a very soft central lift, so the orb sits in
    // a pool of light rather than on a flat field.
    float bgLift = smoothstep(u.resolution.y, 0.0, length(px - u.resolution * 0.5));
    float3 col = mix(float3(0.015, 0.015, 0.02), float3(0.05, 0.05, 0.06), bgLift * 0.5);

    // Outer glow — an alpha falloff, additive. Swells with state glow + energy.
    float glow = exp(-max(dist - r, 0.0) / (r * 0.72));
    col += u.color * glow * u.glow * (0.55 + u.energy * 0.7) * 0.9;

    // Core sphere.
    if (dist < r + 2.0) {
        float2 n2 = d / r;                          // -1..1 across the disc
        float z = sqrt(max(0.0, 1.0 - dot(n2, n2)));
        float3 normal = float3(n2, z);
        float3 lightDir = normalize(float3(-0.45, -0.55, 0.75));
        float diff = clamp(dot(normal, lightDir), 0.0, 1.0);

        // Animated surface: fbm over the sphere's own coordinates, breathing
        // faster and deeper as the orb takes in more sound.
        float2 sp = n2 * 2.3 + float2(u.time * 0.12, -u.time * 0.09);
        float surf = fbm(sp);
        float surface = 0.78 + 0.5 * surf * (0.35 + u.energy);

        float3 base = u.color * surface;
        float3 lit  = base * (0.32 + 0.9 * diff);

        // Fresnel-ish rim and a small specular so it reads as a lit sphere.
        float rim  = pow(1.0 - z, 2.2);
        lit += u.color * rim * 0.55;
        float spec = pow(diff, 26.0);
        lit += float3(1.0) * spec * 0.5;

        float edge = smoothstep(r + 1.5, r - 1.5, dist);   // anti-aliased rim
        col = mix(col, lit, edge);
    }

    return float4(col, 1.0);
}
