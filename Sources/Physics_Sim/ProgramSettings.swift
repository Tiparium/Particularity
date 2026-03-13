import Foundation

enum ProgramSettingID: String, CaseIterable, Identifiable {
    case invertScrollZoom
    case orbitInputMode
    case uiPanelDragInputMode
    case targetUPS
    case shortcutProfile
    case showInteractionDebugOverlays
    case memoryBudgetPreset

    var id: String { rawValue }
}

struct ProgramSettingCandidate: Identifiable {
    let id: ProgramSettingID
    let title: String
    let description: String
}

enum ProgramSettingsCatalog {
    // Seed list for future app-level settings menu.
    static let candidates: [ProgramSettingCandidate] = [
        ProgramSettingCandidate(
            id: .invertScrollZoom,
            title: "Invert Scroll Zoom",
            description: "Flip trackpad/mouse scroll zoom direction."
        ),
        ProgramSettingCandidate(
            id: .orbitInputMode,
            title: "Orbit Input Mode",
            description: "Choose click-and-drag or click-then-drag camera orbit behavior."
        ),
        ProgramSettingCandidate(
            id: .uiPanelDragInputMode,
            title: "UI Panel Drag Input Mode",
            description: "Choose click-and-drag or click-then-drag behavior for moving dock panels."
        ),
        ProgramSettingCandidate(
            id: .targetUPS,
            title: "Target UPS / FPS",
            description: "Set unified simulation + render update rate."
        ),
        ProgramSettingCandidate(
            id: .shortcutProfile,
            title: "Keyboard Shortcuts",
            description: "Customize pause/reset/camera and tool hotkeys."
        ),
        ProgramSettingCandidate(
            id: .showInteractionDebugOverlays,
            title: "Interaction Debug Overlays",
            description: "Toggle visualization overlays for optimization behavior."
        ),
        ProgramSettingCandidate(
            id: .memoryBudgetPreset,
            title: "Memory Budget Preset",
            description: "Select M1/M1 Pro style memory budget defaults."
        ),
    ]
}

enum ProgramSettingsStore {
    enum DragInputMode: String, CaseIterable, Identifiable {
        case clickAndDrag
        case clickThenDrag

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clickAndDrag: return "Click and Drag"
            case .clickThenDrag: return "Click Then Drag"
            }
        }
    }

    typealias OrbitInputMode = DragInputMode
    typealias UIPanelDragInputMode = DragInputMode

    private enum Key {
        static let invertScrollZoom = "settings.viewport.invertScrollZoom"
        static let orbitInputMode = "settings.viewport.orbitInputMode"
        static let uiPanelDragInputMode = "settings.ui.panelDragInputMode"
        static let memoryBudgetPreset = "settings.sim.memoryBudgetPreset"
    }

    static var invertScrollZoom: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Key.invertScrollZoom) == nil {
                return true
            }
            return defaults.bool(forKey: Key.invertScrollZoom)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.invertScrollZoom) }
    }

    static var orbitInputMode: OrbitInputMode {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: Key.orbitInputMode),
                  let mode = DragInputMode(rawValue: raw) else {
                // Flipped default per request.
                return .clickThenDrag
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.orbitInputMode) }
    }

    static var uiPanelDragInputMode: UIPanelDragInputMode {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: Key.uiPanelDragInputMode),
                  let mode = DragInputMode(rawValue: raw) else {
                // Flipped default per request.
                return .clickThenDrag
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.uiPanelDragInputMode) }
    }

    static var memoryBudgetPreset: MemoryBudgetPreset {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: Key.memoryBudgetPreset),
                  let preset = MemoryBudgetPreset(rawValue: raw) else {
                return .m1Pro
            }
            return preset
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.memoryBudgetPreset) }
    }
}
