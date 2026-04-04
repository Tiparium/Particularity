import Foundation

@MainActor
final class MainWindowDiagnosticsStore: ObservableObject {
    static let shared = MainWindowDiagnosticsStore()

    @Published private(set) var performanceMetrics = SimulationPerformanceMetrics()
    @Published private(set) var viewportRuntimeError: String?
    @Published private(set) var leaderCommunicationLogEntries: [LeaderCommunicationLogEntry] = []

    func updatePerformanceMetrics(_ nextMetrics: SimulationPerformanceMetrics) {
        performanceMetrics = nextMetrics
    }

    func updateViewportRuntimeError(_ nextError: String?) {
        viewportRuntimeError = nextError
    }

    func updateLeaderCommunicationLogEntries(_ nextEntries: [LeaderCommunicationLogEntry]) {
        leaderCommunicationLogEntries = nextEntries
    }

    func resetViewportDiagnostics() {
        performanceMetrics = SimulationPerformanceMetrics()
        viewportRuntimeError = nil
        leaderCommunicationLogEntries = []
    }
}
