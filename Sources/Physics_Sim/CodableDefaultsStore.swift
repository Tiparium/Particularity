import Foundation

final class CodableDefaultsStore<Snapshot: Codable & Sendable> {
    private let defaultsKey: String
    private let queue: DispatchQueue

    init(defaultsKey: String, queueLabel: String) {
        self.defaultsKey = defaultsKey
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    func load(fallback: Snapshot) -> Snapshot {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return fallback
        }
        return snapshot
    }

    func save(_ snapshot: Snapshot) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: self.defaultsKey)
        }
    }
}
