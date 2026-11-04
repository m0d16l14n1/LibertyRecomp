// Ray-traced ambient occlusion and its denoiser for the GTA IV Metal renderer.
//
// Kernels, in encode order (raytracing.mm):
//   rtao_trace      half resolution, 1 cosine-weighted ray per pixel against the
//                   frame's instance acceleration structure -> raw visibility + view depth
//   rtao_temporal   reprojects last frame's denoised AO with the title's motion
//                   texture; rejects by depth; keeps a per-pixel history length
//   rtao_atrous     edge-aware a-trous filter (depth + normal), run with step 1 and 2
//   rtao_upsample   depth-aware 2x2 upsample to input resolution
//   rtao_apply_*    full-screen pass over the lighting output: multiply, or show the AO
// Every texture is read with read()/write(): no samplers, no filtering surprises.
// RtaoParams must match raytracing/raytracing.h.
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

struct RtaoParams {
    float4x4 clipToWorld;        // world = clipToWorld * (ndc.xy, device depth, 1), unjittered
    float4x4 previousWorldToClip;// for history rejection by depth
    float4 cameraPosition;       // xyz world, w unused
    uint2 inputSize;             // G-buffer / depth size
    uint2 traceSize;             // AO size (half of input, rounded up)
    float radius;                // world units
    float strength;              // 0..1: how dark full occlusion gets
    float historyBlendMinimum;   // weight of the new sample once history is long
    float depthRejection;        // relative view-depth difference that drops history
    uint frame;
    uint normalMode;             // 0: from depth; 1: G-buffer rgb = n * 0.5 + 0.5 (world, Z up); 2: as 1 with x and y swapped
    uint reversedDepth;          // 1: device depth 1 is near
    uint validHistory;           // 0 after a camera cut or resize
    float2 jitterNdc;            // the depth was rendered with ndc + jitterNdc: removed before reconstruction
    float2 padding;
};

// ---- helpers -------------------------------------------------------------------------

static float2 ndc_of(uint2 pixel, uint2 size) {
    const float2 uv = (float2(pixel) + 0.5f) / float2(size);
    return float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
}

static bool is_sky(float depth, constant RtaoParams& p) {
    return p.reversedDepth ? depth <= 0.0f : depth >= 1.0f;
}

static float3 world_at(uint2 pixel, uint2 size, float depth, constant RtaoParams& p) {
    const float4 world = p.clipToWorld * float4(ndc_of(pixel, size) - p.jitterNdc, depth, 1.0f);
    return world.xyz / world.w;
}

// PCG hash: per-pixel, per-frame decorrelated numbers without a noise texture.
static uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
static float2 random2(uint2 pixel, uint frame) {
    const uint a = pcg(pixel.x + pcg(pixel.y + pcg(frame)));
    const uint b = pcg(a);
    // Cranley-Patterson rotation of the R2 sequence keeps samples well spread over frames.
    const float2 r2 = fract(float2(0.7548776662f, 0.5698402910f) * float(frame % 1024u));
    return fract(r2 + float2(a, b) * (1.0f / 4294967296.0f));
}

static float3 cosine_direction(float3 n, float2 u) {
    const float r = sqrt(u.x), phi = 2.0f * M_PI_F * u.y;
    const float3 t = normalize(abs(n.z) < 0.999f ? cross(n, float3(0, 0, 1)) : cross(n, float3(1, 0, 0)));
    const float3 b = cross(n, t);
    return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0f, 1.0f - u.x)));
}

// The scene depth attachment itself (single sample), read as a depth texture.
static float depth_at(texture2d<float, access::read> depth, uint2 pixel) {
    return depth.read(min(pixel, uint2(depth.get_width() - 1, depth.get_height() - 1))).r;
}

// GBufferTextureSampler1 (RGBA8, world normal * 0.5 + 0.5, Z up). mode 2 swaps x and y:
// the title fetches it as .yxzw, and which of the two is world x is checked by the stats.
static float3 gbuffer_normal(texture2d<float, access::read> gbufferNormal, uint2 pixel, uint mode) {
    const float3 n = gbufferNormal.read(min(pixel, uint2(gbufferNormal.get_width() - 1, gbufferNormal.get_height() - 1))).rgb
                     * 2.0f - 1.0f;
    return mode == 2u ? n.yxz : n;
}

