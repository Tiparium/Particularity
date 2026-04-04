import simd

enum DefaultVisualModuleRuntime {
    static let shaderSource = """
    struct LineVertexIn {
        float3 position [[attribute(0)]];
    };

    struct LineUniforms {
        float4x4 mvp;
        float4 color;
    };

    struct ParticleUniforms {
        float4x4 mvp;
        float sphereSize;
        float viewportHeight;
        float projectionYScale;
        float spectrumOffset;
        uint particleTypeCount;
        uint showOptimizationInfo;
        uint _padding;
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

    float3 hsv_to_rgb(float h, float s, float v) {
        float i = floor(h * 6.0);
        float f = h * 6.0 - i;
        float p = v * (1.0 - s);
        float q = v * (1.0 - f * s);
        float t = v * (1.0 - (1.0 - f) * s);

        switch (int(i) % 6) {
            case 0: return float3(v, t, p);
            case 1: return float3(q, v, p);
            case 2: return float3(p, v, t);
            case 3: return float3(p, q, v);
            case 4: return float3(t, p, v);
            default: return float3(v, p, q);
        }
    }

    float4 color_for_type(uint typeIndex, uint typeCount, float spectrumOffset) {
        uint boundedTypeCount = max(typeCount, 1u);
        float hue = fmod(spectrumOffset + float(typeIndex) / float(boundedTypeCount), 1.0);
        float3 rgb = hsv_to_rgb(hue, 0.8, 1.0);
        return float4(rgb, 1.0);
    }

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
        device const ParticleState *particles [[buffer(0)]],
        constant ParticleUniforms& u [[buffer(1)]],
        uint vertexID [[vertex_id]]
    ) {
        ParticleVertexOut out;
        ParticleState particle = particles[vertexID];
        out.position = u.mvp * float4(particle.position.xyz, 1.0);
        out.color = color_for_type(particle_type(particle), u.particleTypeCount, u.spectrumOffset);

        if (particle_active(particle) == 0) {
            out.color.a = 0.0;
            out.pointSize = 0.0;
            return out;
        }

        if (u.showOptimizationInfo != 0 && vertexID != 0) {
            out.color = float4(out.color.rgb * 0.22, 0.10);
        }

        float clipW = max(0.0001, out.position.w);
        float screenSpaceSize = max(1.0, u.sphereSize * u.viewportHeight * u.projectionYScale / clipW);
        out.pointSize = screenSpaceSize;
        return out;
    }

    fragment float4 particle_fs(ParticleVertexOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
        float2 centered = pointCoord * 2.0 - 1.0;
        float radiusSquared = dot(centered, centered);
        if (radiusSquared > 1.0 || in.color.a <= 0.0) {
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
