enum MLTrainingPlaybackPresenterRuntime {
    static let shaderSource = """
    struct MLPlaybackSurfaceUniforms {
        float4x4 mvp;
        float spectrumOffset;
        float amplitudeScale;
        uint surfaceCount;
        uint visualRecipe;
        uint padding0;
        float frontLayerHorizontalOffset;
        float middleLayerHorizontalOffset;
        float finalLayerHorizontalOffset;
        float frontLayerOffset;
        float middleLayerOffset;
        float finalLayerOffset;
    };

    struct PlaybackMeshSmoothParams {
        uint particleCount;
        uint gridSide;
        float smoothing;
        uint padding0;
    };

    struct MLPlaybackMeshVertexOut {
        float4 position [[position]];
        float4 color;
    };

    float ml_playback_clamp01(float value) {
        return min(max(value, 0.0), 1.0);
    }

    uint ml_playback_layer_index(ParticleState particle) {
        if (particle_active(particle) == 0) {
            return 0u;
        }
        return (uint)clamp(round(particle.impulse.y), 0.0, 2.0);
    }

    float ml_playback_layer_horizontal_offset(ParticleState particle, constant MLPlaybackSurfaceUniforms& u) {
        uint layer = ml_playback_layer_index(particle);
        if (layer == 0u) {
            return u.frontLayerHorizontalOffset;
        }
        if (layer == 1u) {
            return u.middleLayerHorizontalOffset;
        }
        return u.finalLayerHorizontalOffset;
    }

    float ml_playback_layer_offset(ParticleState particle, constant MLPlaybackSurfaceUniforms& u) {
        uint layer = ml_playback_layer_index(particle);
        if (layer == 0u) {
            return u.frontLayerOffset;
        }
        if (layer == 1u) {
            return u.middleLayerOffset;
        }
        return u.finalLayerOffset;
    }

    float3 ml_playback_amplitude_ramp(float value) {
        float t = ml_playback_clamp01(value);
        float3 c0 = float3(0.06, 0.12, 0.90);
        float3 c1 = float3(0.00, 0.72, 1.00);
        float3 c2 = float3(0.10, 0.92, 0.40);
        float3 c3 = float3(1.00, 0.90, 0.08);
        float3 c4 = float3(1.00, 0.14, 0.06);

        if (t < 0.25) {
            return mix(c0, c1, t / 0.25);
        }
        if (t < 0.50) {
            return mix(c1, c2, (t - 0.25) / 0.25);
        }
        if (t < 0.75) {
            return mix(c2, c3, (t - 0.50) / 0.25);
        }
        return mix(c3, c4, (t - 0.75) / 0.25);
    }

    float3 ml_playback_hsv_to_rgb(float h, float s, float v) {
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

    float4 ml_playback_surface_color(ParticleState particle, constant MLPlaybackSurfaceUniforms& u) {
        float amplitude = ml_playback_clamp01(abs(particle.position.z) / max(0.000001, u.amplitudeScale));
        float periodicity = ml_playback_clamp01(particle.velocity.z * 2.5);
        float targetNorm = ml_playback_clamp01(particle.impulse.x);
        float3 color = mix(
            ml_playback_amplitude_ramp(amplitude),
            float3(1.0, 0.96, 0.42),
            periodicity * 0.22
        );

        if (u.visualRecipe == 1u) {
            float hue = fmod(targetNorm + u.spectrumOffset * 0.10, 1.0);
            float3 bandColor = ml_playback_hsv_to_rgb(hue, 0.85, 1.0);
            float saturation = ml_playback_clamp01(0.45 + 0.50 * amplitude);
            float value = ml_playback_clamp01(0.28 + 0.72 * amplitude);
            float alpha = ml_playback_clamp01(0.25 + 0.75 * periodicity);
            float3 rgb = mix(color, bandColor, 0.45) * value * (0.75 + 0.25 * saturation);
            return float4(rgb, alpha);
        }

        if (u.visualRecipe == 2u) {
            float saturation = ml_playback_clamp01(0.20 + 0.75 * periodicity);
            float value = ml_playback_clamp01(0.10 + 0.90 * amplitude);
            float alpha = amplitude < 0.08 ? 0.0 : ml_playback_clamp01(0.25 + 0.75 * periodicity);
            float3 rgb = mix(color * value, float3(1.0, 0.96, 0.42), periodicity * 0.35);
            return float4(rgb * (0.55 + 0.45 * saturation), alpha);
        }

        float3 shimmer = ml_playback_hsv_to_rgb(fmod(amplitude + u.spectrumOffset * 0.08, 1.0), 0.75, 1.0);
        float3 rgb = mix(color, shimmer, 0.18 + 0.22 * periodicity);
        return float4(rgb * (0.35 + 0.65 * amplitude), 0.92);
    }

    vertex MLPlaybackMeshVertexOut ml_playback_surface_mesh_vs(
        device const ParticleState *particles [[buffer(0)]],
        constant MLPlaybackSurfaceUniforms& u [[buffer(1)]],
        uint vertexID [[vertex_id]]
    ) {
        MLPlaybackMeshVertexOut out;
        ParticleState particle = particles[vertexID];
        float3 renderPosition = particle.position.xyz;
        renderPosition.x += ml_playback_layer_horizontal_offset(particle, u);
        renderPosition.z += ml_playback_layer_offset(particle, u);
        out.position = u.mvp * float4(renderPosition, 1.0);
        out.color = ml_playback_surface_color(particle, u);
        if (particle_active(particle) == 0) {
            out.color.a = 0.0;
        }
        return out;
    }

    fragment float4 ml_playback_surface_mesh_fs(MLPlaybackMeshVertexOut in [[stage_in]]) {
        if (in.color.a <= 0.0) {
            discard_fragment();
        }
        return in.color;
    }

    kernel void ml_playback_surface_mesh_smooth(
        device const ParticleState *sourceParticles [[buffer(0)]],
        device ParticleState *destinationParticles [[buffer(1)]],
        constant PlaybackMeshSmoothParams& params [[buffer(2)]],
        uint id [[thread_position_in_grid]]
    ) {
        if (id >= params.particleCount) {
            return;
        }

        uint gridSide = max(params.gridSide, 1u);
        uint surfaceParticleCount = gridSide * gridSide;
        uint surfaceStart = (id / surfaceParticleCount) * surfaceParticleCount;
        uint localIndex = id - surfaceStart;
        uint x = localIndex % gridSide;
        uint y = localIndex / gridSide;

        ParticleState particle = sourceParticles[id];
        float weightedSum = 0.0;
        float weightTotal = 0.0;

        for (int yOffset = -1; yOffset <= 1; yOffset += 1) {
            for (int xOffset = -1; xOffset <= 1; xOffset += 1) {
                int sampleX = int(x) + xOffset;
                int sampleY = int(y) + yOffset;
                if (sampleX < 0 || sampleX >= int(gridSide) || sampleY < 0 || sampleY >= int(gridSide)) {
                    continue;
                }

                uint sampleIndex = surfaceStart + uint(sampleY) * gridSide + uint(sampleX);
                if (sampleIndex >= params.particleCount) {
                    continue;
                }

                int axisDistance = abs(xOffset) + abs(yOffset);
                float weight = axisDistance == 0 ? 4.0 : (axisDistance == 1 ? 2.0 : 1.0);
                weightedSum += sourceParticles[sampleIndex].position.z * weight;
                weightTotal += weight;
            }
        }

        float averagedHeight = weightedSum / max(0.000001, weightTotal);
        particle.position.z = mix(particle.position.z, averagedHeight, ml_playback_clamp01(params.smoothing));
        destinationParticles[id] = particle;
    }
    """
}
