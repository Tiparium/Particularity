import Foundation
import Testing
@testable import Particularity

@Suite("ML playback runtime")
struct MLPlaybackRuntimeTests {
    @Test("loads local derived fixture when present")
    func loadsLocalDerivedFixtureWhenPresent() {
        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(MLPlaybackRuntime.fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return
        }

        let runtime = MLPlaybackRuntime()
        let frame = runtime?.frame(at: 0)

        #expect(runtime != nil)
        #expect(runtime?.timeline.durationSeconds ?? 0 > 0)
        #expect(runtime?.timeline.sampleCount ?? 0 > 0)
        #expect(frame?.particles.isEmpty == false)
    }
}
