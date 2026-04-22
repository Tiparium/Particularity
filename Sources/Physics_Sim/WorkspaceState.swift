import Foundation
import simd

struct SceneObjectState: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var kind: String

    init(id: UUID = UUID(), name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

struct SceneState: Codable, Equatable, Sendable {
    var objects: [SceneObjectState] = []
}

struct ViewportState: Codable, Equatable, Sendable {
    var camera: ViewportCameraState = ViewportCameraState()
    var slowRotationEnabled = false

    private enum CodingKeys: String, CodingKey {
        case camera
    }

    init(camera: ViewportCameraState = ViewportCameraState(), slowRotationEnabled: Bool = false) {
        self.camera = camera
        self.slowRotationEnabled = slowRotationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        camera = try container.decodeIfPresent(ViewportCameraState.self, forKey: .camera) ?? ViewportCameraState()
        slowRotationEnabled = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(camera, forKey: .camera)
    }
}

extension ViewportCameraState {
    func isMeaningfullyDifferent(from other: ViewportCameraState) -> Bool {
        abs(yaw - other.yaw) > 0.0005
            || abs(pitch - other.pitch) > 0.0005
            || simd_length(position - other.position) > 0.0005
    }
}

struct MainWindowWorkspaceStateSnapshot: Codable, Equatable, Sendable {
    var viewportState: ViewportState = ViewportState()
    var sceneState: SceneState = SceneState()
}

@MainActor
final class MainWindowWorkspaceStateStore {
    static let shared = MainWindowWorkspaceStateStore()

    private let store = CodableDefaultsStore<MainWindowWorkspaceStateSnapshot>(
        defaultsKey: "PhysicsSim.MainWindowWorkspaceState.v1",
        queueLabel: "PhysicsSim.MainWindowWorkspaceStateStore"
    )

    func load() -> MainWindowWorkspaceStateSnapshot {
        store.load(fallback: MainWindowWorkspaceStateSnapshot())
    }

    func save(_ snapshot: MainWindowWorkspaceStateSnapshot) {
        store.save(snapshot)
    }
}

@MainActor
final class MainWindowViewportStateStore: ObservableObject {
    static let shared = MainWindowViewportStateStore()

    @Published private(set) var viewportState: ViewportState
    private(set) var sceneState: SceneState

    private let workspacePersistenceHandler = DeferredActionHandler()
    private let persistDelay: TimeInterval = 0.2

    init() {
        let snapshot = MainWindowWorkspaceStateStore.shared.load()
        self.viewportState = snapshot.viewportState
        self.sceneState = snapshot.sceneState
    }

    func updateViewportState(_ nextState: ViewportState) {
        viewportState = nextState
        schedulePersistence()
    }

    func updateLiveCameraState(_ nextState: ViewportCameraState) {
        applyCameraState(nextState)
    }

    func checkpointCameraState(_ nextState: ViewportCameraState) {
        applyCameraState(nextState)
        schedulePersistence()
    }

    func setCameraMode(_ mode: ViewportCameraMode) {
        guard viewportState.camera.mode != mode else { return }
        var nextCameraState = viewportState.camera
        nextCameraState.mode = mode
        applyCameraState(nextCameraState)
    }

    func setCameraMovementSpeed(_ speed: Float) {
        let clampedSpeed = CameraMath.clampMovementSpeed(speed)
        guard abs(viewportState.camera.movementSpeed - clampedSpeed) > 0.0005 else { return }
        var nextCameraState = viewportState.camera
        nextCameraState.movementSpeed = clampedSpeed
        applyCameraState(nextCameraState)
    }

    func setSlowRotationEnabled(_ isEnabled: Bool) {
        guard viewportState.slowRotationEnabled != isEnabled else { return }
        var nextViewportState = viewportState
        nextViewportState.slowRotationEnabled = isEnabled
        viewportState = nextViewportState
        schedulePersistence()
    }

    func updateSceneState(_ nextState: SceneState) {
        sceneState = nextState
        schedulePersistence()
    }

    func flushPersistence() {
        workspacePersistenceHandler.flush {
            self.persist()
        }
    }

    private func schedulePersistence() {
        workspacePersistenceHandler.schedule(after: persistDelay) {
            self.persist()
        }
    }

    private func applyCameraState(_ nextState: ViewportCameraState) {
        var nextViewportState = viewportState
        nextViewportState.camera = nextState
        viewportState = nextViewportState
    }

    private func persist() {
        MainWindowWorkspaceStateStore.shared.save(
            MainWindowWorkspaceStateSnapshot(
                viewportState: viewportState,
                sceneState: sceneState
            )
        )
    }
}
