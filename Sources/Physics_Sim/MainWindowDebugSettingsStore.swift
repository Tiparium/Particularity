import Foundation

struct MainWindowDebugSettingsSnapshot: Codable, Equatable, Sendable {
    var compassPerspectiveDistance: Double
    var compassPerspectiveStrength: Double

    static let `default` = MainWindowDebugSettingsSnapshot(
        compassPerspectiveDistance: 2.4,
        compassPerspectiveStrength: 0.65
    )
}

@MainActor
final class MainWindowDebugSettingsStore: ObservableObject {
    static let shared = MainWindowDebugSettingsStore()

    @Published private(set) var snapshot: MainWindowDebugSettingsSnapshot

    private let store = CodableDefaultsStore<MainWindowDebugSettingsSnapshot>(
        defaultsKey: "PhysicsSim.MainWindowDebugSettings.v1",
        queueLabel: "PhysicsSim.MainWindowDebugSettingsStore"
    )
    private let persistenceHandler = DeferredActionHandler()
    private let persistDelay: TimeInterval = 0.2

    init() {
        self.snapshot = store.load(fallback: .default)
    }

    func setCompassPerspectiveDistance(_ nextValue: Double) {
        guard abs(snapshot.compassPerspectiveDistance - nextValue) > 0.0005 else { return }
        snapshot.compassPerspectiveDistance = nextValue
        schedulePersistence()
    }

    func setCompassPerspectiveStrength(_ nextValue: Double) {
        guard abs(snapshot.compassPerspectiveStrength - nextValue) > 0.0005 else { return }
        snapshot.compassPerspectiveStrength = nextValue
        schedulePersistence()
    }

    func flushPersistence() {
        persistenceHandler.flush {
            self.store.save(self.snapshot)
        }
    }

    private func schedulePersistence() {
        persistenceHandler.schedule(after: persistDelay) {
            self.store.save(self.snapshot)
        }
    }
}
