import AppKit
import CoreText
import Foundation
import simd

/// Deterministic source generator. The rasterized glyph image is used only to
/// sample anchors; every visible element is still supplied as particle data.
final class ProfileHeaderPlaybackRuntime: ParticlePlaybackRuntime {
    private struct GridCell: Hashable {
        let x: Int
        let y: Int
    }

    private struct RasterSample {
        let x: Int
        let y: Int
        let seed: Float
        let glyphOwner: Int
    }

    private struct GlyphInterval {
        let owner: Int
        let lowerX: CGFloat
        let upperX: CGFloat

        func distance(to x: CGFloat) -> CGFloat {
            if x < lowerX { return lowerX - x }
            if x > upperX { return x - upperX }
            return 0
        }
    }

    private struct Anchor {
        let position: SIMD3<Float>
        let phaseA: Float
        let phaseB: Float
        let radius: Float
        let tangent: SIMD2<Float>
        let tangentConfidence: Float
        let glyphOwner: Int
    }

    private struct GeneratedProfile {
        let anchors: [Anchor]
        let connectionCandidates: [[(index: Int, distance: Float)]]
        let maximumConnectionDistance: Float
    }

    private struct ConnectionRequest: Equatable {
        let coverage: Float
        let geometryAdherence: Float
        let maxConnections: Int
    }

    private let durationSeconds: Double
    private let anchors: [Anchor]
    private let connectionCandidates: [[(index: Int, distance: Float)]]
    private let maximumConnectionDistance: Float
    private var cachedConnectionRequest: ConnectionRequest?
    private var cachedConnectionPairs: [(source: Int, target: Int)] = []
    let sourceText: String
    let sourceNodesPerCharacter: Int
    let sourceTextScale: Float
    var motionRadius: Float

    var timeline: PlaybackTimelineState {
        PlaybackTimelineState(
            currentSeconds: 0,
            durationSeconds: durationSeconds,
            playbackRate: 1,
            isLooping: true,
            sampleCount: Int(durationSeconds * 60),
            currentSampleIndex: nil
        )
    }

    init(
        text: String,
        nodesPerCharacter: Int,
        textScale: Float,
        motionRadius: Float,
        durationSeconds: Double
    ) {
        self.durationSeconds = max(4, durationSeconds)
        sourceText = text
        sourceNodesPerCharacter = nodesPerCharacter
        sourceTextScale = textScale
        self.motionRadius = motionRadius
        let generated = Self.makeProfile(
            text: text,
            nodesPerCharacter: nodesPerCharacter,
            textScale: textScale
        )
        anchors = generated.anchors
        connectionCandidates = generated.connectionCandidates
        maximumConnectionDistance = generated.maximumConnectionDistance
    }

    func frame(at seconds: Double) -> PlaybackParticleFrame {
        let time = min(max(0, seconds), durationSeconds)
        let normalized = Float(time / durationSeconds)
        let loopPhase: Float = time >= durationSeconds ? 0 : normalized * .pi * 2
        let particles = anchors.enumerated().map { index, anchor in
            let offset = SIMD3<Float>(
                sin(loopPhase + anchor.phaseA) * motionRadius,
                cos(loopPhase * 2 + anchor.phaseB) * motionRadius * 0.22,
                cos(loopPhase + anchor.phaseB) * motionRadius * 0.80
            )
            return ParticleState(
                position: anchor.position + offset,
                velocity: offset,
                impulse: SIMD3<Float>(anchor.radius, 0, 0),
                type: 0,
                particleID: UInt32(index),
                active: 1
            )
        }
        return PlaybackParticleFrame(
            sampleIndex: min(max(0, Int((time * 60).rounded())), max(0, timeline.sampleCount! - 1)),
            timeSeconds: time,
            particles: particles
        )
    }

