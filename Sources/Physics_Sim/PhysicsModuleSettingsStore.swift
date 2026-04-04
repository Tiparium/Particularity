import Foundation

struct MainWindowPhysicsModuleSettingsSnapshot: Codable, Equatable, Sendable {
    var blobsByModuleName: [String: String] = [:]
}

@MainActor
final class MainWindowPhysicsModuleSettingsStore: ObservableObject {
    static let shared = MainWindowPhysicsModuleSettingsStore()

    @Published private(set) var snapshot: MainWindowPhysicsModuleSettingsSnapshot

    private let store = CodableDefaultsStore<MainWindowPhysicsModuleSettingsSnapshot>(
        defaultsKey: "PhysicsSim.MainWindowPhysicsModuleSettings.v1",
        queueLabel: "PhysicsSim.MainWindowPhysicsModuleSettingsStore"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        self.snapshot = store.load(fallback: MainWindowPhysicsModuleSettingsSnapshot())
    }

    func decodeSettings<T: Codable>(for moduleName: String, fallback: T) -> T {
        guard let blob = snapshot.blobsByModuleName[moduleName],
              let data = blob.data(using: .utf8),
              let decoded = try? decoder.decode(T.self, from: data) else {
            return fallback
        }
        return decoded
    }

    func updateSettings<T: Codable>(_ settings: T, for moduleName: String) {
        guard let data = try? encoder.encode(settings),
              let blob = String(data: data, encoding: .utf8) else {
            return
        }

        var nextSnapshot = snapshot
        nextSnapshot.blobsByModuleName[moduleName] = blob
        snapshot = nextSnapshot
        store.save(nextSnapshot)
    }
}