// The surface normal at an input-resolution pixel, facing the camera.
static float3 normal_at(texture2d<float, access::read> depth, texture2d<float, access::read> gbufferNormal,
                        uint2 pixel, float3 position, constant RtaoParams& p, uint mode) {
    float3 n;
    if (mode != 0u) {
        n = gbuffer_normal(gbufferNormal, pixel, mode);
    } else {
        // From depth: the smaller of the two one-sided differences on each axis avoids
        // smearing normals across silhouettes.
        const uint2 size = p.inputSize;
        const uint2 l = uint2(pixel.x > 0 ? pixel.x - 1 : 0, pixel.y), r = uint2(min(pixel.x + 1, size.x - 1), pixel.y);
        const uint2 u = uint2(pixel.x, pixel.y > 0 ? pixel.y - 1 : 0), d = uint2(pixel.x, min(pixel.y + 1, size.y - 1));
        const float3 pl = world_at(l, size, depth_at(depth, l), p), pr = world_at(r, size, depth_at(depth, r), p);
        const float3 pu = world_at(u, size, depth_at(depth, u), p), pd = world_at(d, size, depth_at(depth, d), p);
        const float3 dx = length_squared(pr - position) < length_squared(position - pl) ? pr - position : position - pl;
        const float3 dy = length_squared(pd - position) < length_squared(position - pu) ? pd - position : position - pu;
        n = cross(dy, dx);
    }
    if (!all(isfinite(n)) || length_squared(n) < 1.0e-12f) n = normalize(p.cameraPosition.xyz - position);
    n = normalize(n);
    return dot(n, p.cameraPosition.xyz - position) < 0.0f ? -n : n;
}

static float view_depth(float3 position, constant RtaoParams& p) {
    return length(position - p.cameraPosition.xyz);
}

// Rays start this far off the reconstructed surface: depth precision, and the captured
// triangles are not bit-identical to the rasterized depth (grazing roads move most).
static float origin_offset(float distance) {
    return max(0.03f, distance * 1.5e-3f);
}

// ---- trace ---------------------------------------------------------------------------
// out: r = visibility (1 open, 0 occluded), g = view distance (0 for sky)

kernel void rtao_trace(constant RtaoParams& p [[buffer(0)]],
                       instance_acceleration_structure scene [[buffer(1)]],
                       texture2d<float, access::read> depth [[texture(0)]],
                       texture2d<float, access::read> gbufferNormal [[texture(1)]],
                       texture2d<float, access::write> raw [[texture(2)]],
                       uint2 id [[thread_position_in_grid]]) {
    if (any(id >= p.traceSize)) return;
    // Each AO pixel traces from one of its four input pixels, rotating over frames.
    const uint2 jitter = uint2(p.frame & 1u, (p.frame >> 1) & 1u);
    const uint2 pixel = min(id * 2u + jitter, p.inputSize - 1u);
    const float d = depth_at(depth, pixel);
    if (is_sky(d, p)) { raw.write(float4(1, 0, 0, 0), id); return; }
    const float3 position = world_at(pixel, p.inputSize, d, p);
    const float3 n = normal_at(depth, gbufferNormal, pixel, position, p, p.normalMode);
    const float distance = view_depth(position, p);

    ray r;
    r.origin = position + n * origin_offset(distance);
    r.direction = cosine_direction(n, random2(id, p.frame));
    r.min_distance = 0.0f;
    r.max_distance = p.radius;
    intersector<instancing> query;
    query.accept_any_intersection(true);
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    const auto hit = query.intersect(r, scene);
    float visibility = 1.0f;
    if (hit.type != intersection_type::none) {
        // Near hits occlude fully, hits towards the radius fade out.
        const float t = saturate(hit.distance / p.radius);
        visibility = 1.0f - p.strength * (1.0f - t * t);
    }
    raw.write(float4(visibility, distance, 0, 0), id);
}

// ---- temporal ------------------------------------------------------------------------
// motion: the title's motion texture at input resolution, in input pixels towards the
// previous position (temporal_shader_variants.py: velocity = (previous - current) * extent * (0.5, -0.5)).
// history in/out: r = AO, g = history length (frames), b = view distance

