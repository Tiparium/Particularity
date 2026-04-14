import Foundation

struct DiagnosticsNotification: Identifiable, Equatable {
    enum Severity: Equatable {
        case info
        case warning
        case error
    }

    let id = UUID()
    let severity: Severity
    let title: String
    let message: String
    let createdAt = Date()
}

@MainActor
final class MainWindowDiagnosticsStore: ObservableObject {
    static let shared = MainWindowDiagnosticsStore()

    @Published private(set) var performanceMetrics = SimulationPerformanceMetrics()
    @Published private(set) var viewportRuntimeError: String?
    @Published private(set) var leaderCommunicationLogEntries: [LeaderCommunicationLogEntry] = []
    @Published private(set) var notifications: [DiagnosticsNotification] = []

    func updatePerformanceMetrics(_ nextMetrics: SimulationPerformanceMetrics) {
        performanceMetrics = nextMetrics
    }

    func updateViewportRuntimeError(_ nextError: String?) {
        viewportRuntimeError = nextError
    }

    func updateLeaderCommunicationLogEntries(_ nextEntries: [LeaderCommunicationLogEntry]) {
        leaderCommunicationLogEntries = nextEntries
    }

    func postNotification(severity: DiagnosticsNotification.Severity, title: String, message: String) {
        notifications.insert(
            DiagnosticsNotification(severity: severity, title: title, message: message),
            at: 0
        )
        notifications = Array(notifications.prefix(8))
    }

    func dismissNotification(id: DiagnosticsNotification.ID) {
        notifications.removeAll { $0.id == id }
    }

    func dismissAllNotifications() {
        notifications.removeAll()
    }

    func resetViewportDiagnostics() {
        performanceMetrics = SimulationPerformanceMetrics()
        viewportRuntimeError = nil
        leaderCommunicationLogEntries = []
    }
}
