import SwiftUI
import UniformTypeIdentifiers
import Foundation
import AppKit

private enum DockZone: String, CaseIterable, Identifiable, Codable {
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

private enum DockPanelType: String, CaseIterable, Codable {
    case moduleSlots
    case physicsSettings
    case visualSettings
    case optimizationSettings
    case fileView
    case inspector

    var title: String {
        switch self {
        case .moduleSlots: return "Module Slots"
        case .physicsSettings: return "Physics Settings"
        case .visualSettings: return "Visual Settings"
        case .optimizationSettings: return "Optimization Settings"
        case .fileView: return "File View"
        case .inspector: return "Debug Inspector"
        }
    }

    var subtype: DockPanelSubtype {
        switch self {
        case .moduleSlots, .physicsSettings, .visualSettings, .optimizationSettings, .fileView:
            return .core
        case .inspector:
            return .diagnostics
        }
    }
}

private enum DockPanelSubtype: String, CaseIterable, Identifiable {
    case core
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: return "Core"
        case .diagnostics: return "Diagnostics"
        }
    }
}

private struct DockPanel: Identifiable, Codable, Equatable {
    let id: UUID
    let type: DockPanelType
    var zone: DockZone
}

private struct DockPanelPreview: Identifiable {
    let id: UUID
    let panel: DockPanel
    let isGhost: Bool
    let isShifted: Bool
}

private enum HeaderControlVariant {
    case neutral
    case accent
    case destructive
}

private struct HeaderControlSurface: View {
    let iconName: String
    let variant: HeaderControlVariant
    let isHovered: Bool

    var body: some View {
        Image(systemName: iconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            )
    }

    private var foregroundColor: Color {
        switch variant {
        case .neutral:
            return isHovered ? .primary : .secondary
        case .accent:
            return isHovered ? .primary : .secondary
        case .destructive:
            return isHovered ? Color.red.opacity(0.95) : .secondary
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .neutral:
            return Color(nsColor: .quaternaryLabelColor).opacity(isHovered ? 0.24 : 0.16)
        case .accent:
            return isHovered ? Color.accentColor.opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.16)
        case .destructive:
            return isHovered ? Color.red.opacity(0.30) : Color(nsColor: .quaternaryLabelColor).opacity(0.16)
        }
    }
}

private struct HeaderControlButton: View {
    let iconName: String
    let variant: HeaderControlVariant
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderControlSurface(iconName: iconName, variant: variant, isHovered: isHovered)
        }
        .buttonStyle(.plain)
    }
}

private struct DockLayoutState: Codable {
    let panels: [DockPanel]
    let collapsedPanelIDs: [UUID]
}

private struct PanelDragSession {
    let panelID: UUID
    let mode: ProgramSettingsStore.UIPanelDragInputMode
    var pointerInRoot: CGPoint
    var hoveredZone: DockZone?
    var insertionIndexByZone: [DockZone: Int]
}

private struct DockPanelFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [DockZone: [UUID: CGRect]] = [:]

    static func reduce(value: inout [DockZone: [UUID: CGRect]], nextValue: () -> [DockZone: [UUID: CGRect]]) {
        for (zone, frames) in nextValue() {
            var existing = value[zone] ?? [:]
            for (id, frame) in frames {
                existing[id] = frame
            }
            value[zone] = existing
        }
    }
}

private struct DockZoneFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [DockZone: CGRect] = [:]

    static func reduce(value: inout [DockZone: CGRect], nextValue: () -> [DockZone: CGRect]) {
        for (zone, frame) in nextValue() {
            value[zone] = frame
        }
    }
}

private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                cursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

private extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}

private struct DockPanelDropDelegate: DropDelegate {
    let zone: DockZone
    let isHorizontal: Bool
    let panelIDsInOrder: [UUID]
    let panelFrames: [UUID: CGRect]
    @Binding var panelDragSession: PanelDragSession?
    let movePanel: (UUID, DockZone, Int?) -> Void
    let resetDragState: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard var session = panelDragSession else { return }
        session.hoveredZone = zone
        session.insertionIndexByZone[zone] = insertionIndex(for: info.location)
        panelDragSession = session
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard var session = panelDragSession else { return nil }
        session.hoveredZone = zone
        session.insertionIndexByZone[zone] = insertionIndex(for: info.location)
        panelDragSession = session
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard var session = panelDragSession else { return }
        if session.hoveredZone == zone {
            session.hoveredZone = nil
        }
        session.insertionIndexByZone[zone] = nil
        panelDragSession = session
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            resetDragState()
        }

        guard let session = panelDragSession else { return false }
        let index = session.insertionIndexByZone[zone] ?? insertionIndex(for: info.location)
        movePanel(session.panelID, zone, index)
        return true
    }

    private func insertionIndex(for location: CGPoint) -> Int {
        if panelIDsInOrder.isEmpty {
            return 0
        }

        for (index, id) in panelIDsInOrder.enumerated() {
            guard let frame = panelFrames[id] else { continue }
            let threshold = isHorizontal ? frame.midX : frame.midY
            let value = isHorizontal ? location.x : location.y
            if value < threshold {
                return index
            }
        }
        return panelIDsInOrder.count
    }
}

struct ContentView: View {
    private let dockLayoutStorageKey = "PhysicsSim.DockLayoutState.v1"
    private let particleCountEngineCap = 10_000_000
    private let particleCountUICap = 100_000
    @AppStorage("layout.dock.leftWidth") private var storedLeftDockWidth = 280.0
    @AppStorage("layout.dock.rightWidth") private var storedRightDockWidth = 280.0
    @AppStorage("layout.dock.centerHeight") private var storedCenterDockHeight = 240.0
    @State private var panels: [DockPanel] = [
        DockPanel(id: UUID(), type: .moduleSlots, zone: .left),
        DockPanel(id: UUID(), type: .inspector, zone: .center),
        DockPanel(id: UUID(), type: .physicsSettings, zone: .right),
        DockPanel(id: UUID(), type: .visualSettings, zone: .right),
        DockPanel(id: UUID(), type: .optimizationSettings, zone: .right),
    ]

    @State private var selectedFileID: String?
    @State private var isImporterPresented = false
    @State private var importerTargetKind: ModuleKind = .physics
    @State private var hoveredCollapsePanelID: UUID?
    @State private var hoveredGrabPanelID: UUID?
    @State private var hoveredClosePanelID: UUID?
    @State private var panelDragSession: PanelDragSession?
    @State private var collapsedPanelIDs: Set<UUID> = []
    @State private var menuInsertionType: DockPanelType?
    @State private var menuHoverZone: DockZone?
    @State private var panelFramesByZone: [DockZone: [UUID: CGRect]] = [:]
    @State private var zoneFramesInRoot: [DockZone: CGRect] = [:]
    @State private var viewportGeneration: Int = 0
    @State private var leftDockWidth = 280.0
    @State private var rightDockWidth = 280.0
    @State private var centerDockHeight = 240.0
    @State private var leftResizeOriginWidth: CGFloat?
    @State private var rightResizeOriginWidth: CGFloat?
    @State private var centerResizeOriginHeight: CGFloat?
    @State private var hoveredResizeAxis: DockResizeAxis?
    private let session: SimulationSession
    @ObservedObject private var editorSettingsStore: MainWindowEditorSettingsStore
    @ObservedObject private var moduleCatalogStore: MainWindowModuleCatalogStore
    @ObservedObject private var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    @ObservedObject private var diagnosticsStore: MainWindowDiagnosticsStore
    @ObservedObject private var interactionSnapshotRecorder: InteractionSnapshotRecorder
    @ObservedObject private var performanceReviewLogger: PerformanceReviewLogger

    init() {
        do {
            let session = try WindowSimulationSessionStore.shared.mainWindowSession()
            self.session = session
            _editorSettingsStore = ObservedObject(
                wrappedValue: WindowSimulationSessionStore.shared.mainWindowEditorSettingsStore()
            )
            _moduleCatalogStore = ObservedObject(
                wrappedValue: WindowSimulationSessionStore.shared.mainWindowModuleCatalogStore()
            )
            _runtimeConfigCoordinator = ObservedObject(
                wrappedValue: try WindowSimulationSessionStore.shared.mainWindowRuntimeConfigCoordinator()
            )
            _diagnosticsStore = ObservedObject(
                wrappedValue: WindowSimulationSessionStore.shared.mainWindowDiagnosticsStore()
            )
            _interactionSnapshotRecorder = ObservedObject(
                wrappedValue: InteractionSnapshotRecorder.shared
            )
            _performanceReviewLogger = ObservedObject(
                wrappedValue: PerformanceReviewLogger.shared
            )
        } catch {
            fatalError("Failed to create main window simulation session: \(error.localizedDescription)")
        }
    }