kernel void rtao_temporal(constant RtaoParams& p [[buffer(0)]],
                          texture2d<float, access::read> raw [[texture(0)]],
                          texture2d<float, access::read> motion [[texture(1)]],
                          texture2d<float, access::read> previous [[texture(2)]],
                          texture2d<float, access::write> current [[texture(3)]],
                          uint2 id [[thread_position_in_grid]]) {
    if (any(id >= p.traceSize)) return;
    const float4 sample = raw.read(id);
    if (sample.g <= 0.0f) { current.write(float4(1, 0, 0, 0), id); return; }
    float ao = sample.r, historyLength = 1.0f;
    if (p.validHistory) {
        const uint2 inputPixel = min(id * 2u, p.inputSize - 1u);
        const float2 velocity = motion.read(inputPixel).rg;
        const float2 back = (float2(id) + 0.5f) + velocity * 0.5f;  // AO pixels are half size
        if (all(back >= 0.0f) && all(back < float2(p.traceSize))) {
            const float4 history = previous.read(uint2(back));
            const bool same = history.b > 0.0f && abs(history.b - sample.g) <= p.depthRejection * sample.g;
            if (same && all(isfinite(history.rg))) {
                historyLength = min(history.g + 1.0f, 32.0f);
                const float alpha = max(1.0f / historyLength, p.historyBlendMinimum);
                ao = mix(history.r, sample.r, alpha);
            }
        }
    }
    current.write(float4(ao, historyLength, sample.g, 0), id);
}

// ---- spatial -------------------------------------------------------------------------
// One a-trous pass on the temporal result (r = AO, g = history length, b = view distance).
// Short histories are filtered harder: their AO is still mostly one noisy sample.

kernel void rtao_atrous(constant RtaoParams& p [[buffer(0)]],
                        constant uint& step [[buffer(1)]],
                        texture2d<float, access::read> input [[texture(0)]],
                        texture2d<float, access::write> output [[texture(1)]],
                        uint2 id [[thread_position_in_grid]]) {
    if (any(id >= p.traceSize)) return;
    const float4 center = input.read(id);
    if (center.b <= 0.0f) { output.write(center, id); return; }
    const float kernelWeights[3] = {3.0f / 8.0f, 1.0f / 4.0f, 1.0f / 16.0f};
    const float sharpness = mix(1.0f, 4.0f, saturate(center.g / 16.0f));
    float sum = 0.0f, total = 0.0f;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            const int2 q = int2(id) + int2(x, y) * int(step);
            if (any(q < 0) || any(q >= int2(p.traceSize))) continue;
            const float4 s = input.read(uint2(q));
            if (s.b <= 0.0f) continue;
            const float depthWeight = exp(-sharpness * abs(s.b - center.b) / max(center.b * 0.02f, 1.0e-3f));
            const float w = kernelWeights[abs(x)] * kernelWeights[abs(y)] * depthWeight;
            sum += s.r * w;
            total += w;
        }
    }
    output.write(float4(total > 0.0f ? sum / total : center.r, center.g, center.b, 0), id);
}

// ---- upsample ------------------------------------------------------------------------
// To input resolution: the 2x2 nearest AO pixels, weighted by view-distance similarity
// to this pixel. ao: r8/r16 float, 1 = unoccluded.

kernel void rtao_upsample(constant RtaoParams& p [[buffer(0)]],
                          texture2d<float, access::read> filtered [[texture(0)]],
                          texture2d<float, access::read> depth [[texture(1)]],
                          texture2d<float, access::write> ao [[texture(2)]],
                          uint2 id [[thread_position_in_grid]]) {
    if (any(id >= p.inputSize)) return;
    const float d = depth_at(depth, id);
    if (is_sky(d, p)) { ao.write(float4(1), id); return; }
    const float distance = view_depth(world_at(id, p.inputSize, d, p), p);
    const float2 source = (float2(id) + 0.5f) * 0.5f - 0.5f;
    const int2 base = int2(floor(source));
    const float2 f = source - float2(base);
    float sum = 0.0f, total = 0.0f;
    for (int y = 0; y <= 1; ++y) {
        for (int x = 0; x <= 1; ++x) {
            const int2 q = clamp(base + int2(x, y), int2(0), int2(p.traceSize) - 1);
            const float4 s = filtered.read(uint2(q));
            if (s.b <= 0.0f) continue;
            const float bilinear = (x ? f.x : 1.0f - f.x) * (y ? f.y : 1.0f - f.y);
            const float w = max(bilinear, 1.0e-3f) / (1.0e-3f + abs(s.b - distance) / max(distance, 1.0e-3f));
            sum += s.r * w;
            total += w;
        }
    }
    ao.write(float4(total > 0.0f ? sum / total : 1.0f), id);
}


// ---- apply ---------------------------------------------------------------------------
// One full-screen triangle over the lighting output, in its own render pass.
// Multiply: blended as dst * src (source factor DestinationColor, destination Zero), so
// the fragment returns the factor mix(1, ao, strength). Show: unblended AO in grey.

