import Foundation
import Testing
@testable import Particularity

@Suite("Toy playback runtime")
struct ToyPlaybackRuntimeTests {
    @Test("keeps frame time continuous while reporting nearest sample")
    func keepsFrameTimeContinuousWhileReportingNearestSample() {
        let runtime = ToyPlaybackRuntime()
        let frame = runtime.frame(at: 1.0 / 60.0)

        #expect(frame.timeSeconds == 1.0 / 60.0)
        #expect(frame.sampleIndex == 0)
        #expect(frame.particles.isEmpty == false)
    }
}