    private var defaultPanels: [DockPanel] {
        [
            DockPanel(id: UUID(), type: .moduleSlots, zone: .left),
            DockPanel(id: UUID(), type: .inspector, zone: .center),
            DockPanel(id: UUID(), type: .physicsSettings, zone: .right),
            DockPanel(id: UUID(), type: .visualSettings, zone: .right),
            DockPanel(id: UUID(), type: .optimizationSettings, zone: .right),
        ]
    }

    private var legacyDefaultLayoutSignature: Set<String> {
        [
            "moduleSlots:left",
            "physicsSettings:left",
            "visualSettings:left",
            "optimizationSettings:left",
            "inspector:center",
        ]
    }

    private var fileBrowserDefaultLayoutSignature: Set<String> {
        [
            "moduleSlots:left",
            "inspector:center",
            "fileView:right",
        ]
    }

    private var currentDefaultLayoutSignature: Set<String> {
        [
            "moduleSlots:left",
            "inspector:center",
            "physicsSettings:right",
            "visualSettings:right",
            "optimizationSettings:right",
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let maxSideWidth = max(260, min(460, geo.size.width * 0.35))
            let maxCenterDockHeight = max(200, min(420, geo.size.height * 0.45))

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                HSplitView {
                    dockColumn(.left)
                        .frame(
                            minWidth: 220,
                            idealWidth: min(max(CGFloat(storedLeftDockWidth), 220), maxSideWidth),
                            maxWidth: maxSideWidth
                        )

                    centerColumn(maxCenterDockHeight: maxCenterDockHeight)
                        .frame(maxWidth: .infinity)

                    dockColumn(.right)
                        .frame(
                            minWidth: 220,
                            idealWidth: min(max(CGFloat(storedRightDockWidth), 220), maxSideWidth),
                            maxWidth: maxSideWidth
                        )
                }
                .padding(12)

                if ProgramSettingsStore.uiPanelDragInputMode == .clickThenDrag,
                   panelDragSession?.mode == .clickThenDrag,
                   let draggingPanel = currentlyDraggingPanel {
                    dragPreview(for: draggingPanel)
                        .position(
                            x: (panelDragSession?.pointerInRoot.x ?? 0) + 120,
                            y: (panelDragSession?.pointerInRoot.y ?? 0) + 22
                        )
                        .allowsHitTesting(false)
                        .zIndex(1000)
                }

                if panelDragSession?.mode == .clickThenDrag {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleClickThenDragTap()
                        }
                        .zIndex(999)
                }
            }
            .coordinateSpace(name: "root-space")
            .onContinuousHover { phase in
                guard var session = panelDragSession else { return }
                if case let .active(location) = phase {
                    session.pointerInRoot = location
                    panelDragSession = session
                    if session.mode == .clickThenDrag {
                        updateClickThenDragHover(at: location)
                    }
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    if menuInsertionType != nil, menuHoverZone == nil {
                        cancelMenuInsertionMode()
                    }
                }
            )
        }
        .onAppear {
            loadDockLayoutState()
            moduleCatalogStore.refresh()
            syncSelectedFileSelection()
            PerformanceReviewLogger.shared.configure(
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                snapshotProvider: makePerformanceReviewSample
            )
        }
        .onAppear {
            fputs("APP_READY\n", stderr)
            fflush(stderr)
        }
        .onChange(of: panels) {
            persistDockLayoutState()
        }
        .onChange(of: collapsedPanelIDs) {
            persistDockLayoutState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddDockPanel)) { note in
            guard let raw = note.userInfo?[AppMenuEventKey.panelType] as? String,
                  let type = DockPanelType(rawValue: raw) else { return }
            menuInsertionType = type
            menuHoverZone = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelInProgressOperation)) { _ in
            cancelMenuInsertionMode()
            if panelDragSession != nil {
                resetDragState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .testingAPICommand)) { note in
            guard let command = note.object as? TestingAPICommand else { return }
            handleTestingAPICommand(command)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rebuildViewport)) { _ in
            viewportGeneration &+= 1
            diagnosticsStore.resetViewportDiagnostics()
        }
        .onChange(of: moduleCatalogStore.availableFiles) {
            syncSelectedFileSelection()
        }
        .onExitCommand {
            cancelMenuInsertionMode()
            if panelDragSession != nil {
                resetDragState()
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json, .data, .text],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                editorSettingsStore.setAssignedModulePath(url.path, for: importerTargetKind)
            }
        }
    }

    private func centerColumn(maxCenterDockHeight: CGFloat) -> some View {
        VSplitView {
            SimulationCenterPane(
                editorSettingsStore: editorSettingsStore,
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                diagnosticsStore: diagnosticsStore,
                viewportGeneration: viewportGeneration,
                debugMetricsAreVisible: debugMetricsAreVisible
            )
            .frame(minHeight: 320)

            dropZoneSurface(for: .center, panels: panelsInZone(.center))
                .frame(
                    minHeight: 180,
                    idealHeight: min(max(CGFloat(storedCenterDockHeight), 180), maxCenterDockHeight),
                    maxHeight: maxCenterDockHeight
                )
        }
    }

    private enum DockResizeAxis {
        case left
        case right
        case center
    }

    private func dockResizeHandle(_ axis: DockResizeAxis, containerSize: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: axis == .center ? nil : 8, height: axis == .center ? 8 : nil)
            .overlay {
                RoundedRectangle(cornerRadius: 999)
                    .fill((hoveredResizeAxis == axis ? Color.accentColor : Color.secondary).opacity(hoveredResizeAxis == axis ? 0.72 : 0.28))
                    .frame(width: axis == .center ? 72 : 3, height: axis == .center ? 3 : 72)
            }
            .contentShape(Rectangle())
            .hoverCursor(axis == .center ? .resizeUpDown : .resizeLeftRight)
            .onHover { hovering in
                hoveredResizeAxis = hovering ? axis : (hoveredResizeAxis == axis ? nil : hoveredResizeAxis)
            }
            .gesture(resizeGesture(for: axis, containerSize: containerSize))
    }

    private func resizeGesture(for axis: DockResizeAxis, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                switch axis {
                case .left:
                    let origin = leftResizeOriginWidth ?? clampedDockWidth(CGFloat(leftDockWidth), containerWidth: containerSize.width)
                    leftResizeOriginWidth = origin
                    leftDockWidth = Double(clampedDockWidth(origin + value.translation.width, containerWidth: containerSize.width))
                case .right:
                    let origin = rightResizeOriginWidth ?? clampedDockWidth(CGFloat(rightDockWidth), containerWidth: containerSize.width)
                    rightResizeOriginWidth = origin
                    rightDockWidth = Double(clampedDockWidth(origin - value.translation.width, containerWidth: containerSize.width))
                case .center:
                    let origin = centerResizeOriginHeight ?? clampedDockHeight(CGFloat(centerDockHeight), containerHeight: containerSize.height)
                    centerResizeOriginHeight = origin
                    centerDockHeight = Double(clampedDockHeight(origin - value.translation.height, containerHeight: containerSize.height))
                }
            }
            .onEnded { _ in
                storedLeftDockWidth = leftDockWidth
                storedRightDockWidth = rightDockWidth
                storedCenterDockHeight = centerDockHeight
                leftResizeOriginWidth = nil
                rightResizeOriginWidth = nil
                centerResizeOriginHeight = nil
            }
    }

    private func clampedDockWidth(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let maxWidth = max(260, min(460, containerWidth * 0.35))
        return min(max(width, 220), maxWidth)
    }

    private func clampedDockHeight(_ height: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let maxHeight = max(200, min(420, containerHeight * 0.45))
        return min(max(height, 180), maxHeight)
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button("Start") {
                runtimeConfigCoordinator.startSimulation()
            }
            .disabled(transportState != .stopped || !validationReport.canStart)

            Button(transportState == .running ? "Pause" : "Play") {
                runtimeConfigCoordinator.togglePausePlay()
            }
            .frame(minWidth: 64)
            .disabled(
                transportState == .stopped
                || (transportState == .paused && !validationReport.canStart)
            )

            Button("Stop") {
                runtimeConfigCoordinator.stopSimulation()
            }
            .disabled(transportState == .stopped)

            Divider()
                .frame(height: 18)

            Picker("Memory Budget", selection: Binding(
                get: { ProgramSettingsStore.memoryBudgetPreset.rawValue },
                set: {
                    guard let preset = MemoryBudgetPreset(rawValue: $0) else { return }
                    ProgramSettingsStore.memoryBudgetPreset = preset
                    runtimeConfigCoordinator.refreshDerivedState()
                }
            )) {
                ForEach(MemoryBudgetPreset.allCases) { preset in
                    Text(preset.title).tag(preset.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            Text(validationReport.canStart ? "Ready" : "Blocked")
                .font(.caption.weight(.semibold))
                .foregroundStyle(validationReport.canStart ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func dockColumn(_ zone: DockZone) -> some View {
        dropZoneSurface(for: zone, panels: panelsInZone(zone))
    }

    private func dropZoneSurface(for zone: DockZone, panels: [DockPanel]) -> some View {
        let previews = previewPanelsInZone(zone, fallback: panels)
        let isAddMode = menuInsertionType != nil
        let isDragMode = panelDragSession != nil
        let shouldTrackFrames = isDragMode
        let isDropTarget = isDragMode && panelDragSession?.hoveredZone == zone
        let zoneFrames = panelFramesByZone[zone] ?? [:]
        let dropDelegate = DockPanelDropDelegate(
            zone: zone,
            isHorizontal: zone == .center,
            panelIDsInOrder: panels.map(\.id),
            panelFrames: zoneFrames,
            panelDragSession: $panelDragSession,
            movePanel: movePanel,
            resetDragState: resetDragState
        )
        return Group {
            if zone == .center {
                VStack(alignment: .leading, spacing: 8) {
                    zoneHeader(for: zone)

                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                        ForEach(previews) { preview in
                            panelCard(preview.panel, isGhost: preview.isGhost, isShifted: preview.isShifted)
                                .frame(width: 330)
                                .background {
                                    if shouldTrackFrames && !preview.isGhost {
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: DockPanelFramesPreferenceKey.self,
                                                value: [zone: [preview.id: proxy.frame(in: .named(zone.rawValue))]]
                                            )
                                        }
                                    }
                                }
                        }

                        if previews.isEmpty {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.quaternary.opacity(0.15))
                                .overlay(
                                    Text("Drop panel here")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                )
                                .frame(width: 260, height: 80)
                        }
                        }
                        .padding(8)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    zoneHeader(for: zone)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(previews) { preview in
                            panelCard(preview.panel, isGhost: preview.isGhost, isShifted: preview.isShifted)
                                .background {
                                    if shouldTrackFrames && !preview.isGhost {
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: DockPanelFramesPreferenceKey.self,
                                                value: [zone: [preview.id: proxy.frame(in: .named(zone.rawValue))]]
                                            )
                                        }
                                    }
                                }
                        }

                        if previews.isEmpty {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.quaternary.opacity(0.15))
                                .overlay(
                                    Text("Drop panel here")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                )
                                .frame(height: 80)
                        }
                        }
                        .padding(8)
                    }
                }
            }
        }
        .scrollIndicators(.visible)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if isDropTarget || isAddMode {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        Color.accentColor.opacity(
                            isDropTarget ? 0.14 : (isAddMode ? 0.07 : 0.10)
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isDropTarget || isAddMode
                        ? Color.accentColor.opacity(0.85)
                        : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: (isDropTarget || isAddMode) ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .coordinateSpace(name: zone.rawValue)
        .onPreferenceChange(DockPanelFramesPreferenceKey.self) { framesByZone in
            if shouldTrackFrames {
                panelFramesByZone.merge(framesByZone) { _, new in new }
            }
        }
        .background {
            if shouldTrackFrames {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DockZoneFramesPreferenceKey.self,
                        value: [zone: proxy.frame(in: .named("root-space"))]
                    )
                }
            }
        }
        .onPreferenceChange(DockZoneFramesPreferenceKey.self) { framesByZone in
            if shouldTrackFrames {
                zoneFramesInRoot.merge(framesByZone) { _, new in new }
            }
        }
        .onHover { hovering in
            if isAddMode {
                if hovering {
                    menuHoverZone = zone
                } else if menuHoverZone == zone {
                    menuHoverZone = nil
                }
            }
        }
        .overlay {
            if isAddMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let insertionType = menuInsertionType {
                            addPanel(type: insertionType, to: zone)
                            cancelMenuInsertionMode()
                        }
                    }
            }
        }
        .onDrop(of: [.text], delegate: dropDelegate)
    }

    private func zoneHeader(for zone: DockZone) -> some View {
        let isPanelDragActive = panelDragSession != nil
        return HStack {
            Text(zone.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Spacer()

            Menu {
                ForEach(DockPanelSubtype.allCases) { subtype in
                    let panelTypes = DockPanelType.allCases.filter { $0.subtype == subtype }
                    if !panelTypes.isEmpty {
                        Menu(subtype.title) {
                            ForEach(panelTypes, id: \.rawValue) { type in
                                Button(type.title) {
                                    addPanel(type: type, to: zone)
                                }
                            }
                        }
                    }
                }
            } label: {
                HeaderControlSurface(
                    iconName: "plus",
                    variant: .neutral,
                    isHovered: false
                )
            }
            .menuStyle(.borderlessButton)
            .help("Add panel")
            .disabled(isPanelDragActive)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func panelCard(_ panel: DockPanel, isGhost: Bool = false, isShifted: Bool = false) -> some View {
        let isPanelDragActive = panelDragSession != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(panel.type.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isGhost ? .secondary : .primary)
                Spacer()
                if !isGhost {
                    HeaderControlButton(
                        iconName: collapsedPanelIDs.contains(panel.id) ? "chevron.down" : "chevron.up",
                        variant: .neutral,
                        isHovered: hoveredCollapsePanelID == panel.id
                    ) {
                        togglePanelCollapsed(panel.id)
                    }
                    .help(collapsedPanelIDs.contains(panel.id) ? "Expand panel" : "Collapse panel")
                    .onHover { hovering in
                        hoveredCollapsePanelID = hovering ? panel.id : (hoveredCollapsePanelID == panel.id ? nil : hoveredCollapsePanelID)
                    }
                    .disabled(isPanelDragActive)
                }
                HeaderControlSurface(
                    iconName: "hand.draw",
                    variant: .accent,
                    isHovered: hoveredGrabPanelID == panel.id
                )
                .contentShape(Rectangle())
                .opacity(isGhost ? 0.0 : 1.0)
                .allowsHitTesting(!isGhost)
                .overlay(alignment: .center) {
                    if !isGhost {
                        let uiPanelDragMode = ProgramSettingsStore.uiPanelDragInputMode
                        if uiPanelDragMode == .clickAndDrag {
                            Color.clear
                                .contentShape(Rectangle())
                                .onDrag {
                                    cancelMenuInsertionMode()
                                    resetDragState()
                                    panelDragSession = PanelDragSession(
                                        panelID: panel.id,
                                        mode: .clickAndDrag,
                                        pointerInRoot: .zero,
                                        hoveredZone: nil,
                                        insertionIndexByZone: [:]
                                    )
                                    return NSItemProvider(object: panel.id.uuidString as NSString)
                                } preview: {
                                    dragPreview(for: panel)
                                }
                        } else {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    cancelMenuInsertionMode()
                                    resetDragState()
                                    panelDragSession = PanelDragSession(
                                        panelID: panel.id,
                                        mode: .clickThenDrag,
                                        pointerInRoot: .zero,
                                        hoveredZone: nil,
                                        insertionIndexByZone: [:]
                                    )
                                }
                        }
                    }
                }
                .onHover { hovering in
                    hoveredGrabPanelID = hovering ? panel.id : (hoveredGrabPanelID == panel.id ? nil : hoveredGrabPanelID)
                }
                if !isGhost {
                    HeaderControlButton(
                        iconName: "xmark",
                        variant: .destructive,
                        isHovered: hoveredClosePanelID == panel.id
                    ) {
                        removePanel(panel.id)
                    }
                    .help("Remove panel")
                    .onHover { hovering in
                        hoveredClosePanelID = hovering ? panel.id : (hoveredClosePanelID == panel.id ? nil : hoveredClosePanelID)
                    }
                    .disabled(isPanelDragActive)
                }
            }

            if !collapsedPanelIDs.contains(panel.id) || isGhost {
                panelBodyContent(for: panel)
                .allowsHitTesting(!isPanelDragActive || isGhost)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .opacity(isGhost ? 0.50 : 1.0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isGhost ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.4),
                    style: isGhost
                        ? StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        : StrokeStyle(lineWidth: 1)
                )
        )
        .scaleEffect(isGhost ? 1.01 : 1.0)
        .offset(
            x: isShifted
                ? (panel.zone == .center ? 16 : 0)
                : 0,
            y: isShifted
                ? (panel.zone == .center ? 0 : 10)
                : 0
        )
        .animation(.easeOut(duration: 0.14), value: isShifted)
        .animation(.easeOut(duration: 0.14), value: isGhost)
    }

    @ViewBuilder
    private func panelBodyContent(for panel: DockPanel) -> some View {
        if panel.zone == .center {
            ScrollView(.vertical) {
                panelBodyCore(for: panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 14)
            }
            .scrollIndicators(.visible)
        } else {
            panelBodyCore(for: panel)
        }
    }

    @ViewBuilder
    private func panelBodyCore(for panel: DockPanel) -> some View {
        switch panel.type {
        case .moduleSlots:
            ModuleSlotsPanel(
                editorSettingsStore: editorSettingsStore,
                availableFiles: moduleCatalogStore.availableFiles,
                selectedFile: selectedFile,
                importerTargetKind: $importerTargetKind,
                isImporterPresented: $isImporterPresented
            )
        case .physicsSettings:
            ModuleSettingsPanelView(
                kind: .physics,
                editorSettingsStore: editorSettingsStore,
                availableFiles: moduleCatalogStore.availableFiles,
                particleCountUICap: particleCountUICap,
                particleCountEngineCap: particleCountEngineCap
            )
        case .visualSettings:
            ModuleSettingsPanelView(
                kind: .visual,
                editorSettingsStore: editorSettingsStore,
                availableFiles: moduleCatalogStore.availableFiles,
                particleCountUICap: particleCountUICap,
                particleCountEngineCap: particleCountEngineCap
            )
        case .optimizationSettings:
            ModuleSettingsPanelView(
                kind: .optimization,
                editorSettingsStore: editorSettingsStore,
                availableFiles: moduleCatalogStore.availableFiles,
                particleCountUICap: particleCountUICap,
                particleCountEngineCap: particleCountEngineCap
            )
        case .fileView:
            FileViewPanel(
                editorSettingsStore: editorSettingsStore,
                availableFiles: moduleCatalogStore.availableFiles,
                selectedFile: selectedFile,
                onRefresh: moduleCatalogStore.refresh
            )
        case .inspector:
            InspectorPanel(
                interactionSnapshotRecorder: interactionSnapshotRecorder,
                performanceReviewLogger: performanceReviewLogger,
                transportState: runtimeConfigCoordinator.transportState,
                validationReport: runtimeConfigCoordinator.validationReport,
                performanceMetrics: performanceMetrics,
                panelsCount: panels.count,
                collapsedPanelsCount: collapsedPanelIDs.count,
                debugMetricsAreVisible: debugMetricsAreVisible,
                viewportRuntimeError: viewportRuntimeError,
                onStartInteractionSnapshot: startInteractionSnapshotRecording,
                onSetPerformanceReviewLoggingEnabled: { performanceReviewLogger.setEnabled($0) }
            )
        }
    }

    private var inspectorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Memory Used")
                    .font(.caption)
                Spacer()
                Text(byteCountString(performanceMetrics.memoryUsedBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("FPS")
                    .font(.caption)
                Spacer()
                Text(formattedRate(performanceMetrics.averageFPS))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("UPS")
                    .font(.caption)
                Spacer()
                Text(formattedRate(performanceMetrics.averageUPS))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Leader Interactions/s")
                    .font(.caption)
                Spacer()
                Text(formattedInteractionRate(performanceMetrics.leaderInteractionsPerSecond))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Rolling average over the last \(Int(performanceMetrics.sampleWindowSeconds))s.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Text("Session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Transport")
                    .font(.caption)
                Spacer()
                Text(transportState.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Panels")
                    .font(.caption)
                Spacer()
                Text("\(panels.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Collapsed")
                    .font(.caption)
                Spacer()
                Text("\(collapsedPanelIDs.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Selected File")
                    .font(.caption)
                Spacer()
                Text(selectedFile?.url.lastPathComponent ?? "None")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Text("Drag Active")
                    .font(.caption)
                Spacer()
                Text(panelDragSession == nil ? "No" : "Yes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Resolved Modules")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(ModuleKind.allCases) { kind in
                HStack {
                    Text(kind.shortTitle)
                        .font(.caption)
                    Spacer()
                    Text(resolvedModule(for: kind).name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            Text("Validation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Projected Memory")
                    .font(.caption)
                Spacer()
                Text(byteCountString(validationReport.projectedBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Budget Preset")
                    .font(.caption)
                Spacer()
                Text(currentMemoryBudgetPreset.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let issue = viewportRuntimeError ?? validationReport.issue {
                Text(issue)
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.9))
            } else {
                Text("Configuration is valid for startup.")
                    .font(.caption2)
                    .foregroundStyle(Color.green.opacity(0.9))
            }
        }
    }

    private var selectedFile: ModuleFile? {
        guard let selectedFileID else { return nil }
        return moduleCatalogStore.availableFiles.first(where: { $0.id == selectedFileID })
    }

    private var availableFiles: [ModuleFile] {
        moduleCatalogStore.availableFiles
    }

    private var modulesRootURL: URL {
        moduleCatalogStore.modulesRootURL
    }

    private var currentMemoryBudgetPreset: MemoryBudgetPreset {
        ProgramSettingsStore.memoryBudgetPreset
    }

    private var activeModuleSet: ActiveModuleSet {
        runtimeConfigCoordinator.activeModules
    }

    private var validationReport: RuntimeValidationReport {
        runtimeConfigCoordinator.validationReport
    }

    private var performanceMetrics: SimulationPerformanceMetrics {
        diagnosticsStore.performanceMetrics
    }

    private var viewportRuntimeError: String? {
        diagnosticsStore.viewportRuntimeError
    }

    private var debugMetricsAreVisible: Bool {
        guard let inspectorPanel = panels.first(where: { $0.type == .inspector }) else { return false }
        return !collapsedPanelIDs.contains(inspectorPanel.id)
    }

    private var currentlyDraggingPanel: DockPanel? {
        guard let draggingID = panelDragSession?.panelID else { return nil }
        return panels.first(where: { $0.id == draggingID })
    }

    private func panelsInZone(_ zone: DockZone) -> [DockPanel] {
        panels.filter { $0.zone == zone }
    }

    private func addPanel(type: DockPanelType, to zone: DockZone) {
        panels.append(DockPanel(id: UUID(), type: type, zone: zone))
        interactionSnapshotRecorder.record(
            event: "ui.add_panel",
            details: [
                "type": type.rawValue,
                "zone": zone.rawValue,
            ]
        )
    }

    private func removePanel(_ id: UUID) {
        panels.removeAll { $0.id == id }
        collapsedPanelIDs.remove(id)
        interactionSnapshotRecorder.record(
            event: "ui.remove_panel",
            details: ["panelID": id.uuidString]
        )
        if panelDragSession?.panelID == id {
            resetDragState()
        }
    }

    private func togglePanelCollapsed(_ id: UUID) {
        if collapsedPanelIDs.contains(id) {
            collapsedPanelIDs.remove(id)
        } else {
            collapsedPanelIDs.insert(id)
        }
        interactionSnapshotRecorder.record(
            event: "ui.toggle_panel_collapsed",
            details: [
                "panelID": id.uuidString,
                "isCollapsed": "\(collapsedPanelIDs.contains(id))",
            ]
        )
    }

    private func movePanel(id: UUID, to zone: DockZone, at insertionIndex: Int?) {
        guard let sourceIndex = panels.firstIndex(where: { $0.id == id }) else { return }
        var moved = panels.remove(at: sourceIndex)
        moved.zone = zone

        let destinationCandidates = panels.enumerated().compactMap { pair -> Int? in
            pair.element.zone == zone ? pair.offset : nil
        }
        let indexInZone = min(max(insertionIndex ?? destinationCandidates.count, 0), destinationCandidates.count)

        if destinationCandidates.isEmpty {
            panels.append(moved)
            interactionSnapshotRecorder.record(
                event: "ui.move_panel",
                details: [
                    "panelID": id.uuidString,
                    "zone": zone.rawValue,
                    "insertionIndex": "\(insertionIndex ?? destinationCandidates.count)",
                ]
            )
            return
        }

        if indexInZone >= destinationCandidates.count {
            panels.insert(moved, at: destinationCandidates.last! + 1)
        } else {
            panels.insert(moved, at: destinationCandidates[indexInZone])
        }
        interactionSnapshotRecorder.record(
            event: "ui.move_panel",
            details: [
                "panelID": id.uuidString,
                "zone": zone.rawValue,
                "insertionIndex": "\(indexInZone)",
            ]
        )
    }

    private func dragPreview(for panel: DockPanel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(panel.type.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "hand.draw")
                    .font(.caption)
            }
            .foregroundStyle(.primary)
        }
        .padding(10)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .opacity(0.72)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
    }

    private func syncSelectedFileSelection() {
        let availableFiles = moduleCatalogStore.availableFiles
        if selectedFileID == nil || !availableFiles.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = availableFiles.first?.id
        }
    }

    private func refreshModuleFiles() {
        moduleCatalogStore.refresh()
    }

    private func handleTestingAPICommand(_ command: TestingAPICommand) {
        interactionSnapshotRecorder.record(
            event: "testing_api.command",
            details: ["command": command.rawValue]
        )
        switch command {
        case .startSimulation:
            runtimeConfigCoordinator.startSimulation()
        case .togglePausePlay:
            runtimeConfigCoordinator.togglePausePlay()
        case .stopSimulation:
            runtimeConfigCoordinator.stopSimulation()
        case .dumpState:
            RuntimeEventLogger.log(
                "testing_api dump_state transport=\(transportState.rawValue) particles=\(physicsState.particleCount) random=\(physicsState.randomDistribution) modules=physics:\(runtimeConfigCoordinator.activeModules.physics.name),visual:\(runtimeConfigCoordinator.activeModules.visual.name),optimization:\(runtimeConfigCoordinator.activeModules.optimization.name) panels=\(panels.count)"
            )
        case .closeMainWindow:
            WindowCommandCenter.shared.closeMainWindow()
        case .openMainWindow:
            WindowCommandCenter.shared.reopenMainWindow()
        }
    }

    private func startInteractionSnapshotRecording() {
        interactionSnapshotRecorder.startRecording { makeInteractionSnapshotState() }
    }

    private func makeInteractionSnapshotState() -> InteractionSnapshotState {
        let editorState = editorSettingsStore.editorState
        let sessionSimulationState = session.simulationState
        let renderState = session.renderState
        let panelStates = panels.map { panel in
            InteractionSnapshotPanelState(
                id: panel.id.uuidString,
                type: panel.type.rawValue,
                zone: panel.zone.rawValue,
                isCollapsed: collapsedPanelIDs.contains(panel.id)
            )
        }

        return InteractionSnapshotState(
            transportState: runtimeConfigCoordinator.transportState.rawValue,
            coordinatorSimulationState: InteractionSnapshotFormat.viewport(runtimeConfigCoordinator.simulationState),
            sessionSimulationState: InteractionSnapshotFormat.viewport(sessionSimulationState),
            renderState: InteractionSnapshotFormat.renderState(renderState),
            activeModules: InteractionSnapshotFormat.activeModules(runtimeConfigCoordinator.activeModules),
            editorPhysicsState: InteractionSnapshotFormat.physics(editorState.physicsState),
            editorVisualState: InteractionSnapshotFormat.visual(editorState.visualState),
            editorOptimizationState: InteractionSnapshotFormat.optimization(editorState.optimizationState),
            debugSettingsState: InteractionSnapshotFormat.debug(editorState.debugSettings),
            validationIssue: runtimeConfigCoordinator.validationReport.issue,
            projectedBytes: runtimeConfigCoordinator.validationReport.projectedBytes,
            viewportRuntimeError: viewportRuntimeError,
            selectedFile: selectedFile?.url.path,
            debugMetricsVisible: debugMetricsAreVisible,
            panels: panelStates,
            performanceMetrics: InteractionSnapshotFormat.performanceMetrics(performanceMetrics)
        )
    }

    private func makePerformanceReviewSample() -> PerformanceReviewSample? {
        let editorState = editorSettingsStore.editorState
        let activeModules = runtimeConfigCoordinator.activeModules
        let transportState = runtimeConfigCoordinator.transportState
        let metrics = performanceMetrics

        return PerformanceReviewSample(
            physicsModule: activeModules.physics.name,
            visualModule: activeModules.visual.name,
            optimizationModule: activeModules.optimization.name,
            transportState: transportState.rawValue,
            particleCount: editorState.physicsState.particleCount,
            randomDistribution: editorState.physicsState.randomDistribution,
            particleTypes: editorState.physicsState.particleTypes,
            movementDirectionX: editorState.physicsState.movementDirection.x,
            movementDirectionY: editorState.physicsState.movementDirection.y,
            movementDirectionZ: editorState.physicsState.movementDirection.z,
            timeScale: editorState.physicsState.timeScale,
            sphereSize: editorState.visualState.sphereSize,
            spectrumOffset: editorState.visualState.spectrumOffset,
            showOptimizationInfo: editorState.visualState.showOptimizationInfo,
            blockingMode: editorState.optimizationState.blockingMode.rawValue,
            showLeaderCommunicationLog: editorState.optimizationState.showLeaderCommunicationLog,
            protectLeaderFromUnload: editorState.debugSettings.protectLeaderFromUnload,
            projectedBytes: runtimeConfigCoordinator.validationReport.projectedBytes,
            memoryUsedBytes: metrics.memoryUsedBytes,
            averageFPS: metrics.averageFPS,
            averageUPS: metrics.averageUPS,
            leaderInteractionsPerSecond: metrics.leaderInteractionsPerSecond
        )
    }

    private func previewPanelsInZone(_ zone: DockZone, fallback: [DockPanel]) -> [DockPanelPreview] {
        if let insertionType = menuInsertionType {
            let insertionIndex = fallback.count
            let mapped: [DockPanelPreview] = fallback.map { panel in
                DockPanelPreview(id: panel.id, panel: panel, isGhost: false, isShifted: false)
            }
            guard menuHoverZone == zone else {
                return mapped
            }

            var withGhost = mapped
            let ghost = DockPanel(id: UUID(), type: insertionType, zone: zone)
            withGhost.insert(
                DockPanelPreview(id: ghost.id, panel: ghost, isGhost: true, isShifted: false),
                at: insertionIndex
            )
            return withGhost.enumerated().map { pair in
                let (index, preview) = pair
                let shouldShift = !preview.isGhost && index >= insertionIndex
                return DockPanelPreview(
                    id: preview.id,
                    panel: preview.panel,
                    isGhost: preview.isGhost,
                    isShifted: shouldShift
                )
            }
        }

        guard panelDragSession?.hoveredZone == zone, let dragID = panelDragSession?.panelID else {
            return fallback.map {
                DockPanelPreview(id: $0.id, panel: $0, isGhost: false, isShifted: false)
            }
        }
        guard let draggedGlobalIndex = panels.firstIndex(where: { $0.id == dragID }),
              let draggedPanel = panels.first(where: { $0.id == dragID }) else {
            return fallback.map {
                DockPanelPreview(id: $0.id, panel: $0, isGhost: false, isShifted: false)
            }
        }

        var zonePanels = panels.filter { $0.zone == zone && $0.id != dragID }
        let defaultInsertionIndex = panels.enumerated().reduce(into: 0) { partial, pair in
            let (idx, candidate) = pair
            if idx < draggedGlobalIndex && candidate.zone == zone && candidate.id != dragID {
                partial += 1
            }
        }
        let insertionIndex = min(
            max(panelDragSession?.insertionIndexByZone[zone] ?? defaultInsertionIndex, 0),
            zonePanels.count
        )

        var ghostPanel = draggedPanel
        ghostPanel.zone = zone
        zonePanels.insert(ghostPanel, at: min(insertionIndex, zonePanels.count))

        return zonePanels.enumerated().map { pair in
            let (index, panel) = pair
            return DockPanelPreview(
                id: panel.id,
                panel: panel,
                isGhost: panel.id == dragID,
                isShifted: panel.id != dragID && index >= insertionIndex
            )
        }
    }

    private func cancelMenuInsertionMode() {
        menuInsertionType = nil
        menuHoverZone = nil
    }

    private func resetDragState() {
        panelDragSession = nil
    }

    private func insertionIndex(for zone: DockZone, at location: CGPoint) -> Int {
        let panelIDsInOrder = panelsInZone(zone).map(\.id)
        let panelFrames = panelFramesByZone[zone] ?? [:]
        let isHorizontal = zone == .center

        if panelIDsInOrder.isEmpty {
            return 0
        }

        for (index, id) in panelIDsInOrder.enumerated() {
            guard let frame = panelFrames[id] else { continue }
            let threshold = isHorizontal ? frame.midX : frame.midY
            let value = isHorizontal ? location.x : location.y
            if value < threshold {
                return index
            }
        }
        return panelIDsInOrder.count
    }

    private func updateClickThenDragHover(at rootLocation: CGPoint) {
        guard var session = panelDragSession, session.mode == .clickThenDrag else { return }

        let hovered = DockZone.allCases.first { zone in
            guard let frame = zoneFramesInRoot[zone] else { return false }
            return frame.contains(rootLocation)
        }
        session.hoveredZone = hovered

        if let zone = hovered, let frame = zoneFramesInRoot[zone] {
            let local = CGPoint(x: rootLocation.x - frame.minX, y: rootLocation.y - frame.minY)
            session.insertionIndexByZone[zone] = insertionIndex(for: zone, at: local)
        } else {
            session.insertionIndexByZone = [:]
        }

        panelDragSession = session
    }

    private func handleClickThenDragTap() {
        guard let session = panelDragSession, session.mode == .clickThenDrag else { return }
        if let zone = session.hoveredZone {
            movePanel(id: session.panelID, to: zone, at: session.insertionIndexByZone[zone])
        }
        resetDragState()
    }

    private func persistDockLayoutState() {
        let payload = DockLayoutState(
            panels: panels,
            collapsedPanelIDs: Array(collapsedPanelIDs)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: dockLayoutStorageKey)
    }

    private func loadDockLayoutState() {
        guard let data = UserDefaults.standard.data(forKey: dockLayoutStorageKey),
              let decoded = try? JSONDecoder().decode(DockLayoutState.self, from: data) else {
            return
        }
        if !decoded.panels.isEmpty {
            let signature = layoutSignature(for: decoded.panels)
            if signature == legacyDefaultLayoutSignature || signature == fileBrowserDefaultLayoutSignature {
                panels = defaultPanels
            } else {
                panels = decoded.panels
            }
        }
        collapsedPanelIDs = Set(decoded.collapsedPanelIDs)
    }

    private func layoutSignature(for panels: [DockPanel]) -> Set<String> {
        Set(panels.map { "\($0.type.rawValue):\($0.zone.rawValue)" })
    }

    private func resolvedModule(for kind: ModuleKind) -> ModuleDescriptor {
        guard let assignedURL = assignedModules[kind],
              let file = moduleCatalogStore.availableFiles.first(where: { $0.url == assignedURL }),
              let descriptor = file.descriptor else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }
        return descriptor
    }

    private func byteCountString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func formattedRate(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func formattedInteractionRate(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    private var transportState: SimulationTransportState { runtimeConfigCoordinator.transportState }
    private var physicsState: PhysicsModuleState { editorSettingsStore.editorState.physicsState }

    private var assignedModules: [ModuleKind: URL] {
        Dictionary(uniqueKeysWithValues: ModuleKind.allCases.compactMap { kind in
            guard let path = editorSettingsStore.assignedModulePath(for: kind) else { return nil }
            return (kind, URL(fileURLWithPath: path))
        })
    }
}

@MainActor
private enum EditorViewSupport {
    static func assignedModules(
        from store: MainWindowEditorSettingsStore
    ) -> [ModuleKind: URL] {
        Dictionary(uniqueKeysWithValues: ModuleKind.allCases.compactMap { kind in
            guard let path = store.assignedModulePath(for: kind) else { return nil }
            return (kind, URL(fileURLWithPath: path))
        })
    }

    static func resolvedModule(
        for kind: ModuleKind,
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> ModuleDescriptor {
        let assignedModules = assignedModules(from: store)
        guard let assignedURL = assignedModules[kind],
              let file = availableFiles.first(where: { $0.url == assignedURL }),
              let descriptor = file.descriptor else {
            return ModuleCatalog.fallback(for: kind.rawValue)
        }
        return descriptor
    }

    static func resolvedVisualSupportsOptimizationDebug(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> Bool {
        resolvedModule(for: .visual, store: store, availableFiles: availableFiles).acceptsOptimizationDebugInfo
            && resolvedModule(for: .optimization, store: store, availableFiles: availableFiles).name == ModuleCatalog.defaultOptimization.name
    }

    static func currentViewportState(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> SimulationViewportState {
        let editorState = store.editorState
        return SimulationViewportState(
            transportState: .stopped,
            particleCount: editorState.physicsState.particleCount,
            randomDistribution: editorState.physicsState.randomDistribution,
            particleTypes: editorState.physicsState.particleTypes,
            movementDirection: SIMD3<Float>(
                Float(editorState.physicsState.movementDirection.x),
                Float(editorState.physicsState.movementDirection.y),
                Float(editorState.physicsState.movementDirection.z)
            ),
            timeScale: Float(editorState.physicsState.timeScale),
            sphereSize: Float(editorState.visualState.sphereSize),
            spectrumOffset: Float(editorState.visualState.spectrumOffset),
            showOptimizationInfo: resolvedVisualSupportsOptimizationDebug(store: store, availableFiles: availableFiles)
                && editorState.visualState.showOptimizationInfo,
            optimizationBlockingMode: editorState.optimizationState.blockingMode
        )
    }

    static func activeModuleSet(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> ActiveModuleSet {
        ActiveModuleSet(
            physics: resolvedModule(for: .physics, store: store, availableFiles: availableFiles),
            visual: resolvedModule(for: .visual, store: store, availableFiles: availableFiles),
            optimization: resolvedModule(for: .optimization, store: store, availableFiles: availableFiles)
        )
    }

    static func projectedMemoryBytes(editorState: SimulationEditorState) -> UInt64 {
        let particleCount = max(1, editorState.physicsState.particleCount)
        let baseParticleStride = 40
        let visualStride = 16
        let optimizationStride = 16
        let typeBudget = 32 * 32
        let debugBudget = editorState.optimizationState.showLeaderCommunicationLog ? 8 * 1024 * 1024 : 0
        let reserved = particleCount * (baseParticleStride + visualStride + optimizationStride) + typeBudget + debugBudget
        return UInt64(reserved)
    }

    static func validationReport(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile],
        memoryBudgetPreset: MemoryBudgetPreset
    ) -> RuntimeValidationReport {
        let projectedBytes = projectedMemoryBytes(editorState: store.editorState)
        let activeModules = activeModuleSet(store: store, availableFiles: availableFiles)
        let viewportState = currentViewportState(store: store, availableFiles: availableFiles)

        if let issue = ModuleCompatibility.incompatibilityReason(for: activeModules, state: viewportState) {
            return RuntimeValidationReport(issue: issue, projectedBytes: projectedBytes)
        }

        if store.editorState.optimizationState.showLeaderCommunicationLog,
           activeModules.optimization.name != ModuleCatalog.defaultOptimization.name {
            return RuntimeValidationReport(
                issue: "Leader communication log is only available with \(ModuleCatalog.defaultOptimization.name).",
                projectedBytes: projectedBytes
            )
        }

        if projectedBytes > memoryBudgetPreset.budgetBytes {
            return RuntimeValidationReport(
                issue: "Projected simulation memory exceeds the \(memoryBudgetPreset.title) budget.",
                projectedBytes: projectedBytes
            )
        }

        return RuntimeValidationReport(issue: nil, projectedBytes: projectedBytes)
    }
}

private struct SimulationCenterPane: View {
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    @ObservedObject var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    @ObservedObject var diagnosticsStore: MainWindowDiagnosticsStore
    let viewportGeneration: Int
    let debugMetricsAreVisible: Bool

    private var transportState: SimulationTransportState { runtimeConfigCoordinator.transportState }
    private var validationReport: RuntimeValidationReport { runtimeConfigCoordinator.validationReport }
    private var currentMemoryBudgetPreset: MemoryBudgetPreset { ProgramSettingsStore.memoryBudgetPreset }
    private var performanceMetrics: SimulationPerformanceMetrics { diagnosticsStore.performanceMetrics }
    private var viewportRuntimeError: String? { diagnosticsStore.viewportRuntimeError }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Simulation")
                    .font(.headline)
                Spacer()
                Text("Sprint 01 First Pass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 10) {
                Button("Start") {
                    runtimeConfigCoordinator.startSimulation()
                }
                .disabled(transportState != .stopped || !validationReport.canStart)

                Button(transportState == .running ? "Pause" : "Play") {
                    runtimeConfigCoordinator.togglePausePlay()
                }
                .frame(minWidth: 64)
                .disabled(transportState == .stopped || (transportState == .paused && !validationReport.canStart))

                Button("Stop") {
                    runtimeConfigCoordinator.stopSimulation()
                }
                .disabled(transportState == .stopped)

                Divider()
                    .frame(height: 18)

                Picker("Memory Budget", selection: Binding(
                    get: { ProgramSettingsStore.memoryBudgetPreset.rawValue },
                    set: {
                        guard let preset = MemoryBudgetPreset(rawValue: $0) else { return }
                        ProgramSettingsStore.memoryBudgetPreset = preset
                        runtimeConfigCoordinator.refreshDerivedState()
                    }
                )) {
                    ForEach(MemoryBudgetPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Text(validationReport.canStart ? "Ready" : "Blocked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(validationReport.canStart ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 16) {
                LabeledContent("Transport", value: transportState.title)
                LabeledContent("Budget", value: currentMemoryBudgetPreset.title)
                LabeledContent("Projected", value: ByteCountFormatter.string(fromByteCount: Int64(validationReport.projectedBytes), countStyle: .memory))
                Spacer()
                if let issue = viewportRuntimeError ?? validationReport.issue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            MetalViewportView(
                metricsEnabled: debugMetricsAreVisible,
                diagnosticsStore: diagnosticsStore
            )
            .id(viewportGeneration)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )

            HStack(spacing: 16) {
                Text("Drag: Orbit")
                Text("WASD: Orbit")
                Text("Scroll/Pinch: Dolly")
                Text("F: Reset View")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ModuleSlotsPanel: View {
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    let availableFiles: [ModuleFile]
    let selectedFile: ModuleFile?
    @Binding var importerTargetKind: ModuleKind
    @Binding var isImporterPresented: Bool

    var body: some View {
        VStack(spacing: 8) {
            ForEach(ModuleKind.allCases) { kind in
                let assigned = EditorViewSupport.assignedModules(from: editorSettingsStore)[kind]
                let resolved = EditorViewSupport.resolvedModule(for: kind, store: editorSettingsStore, availableFiles: availableFiles)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(kind.displayName)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if resolved.visibility == .dev {
                            Text("DEV")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(assigned?.lastPathComponent ?? "Unassigned")
                                .font(.caption2)
                                .foregroundStyle(assigned == nil ? .secondary : .primary)
                                .lineLimit(1)
                            Text(assigned == nil ? "No file assigned. Runtime falls back to the built-in default module." : "Using assigned module file.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if assigned != nil {
                            Button("Clear") {
                                editorSettingsStore.setAssignedModulePath(nil, for: kind)
                            }
                            .font(.caption)
                        }
                        Button("Choose File") {
                            importerTargetKind = kind
                            isImporterPresented = true
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    if let selectedFile, selectedFile.kind == kind {
                        Button("Assign Selected File") {
                            editorSettingsStore.setAssignedModulePath(selectedFile.url.path, for: kind)
                        }
                    }
                    if assigned != nil {
                        Button("Clear Assignment", role: .destructive) {
                            editorSettingsStore.setAssignedModulePath(nil, for: kind)
                        }
                    }
                }
            }
        }
    }
}

private struct ModuleSettingsPanelView: View {
    let kind: ModuleKind
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    let availableFiles: [ModuleFile]
    let particleCountUICap: Int
    let particleCountEngineCap: Int

    private var resolved: ModuleDescriptor {
        EditorViewSupport.resolvedModule(for: kind, store: editorSettingsStore, availableFiles: availableFiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolved.name)
                        .font(.caption.weight(.semibold))
                    Text(kind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if resolved.visibility == .dev {
                    Text("DEV")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Group {
                switch kind {
                case .physics:
                    if resolved.name == ModuleCatalog.defaultPhysics.name {
                        PhysicsSettingsPanel(store: editorSettingsStore, particleCountUICap: particleCountUICap, particleCountEngineCap: particleCountEngineCap)
                    } else {
                        unavailable
                    }
                case .visual:
                    if resolved.name == ModuleCatalog.defaultVisual.name {
                        VisualSettingsPanel(store: editorSettingsStore, optimizationDebugSupported: EditorViewSupport.resolvedVisualSupportsOptimizationDebug(store: editorSettingsStore, availableFiles: availableFiles))
                    } else {
                        unavailable
                    }
                case .optimization:
                    if resolved.name == ModuleCatalog.defaultOptimization.name {
                        OptimizationSettingsPanel(store: editorSettingsStore)
                    } else {
                        unavailable
                    }
                }
            }
            .id(resolved.id)
            .animation(.easeInOut(duration: 0.22), value: resolved.id)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No dedicated settings UI is registered for this module yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Resolved module: \(resolved.name)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PhysicsSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    let particleCountUICap: Int
    let particleCountEngineCap: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EventuallyAppliedIntSlider(
                title: "Particle Count",
                appliedValue: Binding(
                    get: { store.editorState.physicsState.particleCount },
                    set: {
                        var next = store.editorState.physicsState
                        next.particleCount = $0
                        store.setPhysicsState(next)
                    }
                ),
                range: 1...particleCountUICap,
                helpText: "UI cap: \(particleCountUICap.formatted()). Hard engine limit: \(particleCountEngineCap.formatted())."
            )
            EventuallyAppliedToggle(title: "Random Distribution", appliedValue: Binding(
                get: { store.editorState.physicsState.randomDistribution },
                set: {
                    var next = store.editorState.physicsState
                    next.randomDistribution = $0
                    store.setPhysicsState(next)
                }
            ))
            EventuallyAppliedSlider(
                title: "Particle Types",
                appliedValue: Binding(
                    get: { Double(store.editorState.physicsState.particleTypes) },
                    set: {
                        var next = store.editorState.physicsState
                        next.particleTypes = max(1, min(32, Int($0.rounded())))
                        store.setPhysicsState(next)
                    }
                ),
                range: 1...32,
                step: 1,
                valueText: { "\(Int($0.rounded()))" }
            )
            Picker("Movement", selection: .constant("slide")) {
                Text("Slide").tag("slide")
            }
            .font(.caption)
            .pickerStyle(.segmented)
            .disabled(true)
            ForEach([("Direction X", \SIMD3<Double>.x), ("Direction Y", \SIMD3<Double>.y), ("Direction Z", \SIMD3<Double>.z)], id: \.0) { title, keyPath in
                EventuallyAppliedSlider(
                    title: title,
                    appliedValue: Binding(
                        get: { store.editorState.physicsState.movementDirection[keyPath: keyPath] },
                        set: {
                            var next = store.editorState.physicsState
                            next.movementDirection[keyPath: keyPath] = $0
                            store.setPhysicsState(next)
                        }
                    ),
                    range: 0...1,
                    step: 0.01,
                    valueText: { String(format: "%.2f", $0) }
                )
            }
            EventuallyAppliedSlider(
                title: "Time Scale",
                appliedValue: Binding(
                    get: { store.editorState.physicsState.timeScale },
                    set: {
                        var next = store.editorState.physicsState
                        next.timeScale = $0
                        store.setPhysicsState(next)
                    }
                ),
                range: 0...4,
                step: 0.01,
                valueText: { String(format: "%.2fx", $0) }
            )
        }
    }
}

private struct VisualSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore
    let optimizationDebugSupported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EventuallyAppliedSlider(
                title: "Sphere Size",
                appliedValue: Binding(
                    get: { store.editorState.visualState.sphereSize },
                    set: {
                        var next = store.editorState.visualState
                        next.sphereSize = $0
                        store.setVisualState(next)
                    }
                ),
                range: 0.005...0.120,
                step: 0.001,
                valueText: { String(format: "%.3f", $0) }
            )
            EventuallyAppliedSlider(
                title: "Spectrum Offset",
                appliedValue: Binding(
                    get: { store.editorState.visualState.spectrumOffset },
                    set: {
                        var next = store.editorState.visualState
                        next.spectrumOffset = $0
                        store.setVisualState(next)
                    }
                ),
                range: 0...1,
                step: 0.01,
                valueText: { String(format: "%.2f", $0) }
            )
            EventuallyAppliedToggle(
                title: "Show Optimization Info",
                appliedValue: Binding(
                    get: { store.editorState.visualState.showOptimizationInfo },
                    set: {
                        var next = store.editorState.visualState
                        next.showOptimizationInfo = $0
                        store.setVisualState(next)
                    }
                )
            )
            .disabled(!optimizationDebugSupported)
        }
    }
}

private struct OptimizationSettingsPanel: View {
    @ObservedObject var store: MainWindowEditorSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EventuallyAppliedSegmentedPicker(
                title: "Blocking Mode",
                appliedValue: Binding(
                    get: { store.editorState.optimizationState.blockingMode },
                    set: {
                        var next = store.editorState.optimizationState
                        next.blockingMode = $0
                        store.setOptimizationState(next)
                    }
                ),
                options: OptimizationBlockingMode.allCases,
                optionTitle: { $0.title }
            )
            EventuallyAppliedToggle(
                title: "Leader Communication Log",
                appliedValue: Binding(
                    get: { store.editorState.optimizationState.showLeaderCommunicationLog },
                    set: {
                        var next = store.editorState.optimizationState
                        next.showLeaderCommunicationLog = $0
                        store.setOptimizationState(next)
                    }
                )
            )
            EventuallyAppliedToggle(
                title: "Protect Leader From Unload",
                appliedValue: Binding(
                    get: { store.editorState.debugSettings.protectLeaderFromUnload },
                    set: {
                        var next = store.editorState.debugSettings
                        next.protectLeaderFromUnload = $0
                        store.setDebugSettings(next)
                    }
                )
            )
            Text("Naive all-pairs traversal is the default optimization MVP.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FileViewPanel: View {
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    let availableFiles: [ModuleFile]
    let selectedFile: ModuleFile?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Root: \(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Modules", isDirectory: true).path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Refresh", action: onRefresh)
                    .font(.caption2)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ModuleKind.allCases) { kind in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(kind.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            let files = availableFiles.filter { $0.kind == kind }
                            if files.isEmpty {
                                Text("No files")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(files) { file in
                                    Text(file.url.lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.09))
                                        )
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 180)
            .scrollIndicators(.visible)

            if let selectedFile {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected: \(selectedFile.url.lastPathComponent)")
                        .font(.caption)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Button("Assign to \(selectedFile.kind.displayName)") {
                            editorSettingsStore.setAssignedModulePath(selectedFile.url.path, for: selectedFile.kind)
                        }
                        .font(.caption)
                        if editorSettingsStore.assignedModulePath(for: selectedFile.kind) != nil {
                            Button("Clear \(selectedFile.kind.displayName)") {
                                editorSettingsStore.setAssignedModulePath(nil, for: selectedFile.kind)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

private struct InspectorPanel: View {
    @ObservedObject var interactionSnapshotRecorder: InteractionSnapshotRecorder
    @ObservedObject var performanceReviewLogger: PerformanceReviewLogger
    let transportState: SimulationTransportState
    let validationReport: RuntimeValidationReport
    let performanceMetrics: SimulationPerformanceMetrics
    let panelsCount: Int
    let collapsedPanelsCount: Int
    let debugMetricsAreVisible: Bool
    let viewportRuntimeError: String?
    let onStartInteractionSnapshot: () -> Void
    let onSetPerformanceReviewLoggingEnabled: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            metricRow("Memory Used", ByteCountFormatter.string(fromByteCount: Int64(performanceMetrics.memoryUsedBytes), countStyle: .memory))
            metricRow("FPS", String(format: "%.1f", performanceMetrics.averageFPS))
            metricRow("UPS", String(format: "%.1f", performanceMetrics.averageUPS))
            metricRow("Leader Interactions/s", performanceMetrics.leaderInteractionsPerSecond >= 1_000_000 ? String(format: "%.2fM", performanceMetrics.leaderInteractionsPerSecond / 1_000_000) : performanceMetrics.leaderInteractionsPerSecond >= 1_000 ? String(format: "%.1fK", performanceMetrics.leaderInteractionsPerSecond / 1_000) : String(format: "%.0f", performanceMetrics.leaderInteractionsPerSecond))
            Text("Rolling average over the last \(Int(performanceMetrics.sampleWindowSeconds))s.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            Text("Session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            metricRow("Transport", transportState.title)
            metricRow("Panels", "\(panelsCount)")
            metricRow("Collapsed", "\(collapsedPanelsCount)")
            Divider()
            Text("Runtime")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            metricRow("Projected Memory", ByteCountFormatter.string(fromByteCount: Int64(validationReport.projectedBytes), countStyle: .memory))
            metricRow("Visible Debug", debugMetricsAreVisible ? "Yes" : "No")
            Divider()
            Text("Diagnostics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(
                "Performance Review Logging",
                isOn: Binding(
                    get: { performanceReviewLogger.isEnabled },
                    set: { onSetPerformanceReviewLoggingEnabled($0) }
                )
            )
            .font(.caption)
            Text(performanceReviewStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            metricRow(
                "Review Log Budget",
                "\(ByteCountFormatter.string(fromByteCount: Int64(performanceReviewLogger.currentBudgetOccupancyBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(performanceReviewLogger.maxBudgetBytes), countStyle: .file))"
            )
            if performanceReviewLogger.isNearBudgetLimit {
                Text("Performance review logs are nearing the 20 MB cap. Oldest samples will roll off.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button(interactionSnapshotRecorder.isRecording ? "Interaction Snapshot (\(interactionSnapshotRecorder.remainingSeconds)s)" : "Interaction Snapshot") {
                onStartInteractionSnapshot()
            }
            .font(.caption)
            .disabled(interactionSnapshotRecorder.isRecording)
            if let lastOutputPath = interactionSnapshotRecorder.lastOutputPath {
                Text(lastOutputPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if interactionSnapshotRecorder.isRecording {
                Text("Recording UI and simulation state for 15 seconds.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let issue = viewportRuntimeError ?? validationReport.issue {
                Text(issue)
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.9))
            } else {
                Text("No runtime validation issues.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var performanceReviewStatusText: String {
        if performanceReviewLogger.isEnabled {
            if let currentComboFileName = performanceReviewLogger.currentComboFileName {
                return "Adaptive logging on. Buffered samples: \(performanceReviewLogger.bufferedSampleCount). Latest combo: \(currentComboFileName)"
            }
            return "Adaptive logging on. Waiting for running simulation data."
        }
        return "Adaptive logging off."
    }
}
