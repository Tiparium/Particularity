import simd

enum DefaultVisualModuleRuntime {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LineVertexIn {
        float3 position [[attribute(0)]];
    };

    struct ParticleVertexIn {
        float4 position [[attribute(0)]];
        float4 color [[attribute(1)]];
    };

    struct LineUniforms {
        float4x4 mvp;
        float4 color;
    };

    struct ParticleUniforms {
        float4x4 mvp;
        float pointSize;
        uint showOptimizationInfo;
    };

    struct LineVertexOut {
        float4 position [[position]];
        float4 color;
    };

    struct ParticleVertexOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
    };

    vertex LineVertexOut line_vs(LineVertexIn in [[stage_in]], constant LineUniforms& u [[buffer(1)]]) {
        LineVertexOut out;
        out.position = u.mvp * float4(in.position, 1.0);
        out.color = u.color;
        return out;
    }

    fragment float4 line_fs(LineVertexOut in [[stage_in]]) {
        return in.color;
    }

    vertex ParticleVertexOut particle_vs(
        ParticleVertexIn in [[stage_in]],
        constant ParticleUniforms& u [[buffer(2)]],
        uint vertexID [[vertex_id]]
    ) {
        ParticleVertexOut out;
        out.position = u.mvp * float4(in.position.xyz, 1.0);
        out.color = in.color;
        if (u.showOptimizationInfo != 0 && vertexID != 0) {
            out.color = float4(in.color.rgb * 0.22, 0.10);
        }
        out.pointSize = u.pointSize;
        return out;
    }

    fragment float4 particle_fs(ParticleVertexOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
        float2 centered = pointCoord * 2.0 - 1.0;
        float radiusSquared = dot(centered, centered);
        if (radiusSquared > 1.0) {
            discard_fragment();
        }
        return in.color;
    }
    """

    static func colorForType(typeIndex: Int, typeCount: Int, spectrumOffset: Float) -> SIMD4<Float> {
        let boundedTypeCount = max(1, typeCount)
        let hue = fmodf(spectrumOffset + Float(typeIndex) / Float(boundedTypeCount), 1.0)
        let rgb = hsvToRgb(h: hue, s: 0.8, v: 1.0)
        return SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1.0)
    }

    private static func hsvToRgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let i = floor(h * 6.0)
        let f = h * 6.0 - i
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)

        switch Int(i) % 6 {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }
}