struct RtaoApplyVertex { float4 position [[position]]; };

vertex RtaoApplyVertex rtao_apply_vertex(uint id [[vertex_id]]) {
    const float2 uv = float2((id << 1) & 2, id & 2);
    return { float4(uv * float2(2, -2) + float2(-1, 1), 0, 1) };
}

fragment float4 rtao_apply_multiply(RtaoApplyVertex in [[stage_in]],
                                    texture2d<float, access::read> ao [[texture(0)]],
                                    constant float& strength [[buffer(0)]]) {
    const uint2 pixel = min(uint2(in.position.xy), uint2(ao.get_width() - 1, ao.get_height() - 1));
    return float4(float3(mix(1.0f, ao.read(pixel).r, strength)), 1.0f);
}

fragment float4 rtao_apply_show(RtaoApplyVertex in [[stage_in]],
                                texture2d<float, access::read> ao [[texture(0)]]) {
    const uint2 pixel = min(uint2(in.position.xy), uint2(ao.get_width() - 1, ao.get_height() - 1));
    return float4(float3(ao.read(pixel).r), 1.0f);
}


// ---- diagnostics ---------------------------------------------------------------------
// gta4_metal_raytracing_ao_view = debug, and a statistics pass every 300 traced frames.
// Debug texture (trace size): r = fract(world.x / 10), g = 1 when the AO ray hits within the
// radius, b = first hit of a long ray (1 km) along the same direction / (10 * radius).
// Statistics: uints (simd-reduced atomics) then floats, see ambient_occlusion.mm.

constant uint kStatTraced = 0, kStatSky = 1, kStatBadOrigin = 2, kStatNearHits = 3, kStatFarHits = 4,
              kStatAoMin = 5, kStatAoMax = 6, kStatPositionsFinite = 7, kStatPositionsBad = 8, kStatAoPixels = 9,
              kStatNearHitsUnderOffset = 10;
constant uint kSumOriginX = 0, kSumOriginY = 1, kSumOriginZ = 2, kSumFarDistance = 3, kSumViewDistance = 4,
              kSumAo = 5, kSumPositionX = 6, kSumPositionY = 7, kSumPositionZ = 8, kSumNearDistance = 9,
              kSumNormalAgreementRgb = 10, kSumNormalAgreementGrb = 11;

static void add_count(device atomic_uint* counts, uint index, uint value) {
    const uint total = simd_sum(value);
    if (simd_is_first() && total) atomic_fetch_add_explicit(&counts[index], total, memory_order_relaxed);
}
static void add_sum(device atomic_float* sums, uint index, float value) {
    const float total = simd_sum(value);
    if (simd_is_first() && total != 0.0f) atomic_fetch_add_explicit(&sums[index], total, memory_order_relaxed);
}

