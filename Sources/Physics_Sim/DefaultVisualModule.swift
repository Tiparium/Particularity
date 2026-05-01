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
        uint playbackRecipe;
        uint isPlaybackVisual;
        uint playbackFrontLayerVisible;
        uint playbackMiddleLayerVisible;
        uint playbackFinalLayerVisible;
        uint playbackFrontLayerSlot;
        uint playbackMiddleLayerSlot;
        uint playbackFinalLayerSlot;
        float playbackFrontLayerHorizontalOffset;
        float playbackMiddleLayerHorizontalOffset;
        float playbackFinalLayerHorizontalOffset;
        float playbackFrontLayerOffset;
        float playbackMiddleLayerOffset;
        float playbackFinalLayerOffset;
        uint playbackForceLayer;
        uint playbackForceSlot;
        uint playbackNormalizationMode;
        uint playbackUsePreparedHeight;
        float playbackActivationMinimum;
        float playbackActivationMaximum;
        uint padding0;
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

    struct MeshVertexOut {
        float4 position [[position]];
        float4 color;
    };

    struct PlaybackMeshSmoothParams {
        uint particleCount;
        uint gridSide;
        float smoothing;
        uint padding0;
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

    float clamp01(float value) {
        return min(max(value, 0.0), 1.0);
    }

    uint playback_layer_index(ParticleState particle) {
        if (particle_active(particle) == 0) {
            return 0u;
        }
        return (uint)clamp(round(particle.impulse.y), 0.0, 2.0);
    }

    uint playback_effective_layer_index(ParticleState particle, constant ParticleUniforms& u) {
        if (u.playbackForceLayer <= 2u) {
            return u.playbackForceLayer;
        }
        return (uint)clamp(round(particle.impulse.y), 0.0, 2.0);
    }

    uint playback_slot_index(ParticleState particle) {
        if (particle_active(particle) == 0) {
            return 0u;
        }
        return (uint)clamp(round(particle.impulse.z), 0.0, 4.0);
    }

    uint playback_effective_slot_index(ParticleState particle, constant ParticleUniforms& u) {
        if (u.playbackForceSlot <= 4u) {
            return u.playbackForceSlot;
        }
        return (uint)clamp(round(particle.impulse.z), 0.0, 4.0);
    }

    bool should_render_playback_particle(ParticleState particle, constant ParticleUniforms& u) {
        uint layer = playback_effective_layer_index(particle, u);
        uint slot = playback_effective_slot_index(particle, u);
        if (layer == 0u) {
            return u.playbackFrontLayerVisible != 0 && slot == u.playbackFrontLayerSlot;
        }
        if (layer == 1u) {
            return u.playbackMiddleLayerVisible != 0 && slot == u.playbackMiddleLayerSlot;
        }
        return u.playbackFinalLayerVisible != 0 && slot == u.playbackFinalLayerSlot;
    }

    float playback_layer_offset(ParticleState particle, constant ParticleUniforms& u) {
        uint layer = playback_effective_layer_index(particle, u);
        if (layer == 0u) {
            return u.playbackFrontLayerOffset;
        }
        if (layer == 1u) {
            return u.playbackMiddleLayerOffset;
        }
        return u.playbackFinalLayerOffset;
    }

    float playback_layer_horizontal_offset(ParticleState particle, constant ParticleUniforms& u) {
        uint layer = playback_effective_layer_index(particle, u);
        if (layer == 0u) {
            return u.playbackFrontLayerHorizontalOffset;
        }
        if (layer == 1u) {
            return u.playbackMiddleLayerHorizontalOffset;
        }
        return u.playbackFinalLayerHorizontalOffset;
    }

    float playback_activation_normalized(ParticleState particle, constant ParticleUniforms& u) {
        if (u.playbackNormalizationMode == 1u) {
            float range = max(0.000001, u.playbackActivationMaximum - u.playbackActivationMinimum);
            return clamp01((particle.velocity.x - u.playbackActivationMinimum) / range);
        }
        return clamp01(particle.velocity.y);
    }

    float playback_activation_height(ParticleState particle, constant ParticleUniforms& u) {
        if (u.playbackUsePreparedHeight != 0u) {
            return particle.position.z;
        }
        if (u.playbackNormalizationMode == 1u) {
            return (playback_activation_normalized(particle, u) * 2.0 - 1.0) * 0.72;
        }
        return particle.position.z;
    }

    float playback_local_amplitude(ParticleState particle, constant ParticleUniforms& u) {
        return clamp01(abs(playback_activation_height(particle, u)) / 0.72);
    }

    float3 playback_amplitude_ramp(float value) {
        float t = clamp01(value);
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

    float4 color_for_playback_recipe(ParticleState particle, constant ParticleUniforms& u) {
        uint recipe = u.playbackRecipe;
        float localAmplitude = playback_local_amplitude(particle, u);
        float periodicity = clamp01(particle.velocity.z * 2.5);
        float targetNorm = clamp01(particle.impulse.x);
        float3 amplitudeColor = playback_amplitude_ramp(localAmplitude);

        if (recipe == 1u) {
            float hue = fmod(targetNorm + u.spectrumOffset * 0.10, 1.0);
            float3 bandColor = hsv_to_rgb(hue, 0.85, 1.0);
            float saturation = clamp01(0.45 + 0.50 * localAmplitude);
            float value = clamp01(0.28 + 0.72 * localAmplitude);
            float alpha = clamp01(0.25 + 0.75 * periodicity);
            float3 rgb = mix(amplitudeColor, bandColor, 0.45) * value * (0.75 + 0.25 * saturation);
            return float4(rgb, alpha);
        }

        if (recipe == 2u) {
            float saturation = clamp01(0.20 + 0.75 * periodicity);
            float value = clamp01(0.10 + 0.90 * localAmplitude);
            float alpha = localAmplitude < 0.08 ? 0.0 : clamp01(0.25 + 0.75 * periodicity);
            float3 rgb = mix(amplitudeColor * value, float3(1.0, 0.96, 0.42), periodicity * 0.35);
            return float4(rgb * (0.55 + 0.45 * saturation), alpha);
        }

        float3 shimmer = hsv_to_rgb(fmod(localAmplitude + u.spectrumOffset * 0.08, 1.0), 0.75, 1.0);
        float3 rgb = mix(amplitudeColor, shimmer, 0.18 + 0.22 * periodicity);
        float value = 0.35 + 0.65 * localAmplitude;
        return float4(rgb * value, 1.0);
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
        float3 renderPosition = particle.position.xyz;
        if (u.isPlaybackVisual != 0) {
            renderPosition.x += playback_layer_horizontal_offset(particle, u);
            renderPosition.z = playback_activation_height(particle, u);
            renderPosition.z += playback_layer_offset(particle, u);
        }
        out.position = u.mvp * float4(renderPosition, 1.0);
        if (u.isPlaybackVisual != 0) {
            if (!should_render_playback_particle(particle, u)) {
                out.color = float4(0.0, 0.0, 0.0, 0.0);
                out.pointSize = 0.0;
                return out;
            }
            out.color = color_for_playback_recipe(particle, u);
        } else {
            out.color = color_for_type(particle_type(particle), u.particleTypeCount, u.spectrumOffset);
        }

        if (particle_active(particle) == 0) {
            out.color.a = 0.0;
            out.pointSize = 0.0;
            return out;
        }

        if (u.showOptimizationInfo != 0 && vertexID != 0) {
            out.color = float4(out.color.rgb * 0.22, 0.10);
        }

        float clipW = max(0.0001, out.position.w);
        float sizeMultiplier = 1.0;
        if (u.isPlaybackVisual != 0) {
            float activationRaw = particle.velocity.x;
            float activationNorm = playback_activation_normalized(particle, u);
            float periodicity = clamp01(particle.velocity.z * 2.5);
            float activationMagnitude = clamp01(abs(activationRaw) * 1.5);
            if (u.playbackRecipe == 1u) {
                sizeMultiplier = 0.65 + 1.05 * activationNorm + 0.45 * periodicity;
            } else if (u.playbackRecipe == 2u) {
                sizeMultiplier = 0.60 + 0.90 * activationMagnitude + 0.80 * periodicity;
            } else {
                sizeMultiplier = 0.70 + 1.20 * activationNorm;
            }
            sizeMultiplier = min(sizeMultiplier, 2.8);
        }
        float screenSpaceSize = max(1.0, (u.sphereSize * sizeMultiplier) * u.viewportHeight * u.projectionYScale / clipW);
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

    vertex MeshVertexOut mesh_vs(
        device const ParticleState *particles [[buffer(0)]],
        constant ParticleUniforms& u [[buffer(1)]],
        uint vertexID [[vertex_id]]
    ) {
        MeshVertexOut out;
        ParticleState particle = particles[vertexID];
        float3 renderPosition = particle.position.xyz;
        if (u.isPlaybackVisual != 0) {
            renderPosition.x += playback_layer_horizontal_offset(particle, u);
            renderPosition.z = playback_activation_height(particle, u);
            renderPosition.z += playback_layer_offset(particle, u);
        }
        out.position = u.mvp * float4(renderPosition, 1.0);
        if (u.isPlaybackVisual != 0) {
            if (!should_render_playback_particle(particle, u)) {
                out.color = float4(0.0, 0.0, 0.0, 0.0);
                return out;
            }
            out.color = color_for_playback_recipe(particle, u);
        } else {
            out.color = color_for_type(particle_type(particle), u.particleTypeCount, u.spectrumOffset);
        }

        if (particle_active(particle) == 0) {
            out.color.a = 0.0;
        }

        return out;
    }

    fragment float4 mesh_fs(MeshVertexOut in [[stage_in]]) {
        if (in.color.a <= 0.0) {
            discard_fragment();
        }
        return in.color;
    }

    kernel void playback_mesh_smooth(
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
        particle.position.z = mix(particle.position.z, averagedHeight, clamp01(params.smoothing));
        destinationParticles[id] = particle;
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
