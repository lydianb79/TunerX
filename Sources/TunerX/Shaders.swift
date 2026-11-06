/// Metal shader source, compiled at runtime (keeps the SwiftPM build free of .metal resource handling).
let tunerShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TXVertex {
    float2 pos;      // pixels, origin top-left
    float2 uv;
    float4 color;
    float4 params;   // x = mode (0 solid, 1 glyph, 2 strobe, 3 glow), y/z = mode specific
};

struct TXUniforms {
    float2 viewport;
    float  time;
    float  strobePhase;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float4 params;
};

vertex VOut tx_vertex(uint vid [[vertex_id]],
                      const device TXVertex *verts [[buffer(0)]],
                      constant TXUniforms &u [[buffer(1)]]) {
    TXVertex v = verts[vid];
    VOut o;
    float2 ndc = float2(v.pos.x / u.viewport.x * 2.0 - 1.0, 1.0 - v.pos.y / u.viewport.y * 2.0);
    o.position = float4(ndc, 0.0, 1.0);
    o.uv = v.uv;
    o.color = v.color;
    o.params = v.params;
    return o;
}

fragment float4 tx_fragment(VOut in [[stage_in]],
                            constant TXUniforms &u [[buffer(1)]],
                            texture2d<float> atlas [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    int mode = int(in.params.x + 0.5);
    float4 c = in.color;
    if (mode == 1) {                                   // text glyph
        float a = atlas.sample(smp, in.uv).a;
        return float4(c.rgb, c.a * a);
    }
    if (mode == 2) {                                   // strobe band
        float x = in.uv.x * in.params.y + u.strobePhase * in.params.z;
        float s = 0.5 + 0.5 * sin(x * 6.2831853);
        s = smoothstep(0.25, 0.75, s);
        float edge = smoothstep(0.0, 0.12, in.uv.y) * (1.0 - smoothstep(0.88, 1.0, in.uv.y));
        float side = smoothstep(0.0, 0.04, in.uv.x) * (1.0 - smoothstep(0.96, 1.0, in.uv.x));
        float3 col = mix(c.rgb * 0.06, c.rgb, s);
        return float4(col, c.a * edge * side);
    }
    if (mode == 3) {                                   // soft glow, uv.x in [-1, 1]
        float a = exp(-in.uv.x * in.uv.x * 6.0);
        return float4(c.rgb, c.a * a);
    }
    return c;
}
"""
