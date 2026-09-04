enum ProfileHeaderPlaybackPresenterRuntime {
    static let shaderSource = """
    struct ProfileHeaderParticleUniforms {
        float4x4 mvp;
        float4 nodeColor;
        float nodeSizeFloor;
        float nodeSizeCeiling;
        float viewportHeight;
        float projectionYScale;
    };
    struct ProfileHeaderParticleOut { float4 position [[position]]; float4 color; float pointSize [[point_size]]; };
    vertex ProfileHeaderParticleOut profile_header_particle_vs(device const ParticleState *particles [[buffer(0)]], constant ProfileHeaderParticleUniforms& u [[buffer(1)]], uint id [[vertex_id]]) {
        ProfileHeaderParticleOut out;
        ParticleState p = particles[id];
        out.position = u.mvp * float4(p.position.xyz, 1.0);
        float t = clamp((p.impulse.x - 0.004) / 0.006, 0.0, 1.0);
        float size = mix(u.nodeSizeFloor, u.nodeSizeCeiling, t);
        out.pointSize = max(1.0, size * u.viewportHeight * u.projectionYScale / max(0.0001, out.position.w));
        out.color = u.nodeColor;
        return out;
    }
    fragment float4 profile_header_particle_fs(ProfileHeaderParticleOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
        float2 centered = pointCoord * 2.0 - 1.0;
        if (dot(centered, centered) > 1.0) discard_fragment();
        return in.color;
    }
    struct ProfileHeaderVertVertex { float4 position; };
    struct ProfileHeaderVertUniforms { float4x4 mvp; float4 color; };
    struct ProfileHeaderVertOut { float4 position [[position]]; float4 color; };
    vertex ProfileHeaderVertOut profile_header_vert_vs(device const ProfileHeaderVertVertex *vertices [[buffer(0)]], constant ProfileHeaderVertUniforms& u [[buffer(1)]], uint id [[vertex_id]]) {
        ProfileHeaderVertOut out;
        out.position = u.mvp * vertices[id].position;
        out.color = u.color;
        return out;
    }
    fragment float4 profile_header_vert_fs(ProfileHeaderVertOut in [[stage_in]]) { return in.color; }
    """
}