    func connectionPairs(
        coverage: Float,
        geometryAdherence: Float,
        maxConnections: Int
    ) -> [(source: Int, target: Int)] {
        guard coverage > 0, maxConnections > 0 else { return [] }
        let request = ConnectionRequest(
            coverage: min(coverage, 1),
            geometryAdherence: min(max(geometryAdherence, 0), 1),
            maxConnections: maxConnections
        )
        if cachedConnectionRequest == request {
            return cachedConnectionPairs
        }
        var pairs: [(source: Int, target: Int)] = []
        var emitted = Set<UInt64>()
        pairs.reserveCapacity(Int(Float(anchors.count * maxConnections) * request.coverage))

        for sourceIndex in anchors.indices {
            let sourceSample = Float((sourceIndex &* 1_103_515_245 &+ 12_345) & 0xFFFF) / 65_535
            guard sourceSample < request.coverage else { continue }

            var sourceConnectionCount = 0
            let rankedCandidates = connectionCandidates[sourceIndex].sorted {
                let left = connectionScore(
                    sourceIndex: sourceIndex,
                    targetIndex: $0.index,
                    geometryAdherence: request.geometryAdherence
                )
                let right = connectionScore(
                    sourceIndex: sourceIndex,
                    targetIndex: $1.index,
                    geometryAdherence: request.geometryAdherence
                )
                if left != right { return left < right }
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.index < $1.index
            }
            for candidate in rankedCandidates {
                let targetIndex = candidate.index
                let lower = min(sourceIndex, targetIndex)
                let upper = max(sourceIndex, targetIndex)
                let key = (UInt64(lower) << 32) | UInt64(upper)
                guard emitted.insert(key).inserted else { continue }
                pairs.append((sourceIndex, targetIndex))
                sourceConnectionCount += 1
                if sourceConnectionCount == request.maxConnections { break }
            }
        }
        cachedConnectionRequest = request
        cachedConnectionPairs = pairs
        return cachedConnectionPairs
    }

    func glyphOwner(ofNodeAt index: Int) -> Int? {
        guard anchors.indices.contains(index) else { return nil }
        return anchors[index].glyphOwner
    }

    private func connectionScore(
        sourceIndex: Int,
        targetIndex: Int,
        geometryAdherence: Float
    ) -> Float {
        let delta = SIMD2<Float>(
            anchors[targetIndex].position.x - anchors[sourceIndex].position.x,
            anchors[targetIndex].position.z - anchors[sourceIndex].position.z
        )
        let distance = simd_length(delta)
        guard distance > 0 else { return .greatestFiniteMagnitude }
        let direction = delta / distance
        let sourceAlignment = abs(simd_dot(direction, anchors[sourceIndex].tangent))
        let targetAlignment = abs(simd_dot(direction, anchors[targetIndex].tangent))
        let confidenceSum = anchors[sourceIndex].tangentConfidence + anchors[targetIndex].tangentConfidence
        let alignmentPenalty: Float
        if confidenceSum > 0.15 {
            alignmentPenalty = (
                (1 - sourceAlignment) * anchors[sourceIndex].tangentConfidence
                    + (1 - targetAlignment) * anchors[targetIndex].tangentConfidence
            ) / confidenceSum
        } else {
            alignmentPenalty = 0
        }
        let distanceScore = distance / maximumConnectionDistance
        let crossesGlyphBoundary = anchors[sourceIndex].glyphOwner != anchors[targetIndex].glyphOwner
        let ownershipPenalty: Float = crossesGlyphBoundary ? 2 : 0
        return distanceScore * (1 - geometryAdherence)
            + alignmentPenalty * geometryAdherence
            + ownershipPenalty
    }

    private static func makeProfile(
        text: String,
        nodesPerCharacter: Int,
        textScale: Float
    ) -> GeneratedProfile {
        let font = NSFont.systemFont(ofSize: 260, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        let canvas = NSSize(
            width: max(240, ceil(measured.width + 120)),
            height: 520
        )
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width),
            pixelsHigh: Int(canvas.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()

        let finalAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let finalSize = (text as NSString).size(withAttributes: finalAttributes)
        let drawOrigin = NSPoint(
            x: (canvas.width - finalSize.width) * 0.5,
            y: (canvas.height - finalSize.height) * 0.5
        )
        let textLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: finalAttributes)
        )
        let glyphIntervals = makeGlyphIntervals(for: textLine)
        (text as NSString).draw(
            at: drawOrigin,
            withAttributes: finalAttributes
        )
        NSGraphicsContext.restoreGraphicsState()