kernel void rtao_debug_trace(constant RtaoParams& p [[buffer(0)]],
                             instance_acceleration_structure scene [[buffer(1)]],
                             device atomic_uint* counts [[buffer(2)]],
                             device atomic_float* sums [[buffer(3)]],
                             texture2d<float, access::read> depth [[texture(0)]],
                             texture2d<float, access::read> gbufferNormal [[texture(1)]],
                             texture2d<float, access::write> debug [[texture(2)]],
                             uint2 id [[thread_position_in_grid]]) {
    // No early return before the simd reductions: out-of-range lanes add zero.
    const bool inside = all(id < p.traceSize);
    const uint2 pixel = min(id * 2u, p.inputSize - 1u);
    const float d = depth_at(depth, pixel);
    const bool sky = !inside || is_sky(d, p);
    float3 position = float3(0), n = float3(0, 0, 1);
    float distance = 0.0f;
    bool good = false;
    if (!sky) {
        position = world_at(pixel, p.inputSize, d, p);
        good = all(isfinite(position));
        if (good) { n = normal_at(depth, gbufferNormal, pixel, position, p, p.normalMode); distance = view_depth(position, p); }
    }
    bool near = false, far = false;
    float nearDistance = 0.0f, farDistance = 0.0f;
    if (good) {
        ray r;
        r.origin = position + n * origin_offset(distance);
        r.direction = cosine_direction(n, random2(id, p.frame));
        r.min_distance = 0.0f;
        r.max_distance = 1000.0f;
        intersector<instancing> query;
        query.accept_any_intersection(false);  // the nearest hit: its distance is the point
        query.assume_geometry_type(geometry_type::triangle);
        query.force_opacity(forced_opacity::opaque);
        const auto hit = query.intersect(r, scene);
        if (hit.type != intersection_type::none) {
            far = true;
            farDistance = hit.distance;
            near = hit.distance <= p.radius;
            nearDistance = near ? hit.distance : 0.0f;
        }
    }
    if (inside)
        debug.write(float4(good ? fract(position.x / 10.0f) : 0.0f, near ? 1.0f : 0.0f,
                           far ? saturate(farDistance / (10.0f * p.radius)) : 0.0f, 1.0f), id);
    add_count(counts, kStatTraced, good ? 1u : 0u);
    add_count(counts, kStatSky, inside && sky ? 1u : 0u);
    add_count(counts, kStatBadOrigin, !sky && !good ? 1u : 0u);
    add_count(counts, kStatNearHits, near ? 1u : 0u);
    add_count(counts, kStatFarHits, far ? 1u : 0u);
    add_count(counts, kStatNearHitsUnderOffset, near && nearDistance < 0.1f ? 1u : 0u);
    add_sum(sums, kSumOriginX, good ? position.x : 0.0f);
    add_sum(sums, kSumOriginY, good ? position.y : 0.0f);
    add_sum(sums, kSumOriginZ, good ? position.z : 0.0f);
    add_sum(sums, kSumViewDistance, distance);
    add_sum(sums, kSumFarDistance, farDistance);
    add_sum(sums, kSumNearDistance, nearDistance);
    // How well each G-buffer decoding agrees with the normal from depth (mean dot, 1 = same).
    float agreeRgb = 0.0f, agreeGrb = 0.0f;
    if (good) {
        const float3 fromDepth = normal_at(depth, gbufferNormal, pixel, position, p, 0u);
        agreeRgb = dot(fromDepth, normal_at(depth, gbufferNormal, pixel, position, p, 1u));
        agreeGrb = dot(fromDepth, normal_at(depth, gbufferNormal, pixel, position, p, 2u));
    }
    add_sum(sums, kSumNormalAgreementRgb, agreeRgb);
    add_sum(sums, kSumNormalAgreementGrb, agreeGrb);
}

kernel void rtao_debug_ao(texture2d<float, access::read> ao [[texture(0)]],
                          device atomic_uint* counts [[buffer(2)]],
                          device atomic_float* sums [[buffer(3)]],
                          uint2 id [[thread_position_in_grid]]) {
    const bool inside = id.x < ao.get_width() && id.y < ao.get_height();
    const float v = inside ? max(ao.read(id).r, 0.0f) : 0.0f;
    const uint bits = as_type<uint>(v);  // non-negative floats order like their bits
    const uint lo = simd_min(inside ? bits : 0xFFFFFFFFu), hi = simd_max(inside ? bits : 0u);
    if (simd_is_first()) {
        atomic_fetch_min_explicit(&counts[kStatAoMin], lo, memory_order_relaxed);
        atomic_fetch_max_explicit(&counts[kStatAoMax], hi, memory_order_relaxed);
    }
    add_count(counts, kStatAoPixels, inside ? 1u : 0u);
    add_sum(sums, kSumAo, v);
}

kernel void rtao_debug_positions(const device float4* positions [[buffer(0)]],
                                 constant uint& count [[buffer(1)]],
                                 device atomic_uint* counts [[buffer(2)]],
                                 device atomic_float* sums [[buffer(3)]],
                                 uint id [[thread_position_in_grid]]) {
    const float4 v = id < count ? positions[id] : float4(0);
    const bool finite = id < count && all(isfinite(v.xyz));
    add_count(counts, kStatPositionsFinite, finite ? 1u : 0u);
    add_count(counts, kStatPositionsBad, id < count && !finite ? 1u : 0u);
    add_sum(sums, kSumPositionX, finite ? v.x : 0.0f);
    add_sum(sums, kSumPositionY, finite ? v.y : 0.0f);
    add_sum(sums, kSumPositionZ, finite ? v.z : 0.0f);
}

fragment float4 rtao_apply_debug(RtaoApplyVertex in [[stage_in]],
                                 texture2d<float, access::read> debug [[texture(0)]]) {
    const uint2 pixel = min(uint2(in.position.xy) / 2u, uint2(debug.get_width() - 1, debug.get_height() - 1));
    return float4(debug.read(pixel).rgb, 1.0f);
}
