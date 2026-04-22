import Foundation

enum DockZone: String, CaseIterable, Identifiable, Codable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left Panel"
        case .center: return "Center"
        case .right: return "Right Panel"
        }
    }
}

struct DockPanel: Identifiable, Codable, Equatable {
    let id: UUID
    let type: DockPanelType
    var zone: DockZone
}

struct MainWindowChromeStateSnapshot: Codable, Equatable, Sendable {
    var panels: [DockPanel]
    var collapsedPanelIDs: [UUID]
    var selectedFileID: String?
    var leftPanelVisible: Bool
    var rightPanelVisible: Bool
    var bottomPanelVisible: Bool
    var leftDockWidth: Double?
    var rightDockWidth: Double?
    var centerDockHeight: Double?

    private enum CodingKeys: String, CodingKey {
        case panels
        case collapsedPanelIDs
        case selectedFileID
        case sidePanelsVisible
        case leftPanelVisible
        case rightPanelVisible
        case bottomPanelVisible
        case leftDockWidth
        case rightDockWidth
        case centerDockHeight
    }

    static let currentDefaultPanels: [DockPanel] = DockPanelRegistry.defaultPanels

    static let `default` = MainWindowChromeStateSnapshot(
        panels: currentDefaultPanels,
        collapsedPanelIDs: [],
        selectedFileID: nil,
        leftPanelVisible: true,
        rightPanelVisible: true,
        bottomPanelVisible: true,
        leftDockWidth: 280,
        rightDockWidth: 280,
        centerDockHeight: 240
    )

    static let legacyDefaultLayoutSignature: Set<String> = [
        "moduleSlots:left",
        "physicsSettings:left",
        "visualSettings:left",
        "optimizationSettings:left",
        "inspector:center",
    ]

    static let fileBrowserDefaultLayoutSignature: Set<String> = [
        "moduleSlots:left",
        "inspector:center",
        "fileView:right",
    ]

    static let currentDefaultLayoutSignature: Set<String> = layoutSignature(for: currentDefaultPanels)

    static func layoutSignature(for panels: [DockPanel]) -> Set<String> {
        Set(panels.map { "\($0.type.rawValue):\($0.zone.rawValue)" })
    }

    func normalized() -> MainWindowChromeStateSnapshot {
        var next = self
        next.panels = next.panels.filter { DockPanelRegistry.definition(for: $0.type) != nil }
        let signature = Self.layoutSignature(for: next.panels)

        if next.panels.isEmpty
            || signature == Self.legacyDefaultLayoutSignature
            || signature == Self.fileBrowserDefaultLayoutSignature {
            next.panels = Self.currentDefaultPanels
        }

        let livePanelIDs = Set(next.panels.map(\.id))
        next.collapsedPanelIDs = next.collapsedPanelIDs.filter { livePanelIDs.contains($0) }
        return next
    }

    init(
        panels: [DockPanel],
        collapsedPanelIDs: [UUID],
        selectedFileID: String?,
        leftPanelVisible: Bool,
        rightPanelVisible: Bool,
        bottomPanelVisible: Bool,
        leftDockWidth: Double?,
        rightDockWidth: Double?,
        centerDockHeight: Double?
    ) {
        self.panels = panels
        self.collapsedPanelIDs = collapsedPanelIDs
        self.selectedFileID = selectedFileID
        self.leftPanelVisible = leftPanelVisible
        self.rightPanelVisible = rightPanelVisible
        self.bottomPanelVisible = bottomPanelVisible
        self.leftDockWidth = leftDockWidth
        self.rightDockWidth = rightDockWidth
        self.centerDockHeight = centerDockHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panels = try container.decode([DockPanel].self, forKey: .panels)
        collapsedPanelIDs = try container.decodeIfPresent([UUID].self, forKey: .collapsedPanelIDs) ?? []
        selectedFileID = try container.decodeIfPresent(String.self, forKey: .selectedFileID)

        let legacySidePanelsVisible = try container.decodeIfPresent(Bool.self, forKey: .sidePanelsVisible)
        leftPanelVisible = try container.decodeIfPresent(Bool.self, forKey: .leftPanelVisible) ?? legacySidePanelsVisible ?? true
        rightPanelVisible = try container.decodeIfPresent(Bool.self, forKey: .rightPanelVisible) ?? legacySidePanelsVisible ?? true
        bottomPanelVisible = try container.decodeIfPresent(Bool.self, forKey: .bottomPanelVisible) ?? true

        leftDockWidth = try container.decodeIfPresent(Double.self, forKey: .leftDockWidth)
        rightDockWidth = try container.decodeIfPresent(Double.self, forKey: .rightDockWidth)
        centerDockHeight = try container.decodeIfPresent(Double.self, forKey: .centerDockHeight)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(panels, forKey: .panels)
        try container.encode(collapsedPanelIDs, forKey: .collapsedPanelIDs)
        try container.encodeIfPresent(selectedFileID, forKey: .selectedFileID)
        try container.encode(leftPanelVisible, forKey: .leftPanelVisible)
        try container.encode(rightPanelVisible, forKey: .rightPanelVisible)
        try container.encode(bottomPanelVisible, forKey: .bottomPanelVisible)
        try container.encodeIfPresent(leftDockWidth, forKey: .leftDockWidth)
        try container.encodeIfPresent(rightDockWidth, forKey: .rightDockWidth)
        try container.encodeIfPresent(centerDockHeight, forKey: .centerDockHeight)
    }
}

@MainActor
final class MainWindowChromeStateStore: ObservableObject {
    static let shared = MainWindowChromeStateStore()