        let gridStep = 3
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let data = bitmap.bitmapData!
        var samples: [RasterSample] = []
        for y in Swift.stride(from: 0, to: height, by: gridStep) {
            for x in Swift.stride(from: 0, to: width, by: gridStep) {
                let offset = y * bitmap.bytesPerRow + x * 4
                guard data[offset + 3] > 96 else { continue }
                let seed = Float((x &* 73856093) ^ (y &* 19349663))
                let localX = CGFloat(x) - drawOrigin.x
                samples.append(RasterSample(
                    x: x,
                    y: y,
                    seed: seed,
                    glyphOwner: glyphOwner(at: localX, intervals: glyphIntervals)
                ))
            }
        }
        let characterCount = max(1, text.count { !$0.isWhitespace })
        let requestedNodeCount = min(24_000, max(1, nodesPerCharacter) * characterCount)
        let targetCount = min(requestedNodeCount, samples.count)
        let selectedSamples: [RasterSample]
        if targetCount < samples.count {
            let selectionStep = Double(samples.count) / Double(targetCount)
            selectedSamples = (0..<targetCount).map {
                samples[min(samples.count - 1, Int(Double($0) * selectionStep))]
            }
        } else {
            selectedSamples = samples
        }

        let cellSize = 48
        var spatialGrid: [GridCell: [Int]] = [:]
        for (index, sample) in selectedSamples.enumerated() {
            spatialGrid[GridCell(x: sample.x / cellSize, y: sample.y / cellSize), default: []].append(index)
        }

        let worldUnitsPerPixel: Float = 3 / 1_800
        let appliedTextScale = min(max(textScale, 0.2), 2)
        let basePositions = selectedSamples.map { sample -> SIMD3<Float> in
            let jitterX = sin(sample.seed) * Float(gridStep) * 0.18
            let jitterY = cos(sample.seed * 0.73) * Float(gridStep) * 0.18
            return SIMD3<Float>(
                (Float(sample.x) + jitterX - Float(width) * 0.5) * worldUnitsPerPixel * appliedTextScale,
                0,
                -(Float(sample.y) + jitterY - Float(height) * 0.5) * worldUnitsPerPixel * appliedTextScale
            )
        }

        let tangentRadius: Float = 54
        let tangentData = selectedSamples.indices.map { index -> (SIMD2<Float>, Float) in
            let sample = selectedSamples[index]
            let cell = GridCell(x: sample.x / cellSize, y: sample.y / cellSize)
            var covarianceXX: Float = 0
            var covarianceXZ: Float = 0
            var covarianceZZ: Float = 0
            var totalWeight: Float = 0

            for cellY in (cell.y - 2)...(cell.y + 2) {
                for cellX in (cell.x - 2)...(cell.x + 2) {
                    for neighborIndex in spatialGrid[GridCell(x: cellX, y: cellY)] ?? [] where neighborIndex != index {
                        let delta = SIMD2<Float>(
                            basePositions[neighborIndex].x - basePositions[index].x,
                            basePositions[neighborIndex].z - basePositions[index].z
                        )
                        let pixelDistance = hypot(
                            Float(selectedSamples[neighborIndex].x - sample.x),
                            Float(selectedSamples[neighborIndex].y - sample.y)
                        )
                        guard pixelDistance < tangentRadius else { continue }
                        let weight = 1 - pixelDistance / tangentRadius
                        covarianceXX += delta.x * delta.x * weight
                        covarianceXZ += delta.x * delta.y * weight
                        covarianceZZ += delta.y * delta.y * weight
                        totalWeight += weight
                    }
                }
            }

            guard totalWeight > 0 else { return (SIMD2<Float>(1, 0), 0) }
            let angle = 0.5 * atan2(2 * covarianceXZ, covarianceXX - covarianceZZ)
            let trace = covarianceXX + covarianceZZ
            let difference = hypot(covarianceXX - covarianceZZ, 2 * covarianceXZ)
            let confidence = trace > 0 ? min(max(difference / trace, 0), 1) : 0
            return (SIMD2<Float>(cos(angle), sin(angle)), confidence)
        }