    @Published private(set) var panels: [DockPanel]
    @Published private(set) var collapsedPanelIDs: Set<UUID>
    @Published private(set) var selectedFileID: String?
    @Published private(set) var leftPanelVisible: Bool
    @Published private(set) var rightPanelVisible: Bool
    @Published private(set) var bottomPanelVisible: Bool

    private var leftDockWidth: Double?
    private var rightDockWidth: Double?
    private var centerDockHeight: Double?

    private let store = CodableDefaultsStore<MainWindowChromeStateSnapshot>(
        defaultsKey: "PhysicsSim.MainWindowChromeState.v1",
        queueLabel: "PhysicsSim.MainWindowChromeStateStore"
    )
    private let persistenceHandler = DeferredActionHandler()
    private let persistDelay: TimeInterval = 0.2

    init() {
        let snapshot = store.load(fallback: .default).normalized()
        self.panels = snapshot.panels
        self.collapsedPanelIDs = Set(snapshot.collapsedPanelIDs)
        self.selectedFileID = snapshot.selectedFileID
        self.leftPanelVisible = snapshot.leftPanelVisible
        self.rightPanelVisible = snapshot.rightPanelVisible
        self.bottomPanelVisible = snapshot.bottomPanelVisible
        self.leftDockWidth = snapshot.leftDockWidth
        self.rightDockWidth = snapshot.rightDockWidth
        self.centerDockHeight = snapshot.centerDockHeight
    }

    func addPanel(type: DockPanelType, to zone: DockZone) {
        guard DockPanelRegistry.definition(for: type) != nil else { return }
        panels.append(DockPanel(id: UUID(), type: type, zone: zone))
        schedulePersistence()
    }

    func removePanel(id: UUID) {
        panels.removeAll { $0.id == id }
        collapsedPanelIDs.remove(id)
        schedulePersistence()
    }

    func movePanel(id: UUID, to zone: DockZone, at insertionIndex: Int?) {
        guard let sourceIndex = panels.firstIndex(where: { $0.id == id }) else { return }
        var moved = panels.remove(at: sourceIndex)
        moved.zone = zone

        let destinationCandidates = panels.enumerated().compactMap { pair -> Int? in
            pair.element.zone == zone ? pair.offset : nil
        }
        let indexInZone = min(max(insertionIndex ?? destinationCandidates.count, 0), destinationCandidates.count)

        if destinationCandidates.isEmpty {
            panels.append(moved)
        } else if indexInZone >= destinationCandidates.count {
            panels.insert(moved, at: destinationCandidates.last! + 1)
        } else {
            panels.insert(moved, at: destinationCandidates[indexInZone])
        }

        schedulePersistence()
    }

    func setPanelCollapsed(_ id: UUID, isCollapsed: Bool) {
        if isCollapsed {
            collapsedPanelIDs.insert(id)
        } else {
            collapsedPanelIDs.remove(id)
        }
        schedulePersistence()
    }

    func setSelectedFileID(_ nextID: String?) {
        guard selectedFileID != nextID else { return }
        selectedFileID = nextID
        schedulePersistence()
    }

    var anyDockPanelsVisible: Bool {
        leftPanelVisible || rightPanelVisible || bottomPanelVisible
    }

    func toggleAllDockPanelsVisibility() {
        let shouldShowAll = !anyDockPanelsVisible
        leftPanelVisible = shouldShowAll
        rightPanelVisible = shouldShowAll
        bottomPanelVisible = shouldShowAll
        schedulePersistence()
    }

    func toggleLeftPanelVisibility() {
        leftPanelVisible.toggle()
        schedulePersistence()
    }

    func toggleRightPanelVisibility() {
        rightPanelVisible.toggle()
        schedulePersistence()
    }

    func toggleBottomPanelVisibility() {
        bottomPanelVisible.toggle()
        schedulePersistence()
    }

    func ensureSelectedFileID(availableFiles: [ModuleFile]) {
        let availableIDs = Set(availableFiles.map(\.id))
        let nextID: String?
        if let selectedFileID, availableIDs.contains(selectedFileID) {
            nextID = selectedFileID
        } else {
            nextID = availableFiles.first?.id
        }
        setSelectedFileID(nextID)
    }

    func savedLeftDockWidth(fallback: CGFloat) -> CGFloat {
        CGFloat(leftDockWidth ?? Double(fallback))
    }

    func savedRightDockWidth(fallback: CGFloat) -> CGFloat {
        CGFloat(rightDockWidth ?? Double(fallback))
    }

    func savedCenterDockHeight(fallback: CGFloat) -> CGFloat {
        CGFloat(centerDockHeight ?? Double(fallback))
    }

    func setSideDockWidths(left: CGFloat, right: CGFloat) {
        leftDockWidth = Double(left)
        rightDockWidth = Double(right)
        schedulePersistence()
    }

    func setCenterDockHeight(_ height: CGFloat) {
        centerDockHeight = Double(height)
        schedulePersistence()
    }

    func flushPersistence() {
        persistenceHandler.flush {
            self.persist()
        }
    }

    private func schedulePersistence() {
        persistenceHandler.schedule(after: persistDelay) {
            self.persist()
        }
    }

    private func persist() {
        store.save(
            MainWindowChromeStateSnapshot(
                panels: panels,
                collapsedPanelIDs: Array(collapsedPanelIDs),
                selectedFileID: selectedFileID,
                leftPanelVisible: leftPanelVisible,
                rightPanelVisible: rightPanelVisible,
                bottomPanelVisible: bottomPanelVisible,
                leftDockWidth: leftDockWidth,
                rightDockWidth: rightDockWidth,
                centerDockHeight: centerDockHeight
            )
        )
    }
}