        let anchors = selectedSamples.indices.map { index in
            let sample = selectedSamples[index]
            return Anchor(
                position: basePositions[index],
                phaseA: sin(sample.seed * 0.00001) * .pi,
                phaseB: cos(sample.seed * 0.000013) * .pi,
                radius: 0.004 + abs(sin(sample.seed * 0.00002)) * 0.006,
                tangent: tangentData[index].0,
                tangentConfidence: tangentData[index].1,
                glyphOwner: sample.glyphOwner
            )
        }

        let maximumConnectionDistance: Float = 0.075 * appliedTextScale
        let connectionCandidates = anchors.indices.map { sourceIndex -> [(index: Int, distance: Float)] in
            let sample = selectedSamples[sourceIndex]
            let cell = GridCell(x: sample.x / cellSize, y: sample.y / cellSize)
            var candidates: [(index: Int, distance: Float)] = []

            for cellY in (cell.y - 1)...(cell.y + 1) {
                for cellX in (cell.x - 1)...(cell.x + 1) {
                    for targetIndex in spatialGrid[GridCell(x: cellX, y: cellY)] ?? [] where targetIndex != sourceIndex {
                        let delta = SIMD2<Float>(
                            anchors[targetIndex].position.x - anchors[sourceIndex].position.x,
                            anchors[targetIndex].position.z - anchors[sourceIndex].position.z
                        )
                        let distance = simd_length(delta)
                        guard distance > 0.000_001, distance < maximumConnectionDistance else { continue }
                        guard lineRemainsInsideGlyph(
                            from: selectedSamples[sourceIndex],
                            to: selectedSamples[targetIndex],
                            bitmap: bitmap
                        ) else { continue }

                        candidates.append((targetIndex, distance))
                    }
                }
            }

            return candidates
        }
        return GeneratedProfile(
            anchors: anchors,
            connectionCandidates: connectionCandidates,
            maximumConnectionDistance: maximumConnectionDistance
        )
    }

    private static func makeGlyphIntervals(for line: CTLine) -> [GlyphInterval] {
        let runs = CTLineGetGlyphRuns(line) as NSArray
        var intervals: [GlyphInterval] = []
        var owner = 0

        for case let run as CTRun in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            CTRunGetPositions(run, CFRange(location: 0, length: glyphCount), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: glyphCount), &advances)

            for glyphIndex in 0..<glyphCount {
                let start = positions[glyphIndex].x
                let end = start + advances[glyphIndex].width
                intervals.append(GlyphInterval(
                    owner: owner,
                    lowerX: min(start, end),
                    upperX: max(start, end)
                ))
                owner += 1
            }
        }
        return intervals.sorted { $0.lowerX < $1.lowerX }
    }

    private static func glyphOwner(at x: CGFloat, intervals: [GlyphInterval]) -> Int {
        intervals.min {
            let leftDistance = $0.distance(to: x)
            let rightDistance = $1.distance(to: x)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return $0.owner < $1.owner
        }?.owner ?? 0
    }

    private static func lineRemainsInsideGlyph(
        from source: RasterSample,
        to target: RasterSample,
        bitmap: NSBitmapImageRep
    ) -> Bool {
        let distance = hypot(Float(target.x - source.x), Float(target.y - source.y))
        let sampleCount = max(3, Int(ceil(distance / 3)))
        let data = bitmap.bitmapData!
        var outsideCount = 0

        for step in 1..<sampleCount {
            let fraction = Float(step) / Float(sampleCount)
            let x = min(max(Int(round(Float(source.x) + Float(target.x - source.x) * fraction)), 0), bitmap.pixelsWide - 1)
            let y = min(max(Int(round(Float(source.y) + Float(target.y - source.y) * fraction)), 0), bitmap.pixelsHigh - 1)
            let offset = y * bitmap.bytesPerRow + x * 4
            if data[offset + 3] <= 48 {
                outsideCount += 1
                if outsideCount > max(1, sampleCount / 5) { return false }
            }
        }
        return true
    }
}
