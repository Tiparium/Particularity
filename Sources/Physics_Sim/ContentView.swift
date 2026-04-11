import SwiftUI
import UniformTypeIdentifiers
import Foundation
import AppKit

private struct DockPanelPreview: Identifiable {
    let id: UUID
    let panel: DockPanel
    let isGhost: Bool
    let isShifted: Bool
}

private struct HeaderControlButton: View {
    let iconName: String
    let variant: AppControlVariant
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppIconControlSurface(iconName: iconName, variant: variant, isHovered: isHovered, isPressed: false)
        }
        .buttonStyle(AppInteractiveButtonStyle())
    }
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

struct MainWindowContentDependencies {
    let session: SimulationSession
    let chromeStateStore: MainWindowChromeStateStore
    let editorSettingsStore: MainWindowEditorSettingsStore
    let viewportStateStore: MainWindowViewportStateStore
    let physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    let moduleCatalogStore: MainWindowModuleCatalogStore
    let runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    let diagnosticsStore: MainWindowDiagnosticsStore
    let interactionSnapshotRecorder: InteractionSnapshotRecorder
    let performanceReviewLogger: PerformanceReviewLogger

    @MainActor
    static func load(
        progress: ((LaunchProgressStage) -> Void)? = nil
    ) async throws -> MainWindowContentDependencies {
        progress?(.loadingSession)
        await Task.yield()
        let session = try await WindowSimulationSessionStore.shared.mainWindowSession()

        progress?(.loadingEditorStores)
        await Task.yield()
        let editorSettingsStore = WindowSimulationSessionStore.shared.mainWindowEditorSettingsStore()
        let physicsModuleSettingsStore = WindowSimulationSessionStore.shared.mainWindowPhysicsModuleSettingsStore()
        let moduleCatalogStore = WindowSimulationSessionStore.shared.mainWindowModuleCatalogStore()
        let diagnosticsStore = WindowSimulationSessionStore.shared.mainWindowDiagnosticsStore()

        progress?(.buildingCoordinator)
        await Task.yield()
        let runtimeConfigCoordinator = try await WindowSimulationSessionStore.shared.mainWindowRuntimeConfigCoordinator()

        progress?(.finalizingUI)
        await Task.yield()
        return MainWindowContentDependencies(
            session: session,
            chromeStateStore: WindowSimulationSessionStore.shared.mainWindowChromeStateStore(),
            editorSettingsStore: editorSettingsStore,
            viewportStateStore: WindowSimulationSessionStore.shared.mainWindowViewportStateStore(),
            physicsModuleSettingsStore: physicsModuleSettingsStore,
            moduleCatalogStore: moduleCatalogStore,
            runtimeConfigCoordinator: runtimeConfigCoordinator,
            diagnosticsStore: diagnosticsStore,
            interactionSnapshotRecorder: InteractionSnapshotRecorder.shared,
            performanceReviewLogger: PerformanceReviewLogger.shared
        )
    }
}

struct ContentView: View {
    private let particleCountEngineCap = SimulationParticleLimits.engineCap
    private let particleCountUICap = SimulationParticleLimits.settingsUICap
    @State private var isImporterPresented = false
    @State private var importerTargetKind: ModuleKind = .physics
    @State private var hoveredGrabPanelID: UUID?
    @State private var hoveredClosePanelID: UUID?
    @State private var panelDragSession: PanelDragSession?
    @State private var panelDragInteractionState = DragInteractionState(clickThenDragEndBehavior: .explicitOnly)
    @State private var menuInsertionType: DockPanelType?
    @State private var menuHoverZone: DockZone?
    @State private var panelFramesByZone: [DockZone: [UUID: CGRect]] = [:]
    @State private var zoneFramesInRoot: [DockZone: CGRect] = [:]
    @State private var viewportGeneration: Int = 0
    private let session: SimulationSession
    @ObservedObject private var chromeStateStore: MainWindowChromeStateStore
    private let editorSettingsStore: MainWindowEditorSettingsStore
    private let viewportStateStore: MainWindowViewportStateStore
    private let physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    private let moduleCatalogStore: MainWindowModuleCatalogStore
    private let runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    private let diagnosticsStore: MainWindowDiagnosticsStore
    private let interactionSnapshotRecorder: InteractionSnapshotRecorder
    private let performanceReviewLogger: PerformanceReviewLogger

    init(dependencies: MainWindowContentDependencies) {
        self.session = dependencies.session
        _chromeStateStore = ObservedObject(wrappedValue: dependencies.chromeStateStore)
        self.editorSettingsStore = dependencies.editorSettingsStore
        self.viewportStateStore = dependencies.viewportStateStore
        self.physicsModuleSettingsStore = dependencies.physicsModuleSettingsStore
        self.moduleCatalogStore = dependencies.moduleCatalogStore
        self.runtimeConfigCoordinator = dependencies.runtimeConfigCoordinator
        self.diagnosticsStore = dependencies.diagnosticsStore
        self.interactionSnapshotRecorder = dependencies.interactionSnapshotRecorder
        self.performanceReviewLogger = dependencies.performanceReviewLogger
    }

    private var panels: [DockPanel] {
        chromeStateStore.panels
    }

    private var collapsedPanelIDs: Set<UUID> {
        chromeStateStore.collapsedPanelIDs
    }

    private func assignImportedModuleURL(_ url: URL, for kind: ModuleKind) {
        guard let resolvedFile = SimulationConfigurationDerivation.resolvedAssignedModuleFile(
            for: kind,
            assignedPath: url.path,
            availableFiles: moduleCatalogStore.availableFiles
        ) else {
            return
        }

        editorSettingsStore.setAssignedModulePath(resolvedFile.url.path, for: kind)
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                PersistentThreePaneSplitView(
                    defaultLeftWidth: 280,
                    defaultRightWidth: 280,
                    initialLeftWidth: chromeStateStore.savedLeftDockWidth(fallback: 280),
                    initialRightWidth: chromeStateStore.savedRightDockWidth(fallback: 280),
                    leftPanelVisible: chromeStateStore.leftPanelVisible,
                    rightPanelVisible: chromeStateStore.rightPanelVisible,
                    minSideWidth: 220,
                    maxSideWidthRatio: 0.35,
                    onWidthsChanged: { left, right in
                        chromeStateStore.setSideDockWidths(left: left, right: right)
                    },
                    left: dockColumn(.left),
                    center: centerColumn(),
                    right: dockColumn(.right)
                )
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
            moduleCatalogStore.refresh()
            chromeStateStore.ensureSelectedFileID(availableFiles: moduleCatalogStore.availableFiles)
            PerformanceReviewLogger.shared.configure(
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                snapshotProvider: makePerformanceReviewSample
            )
        }
        .onAppear {
            fputs("APP_READY\n", stderr)
            fflush(stderr)
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
        .onReceive(moduleCatalogStore.$availableFiles) { availableFiles in
            chromeStateStore.ensureSelectedFileID(availableFiles: availableFiles)
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
                assignImportedModuleURL(url, for: importerTargetKind)
            }
        }
    }

    private func centerColumn() -> some View {
        PersistentVerticalSplitView(
            defaultBottomHeight: 240,
            initialBottomHeight: chromeStateStore.savedCenterDockHeight(fallback: 240),
            bottomPanelVisible: chromeStateStore.bottomPanelVisible,
            minBottomHeight: 180,
            maxBottomHeightRatio: 0.45,
            onBottomHeightChanged: { height in
                chromeStateStore.setCenterDockHeight(height)
            },
            top: SimulationCenterPane(
                session: session,
                viewportStateStore: viewportStateStore,
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                diagnosticsStore: diagnosticsStore,
                viewportGeneration: viewportGeneration,
                anyDockPanelsVisible: chromeStateStore.anyDockPanelsVisible,
                leftPanelVisible: chromeStateStore.leftPanelVisible,
                rightPanelVisible: chromeStateStore.rightPanelVisible,
                bottomPanelVisible: chromeStateStore.bottomPanelVisible,
                onToggleAllDockPanelsVisibility: { chromeStateStore.toggleAllDockPanelsVisibility() },
                onToggleLeftPanelVisibility: { chromeStateStore.toggleLeftPanelVisibility() },
                onToggleRightPanelVisibility: { chromeStateStore.toggleRightPanelVisibility() },
                onToggleBottomPanelVisibility: { chromeStateStore.toggleBottomPanelVisibility() }
            ),
            bottom: dropZoneSurface(for: .center, panels: panelsInZone(.center))
        )
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
                VStack(alignment: .leading, spacing: 4) {
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
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    zoneHeader(for: zone)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
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
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
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
                        AppControlPalette.accent.opacity(
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
                        ? AppControlPalette.accent.opacity(0.85)
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
        .highPriorityGesture(
            TapGesture().onEnded {
                guard let insertionType = menuInsertionType else { return }
                addPanel(type: insertionType, to: zone)
                cancelMenuInsertionMode()
            },
            including: isAddMode ? .gesture : .subviews
        )
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
                AppMenuIconLabel(iconName: "plus", variant: .neutral)
            }
            .menuStyle(.borderlessButton)
            .help("Add panel")
            .disabled(isPanelDragActive)

        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 0)
    }

    private func panelCard(_ panel: DockPanel, isGhost: Bool = false, isShifted: Bool = false) -> some View {
        let isPanelDragActive = panelDragSession != nil
        let isExpanded = Binding(
            get: { !collapsedPanelIDs.contains(panel.id) },
            set: { nextValue in
                chromeStateStore.setPanelCollapsed(panel.id, isCollapsed: !nextValue)
                interactionSnapshotRecorder.record(
                    event: "ui.toggle_panel_collapsed",
                    details: [
                        "panelID": panel.id.uuidString,
                        "isCollapsed": "\(!nextValue)",
                    ]
                )
            }
        )
        return VStack(alignment: .leading, spacing: 10) {
            CollapsibleSectionHeader(
                title: panel.type.title,
                isExpanded: isGhost ? .constant(true) : isExpanded,
                titleFont: .subheadline.weight(.semibold),
                titleColor: isGhost ? .secondary : .primary,
                minHeight: 32,
                cornerRadius: 7,
                backgroundOpacity: 0.16
            ) {
                AppIconControlSurface(
                    iconName: "hand.draw",
                    variant: .accent,
                    isHovered: hoveredGrabPanelID == panel.id,
                    isPressed: false
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
                                    _ = panelDragInteractionState.beginInteraction(for: .clickAndDrag)
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
                                    if panelDragSession?.panelID != panel.id {
                                        resetDragState()
                                    }

                                    let isActive = panelDragInteractionState.beginInteraction(for: .clickThenDrag)
                                    if isActive {
                                        panelDragSession = PanelDragSession(
                                            panelID: panel.id,
                                            mode: .clickThenDrag,
                                            pointerInRoot: .zero,
                                            hoveredZone: nil,
                                            insertionIndexByZone: [:]
                                        )
                                    } else {
                                        panelDragSession = nil
                                    }
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
            .allowsHitTesting(!isGhost)

            if isExpanded.wrappedValue || isGhost {
                panelBodyContent(for: panel)
                .allowsHitTesting(!isPanelDragActive || isGhost)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .opacity(isGhost ? 0.50 : 1.0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isGhost ? AppControlPalette.accent.opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.4),
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
                moduleCatalogStore: moduleCatalogStore,
                chromeStateStore: chromeStateStore,
                importerTargetKind: $importerTargetKind,
                isImporterPresented: $isImporterPresented
            )
        case .physicsSettings:
            ModuleSettingsPanelView(
                kind: .physics,
                editorSettingsStore: editorSettingsStore,
                physicsModuleSettingsStore: physicsModuleSettingsStore,
                moduleCatalogStore: moduleCatalogStore,
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                particleCountUICap: particleCountUICap,
                particleCountEngineCap: particleCountEngineCap
            )
        case .visualSettings:
            ModuleSettingsPanelView(
                kind: .visual,
                editorSettingsStore: editorSettingsStore,
                physicsModuleSettingsStore: physicsModuleSettingsStore,
                moduleCatalogStore: moduleCatalogStore,
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                particleCountUICap: particleCountUICap,
                particleCountEngineCap: particleCountEngineCap
            )
        case .optimizationSettings:
            ModuleSettingsPanelView(
                kind: .optimization,
                editorSettingsStore: editorSettingsStore,
                physicsModuleSettingsStore: physicsModuleSettingsStore,
                moduleCatalogStore: moduleCatalogStore,
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                particleCountUICap: particleCountUICap,
                particleCountEngineCap: particleCountEngineCap
            )
        case .fileView:
            FileViewPanel(
                editorSettingsStore: editorSettingsStore,
                moduleCatalogStore: moduleCatalogStore,
                chromeStateStore: chromeStateStore
            )
        case .inspector:
            InspectorPanel(
                interactionSnapshotRecorder: interactionSnapshotRecorder,
                performanceReviewLogger: performanceReviewLogger,
                runtimeConfigCoordinator: runtimeConfigCoordinator,
                diagnosticsStore: diagnosticsStore,
                chromeStateStore: chromeStateStore,
                onStartInteractionSnapshot: startInteractionSnapshotRecording,
                onSetPerformanceReviewLoggingEnabled: { performanceReviewLogger.setEnabled($0) }
            )
        case .leaderCommunicationLog:
            LeaderCommunicationLogPanel(diagnosticsStore: diagnosticsStore)
        }
    }

    private var selectedFile: ModuleFile? {
        guard let selectedFileID = chromeStateStore.selectedFileID else { return nil }
        return moduleCatalogStore.availableFiles.first(where: { $0.id == selectedFileID })
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
        chromeStateStore.addPanel(type: type, to: zone)
        interactionSnapshotRecorder.record(
            event: "ui.add_panel",
            details: [
                "type": type.rawValue,
                "zone": zone.rawValue,
            ]
        )
    }

    private func removePanel(_ id: UUID) {
        chromeStateStore.removePanel(id: id)
        interactionSnapshotRecorder.record(
            event: "ui.remove_panel",
            details: ["panelID": id.uuidString]
        )
        if panelDragSession?.panelID == id {
            resetDragState()
        }
    }

    private func movePanel(id: UUID, to zone: DockZone, at insertionIndex: Int?) {
        chromeStateStore.movePanel(id: id, to: zone, at: insertionIndex)
        let destinationCount = panels.filter { $0.zone == zone }.count
        let indexInZone = min(max(insertionIndex ?? destinationCount, 0), destinationCount)
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
                .stroke(AppControlPalette.accent.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
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
            viewportRuntimeError: diagnosticsStore.viewportRuntimeError,
            selectedFile: selectedFile?.url.path,
            debugMetricsVisible: debugMetricsAreVisible,
            panels: panelStates,
            performanceMetrics: InteractionSnapshotFormat.performanceMetrics(diagnosticsStore.performanceMetrics)
        )
    }

    private func makePerformanceReviewSample() -> PerformanceReviewSample? {
        let editorState = editorSettingsStore.editorState
        let activeModules = runtimeConfigCoordinator.activeModules
        let transportState = runtimeConfigCoordinator.transportState
        let metrics = diagnosticsStore.performanceMetrics

        return PerformanceReviewSample(
            physicsModule: activeModules.physics.name,
            visualModule: activeModules.visual.name,
            optimizationModule: activeModules.optimization.name,
            transportState: transportState.rawValue,
            particleCount: editorState.physicsState.particleCount,
            randomDistribution: editorState.physicsState.randomDistribution,
            particleTypes: editorState.physicsState.particleTypes,
            allParticlesIntercommunicate: editorState.physicsState.allParticlesIntercommunicate,
            movementDirectionX: editorState.physicsState.movementDirection.x,
            movementDirectionY: editorState.physicsState.movementDirection.y,
            movementDirectionZ: editorState.physicsState.movementDirection.z,
            timeScale: editorState.physicsState.timeScale,
            sphereSize: editorState.visualState.sphereSize,
            spectrumOffset: editorState.visualState.spectrumOffset,
            showOptimizationInfo: editorState.visualState.showOptimizationInfo,
            showLeaderCommunicationLog: editorState.optimizationState.showLeaderCommunicationLog,
            fixedGridNeighborReadMode: editorState.optimizationState.fixedGridNeighborReadMode.rawValue,
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
        panelDragInteractionState.reset()
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
        panelDragInteractionState.endClickThenDragInteraction()
        resetDragState()
    }

    private var transportState: SimulationTransportState { runtimeConfigCoordinator.transportState }
    private var physicsState: PhysicsModuleState { editorSettingsStore.editorState.physicsState }
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
        SimulationConfigurationDerivation.resolveModule(
            for: kind,
            editorState: store.editorState,
            availableFiles: availableFiles
        )
    }

    static func resolvedVisualSupportsOptimizationDebug(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> Bool {
        SimulationConfigurationDerivation.visualSupportsOptimizationDebug(
            editorState: store.editorState,
            availableFiles: availableFiles
        )
    }

    static func currentViewportState(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> SimulationViewportState {
        SimulationConfigurationDerivation.simulationState(
            transportState: .stopped,
            editorState: store.editorState,
            availableFiles: availableFiles
        )
    }

    static func activeModuleSet(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> ActiveModuleSet {
        SimulationConfigurationDerivation.activeModules(
            editorState: store.editorState,
            availableFiles: availableFiles
        )
    }

    static func projectedMemoryBytes(editorState: SimulationEditorState) -> UInt64 {
        SimulationConfigurationDerivation.projectedMemoryBytes(editorState: editorState)
    }

    static func validationReport(
        store: MainWindowEditorSettingsStore,
        availableFiles: [ModuleFile]
    ) -> RuntimeValidationReport {
        SimulationConfigurationDerivation.validationReport(
            editorState: store.editorState,
            transportState: .stopped,
            availableFiles: availableFiles
        )
    }
}

private struct SimulationCenterPane: View {
    let session: SimulationSession
    @ObservedObject var viewportStateStore: MainWindowViewportStateStore
    @ObservedObject var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    @ObservedObject var diagnosticsStore: MainWindowDiagnosticsStore
    let viewportGeneration: Int
    let anyDockPanelsVisible: Bool
    let leftPanelVisible: Bool
    let rightPanelVisible: Bool
    let bottomPanelVisible: Bool
    let onToggleAllDockPanelsVisibility: () -> Void
    let onToggleLeftPanelVisibility: () -> Void
    let onToggleRightPanelVisibility: () -> Void
    let onToggleBottomPanelVisibility: () -> Void

    private var transportState: SimulationTransportState { runtimeConfigCoordinator.transportState }
    private var validationReport: RuntimeValidationReport { runtimeConfigCoordinator.validationReport }
    private var viewportRuntimeError: String? { diagnosticsStore.viewportRuntimeError }
    private var isPlaybackMode: Bool { runtimeConfigCoordinator.activeModules.isPlaybackModuleFamily }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Simulation")
                    .font(.headline)
                Spacer()
                Text("Editor Runtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 10) {
                Button("Start") {
                    runtimeConfigCoordinator.startSimulation()
                }
                .buttonStyle(AppFramedButtonStyle(.prominent))
                .disabled(transportState != .stopped || !validationReport.canStart)

                Button(transportState == .running ? "Pause" : "Play") {
                    runtimeConfigCoordinator.togglePausePlay()
                }
                .frame(minWidth: 64)
                .buttonStyle(AppFramedButtonStyle())
                .disabled(transportState == .stopped || (transportState == .paused && !validationReport.canStart))

                Button("Stop") {
                    runtimeConfigCoordinator.stopSimulation()
                }
                .buttonStyle(AppFramedButtonStyle())
                .disabled(transportState == .stopped)

                Divider()
                    .frame(height: 18)

                AppIconButton(
                    iconName: anyDockPanelsVisible ? "rectangle.split.3x1" : "rectangle.split.3x1.fill",
                    helpText: anyDockPanelsVisible ? "Hide all dock panels" : "Show all dock panels"
                ) {
                    onToggleAllDockPanelsVisibility()
                }

                AppIconButton(
                    iconName: "sidebar.left",
                    helpText: leftPanelVisible ? "Hide left panel" : "Show left panel",
                    isDimmed: leftPanelVisible
                ) {
                    onToggleLeftPanelVisibility()
                }

                AppIconButton(
                    iconName: "sidebar.right",
                    helpText: rightPanelVisible ? "Hide right panel" : "Show right panel",
                    isDimmed: rightPanelVisible
                ) {
                    onToggleRightPanelVisibility()
                }

                AppIconButton(
                    iconName: bottomPanelVisible ? "rectangle.topthird.inset.filled" : "rectangle.bottomthird.inset.filled",
                    helpText: bottomPanelVisible ? "Hide bottom panel" : "Show bottom panel",
                    isDimmed: bottomPanelVisible
                ) {
                    onToggleBottomPanelVisibility()
                }

                Divider()
                    .frame(height: 18)

                AppSwitchToggle(
                    "Slow Rotation",
                    isOn: Binding(
                        get: { viewportStateStore.viewportState.slowRotationEnabled },
                        set: { viewportStateStore.setSlowRotationEnabled($0) }
                    ),
                    helpText: viewportStateStore.viewportState.slowRotationEnabled ? "Disable slow rotation" : "Enable slow rotation"
                )

                Spacer()

                Text(validationReport.canStart ? "Ready" : "Blocked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(validationReport.canStart ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            Group {
                if isPlaybackMode {
                    PlaybackTimelineBar(runtimeConfigCoordinator: runtimeConfigCoordinator)
                        .transition(.opacity)
                } else if let issue = viewportRuntimeError {
                    HStack {
                        Spacer()
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(Color.red.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            SimulationViewportSurface(
                session: session,
                viewportStateStore: viewportStateStore,
                transportState: transportState,
                viewportGeneration: viewportGeneration,
                diagnosticsStore: diagnosticsStore
            )
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

private struct PlaybackTimelineBar: View {
    @ObservedObject var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator

    @State private var currentSeconds: Double = 0
    @State private var isLooping = true
    @State private var isScrubbing = false

    private var durationSeconds: Double {
        max(0.001, runtimeConfigCoordinator.playbackTimelineSnapshot.durationSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playback Timeline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()

                AppSwitchToggle(
                    "Loop",
                    isOn: Binding(
                        get: { isLooping },
                        set: {
                            isLooping = $0
                            runtimeConfigCoordinator.setPlaybackLooping($0)
                        }
                    ),
                    helpText: isLooping ? "Loop playback at the end" : "Stop playback at the end"
                )
            }

            HStack(spacing: 10) {
                Text(formatTime(currentSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 66, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { currentSeconds },
                        set: {
                            let nextSeconds = min(max(0, $0), durationSeconds)
                            currentSeconds = nextSeconds
                            runtimeConfigCoordinator.setPlaybackTime(nextSeconds)
                        }
                    ),
                    in: 0...durationSeconds,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            runtimeConfigCoordinator.beginPlaybackScrub()
                        } else {
                            runtimeConfigCoordinator.endPlaybackScrub()
                            syncTimelineFromRuntime()
                        }
                    }
                )

                Text(formatTime(durationSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 66, alignment: .trailing)
            }

            Text("Member 001 stress playback. 20,000 particles across embeddings, probes, and hidden-state slices.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            runtimeConfigCoordinator.refreshPlaybackTimelineSnapshot()
            syncTimelineFromRuntime()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            runtimeConfigCoordinator.refreshPlaybackTimelineSnapshot()
            syncTimelineFromRuntime()
        }
        .onChange(of: runtimeConfigCoordinator.playbackTimelineSnapshot) { _, _ in
            syncTimelineFromRuntime()
        }
    }

    private func syncTimelineFromRuntime() {
        guard !isScrubbing else { return }
        let snapshot = runtimeConfigCoordinator.playbackTimelineSnapshot
        currentSeconds = min(max(0, snapshot.currentSeconds), max(0, snapshot.durationSeconds))
        isLooping = snapshot.isLooping
    }

    private func formatTime(_ seconds: Double) -> String {
        let bounded = max(0, seconds)
        let wholeSeconds = Int(bounded)
        let milliseconds = Int((bounded - Double(wholeSeconds)) * 1000)
        return String(format: "%02d:%02d.%03d", wholeSeconds / 60, wholeSeconds % 60, milliseconds)
    }
}

private struct SimulationViewportSurface: View {
    let session: SimulationSession
    let viewportStateStore: MainWindowViewportStateStore
    let transportState: SimulationTransportState
    let viewportGeneration: Int
    let diagnosticsStore: MainWindowDiagnosticsStore

    var body: some View {
        MetalViewportView(
            session: session,
            viewportStateStore: viewportStateStore,
            transportState: transportState,
            diagnosticsStore: diagnosticsStore
        )
        .id(viewportGeneration)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

private struct ModuleSlotsPanel: View {
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    @ObservedObject var moduleCatalogStore: MainWindowModuleCatalogStore
    @ObservedObject var chromeStateStore: MainWindowChromeStateStore
    @Binding var importerTargetKind: ModuleKind
    @Binding var isImporterPresented: Bool

    private var availableFiles: [ModuleFile] {
        moduleCatalogStore.availableFiles
    }

    private var selectedFile: ModuleFile? {
        guard let selectedFileID = chromeStateStore.selectedFileID else { return nil }
        return availableFiles.first(where: { $0.id == selectedFileID })
    }

    private var mlPlaybackFamilyFiles: [ModuleKind: ModuleFile] {
        Dictionary(uniqueKeysWithValues: ModuleKind.allCases.compactMap { kind in
            guard let file = availableFiles.first(where: {
                $0.kind == kind
                    && $0.descriptor?.kind == kind.rawValue
                    && $0.descriptor?.moduleFamilyID == MLPlaybackModuleFamily.id
            }) else {
                return nil
            }
            return (kind, file)
        })
    }

    private var canAssignMLPlaybackFamily: Bool {
        mlPlaybackFamilyFiles.count == ModuleKind.allCases.count
    }

    private var isMLPlaybackFamilyActive: Bool {
        EditorViewSupport.activeModuleSet(
            store: editorSettingsStore,
            availableFiles: availableFiles
        ).isPlaybackModuleFamily
    }

    var body: some View {
        VStack(spacing: 8) {
            if canAssignMLPlaybackFamily {
                Button(isMLPlaybackFamilyActive ? "ML Playback Trio Active" : "Assign ML Playback Trio") {
                    assignMLPlaybackFamily()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(AppFramedButtonStyle(isMLPlaybackFamilyActive ? .standard : .prominent))
                .disabled(isMLPlaybackFamilyActive)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(ModuleKind.allCases) { kind in
                let assigned = EditorViewSupport.assignedModules(from: editorSettingsStore)[kind]
                let assignedFile = resolvedAssignedFile(for: kind, assigned: assigned)
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
                            Text(resolved.name)
                                .font(.caption2)
                                .foregroundStyle(assigned == nil ? .secondary : .primary)
                                .lineLimit(1)
                            assignmentStatusText(
                                assigned: assigned,
                                assignedFile: assignedFile,
                                resolved: resolved
                            )
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if assigned != nil {
                                Button("Clear") {
                                    editorSettingsStore.setAssignedModulePath(nil, for: kind)
                                }
                                .font(.caption)
                                .buttonStyle(AppFramedButtonStyle(.destructive))
                            }
                            Button("Choose File") {
                                importerTargetKind = kind
                                isImporterPresented = true
                            }
                            .font(.caption)
                            .buttonStyle(AppFramedButtonStyle())
                        }
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

    private func assignMLPlaybackFamily() {
        for kind in ModuleKind.allCases {
            guard let file = mlPlaybackFamilyFiles[kind] else { continue }
            editorSettingsStore.setAssignedModulePath(file.url.path, for: kind)
        }
    }

    private func resolvedAssignedFile(for kind: ModuleKind, assigned: URL?) -> ModuleFile? {
        guard let assigned else { return nil }
        return SimulationConfigurationDerivation.resolvedAssignedModuleFile(
            for: kind,
            assignedPath: assigned.path,
            availableFiles: availableFiles
        )
    }

    private func assignmentStatusText(
        assigned: URL?,
        assignedFile: ModuleFile?,
        resolved: ModuleDescriptor
    ) -> some View {
        let text: String
        let style: Color

        if let assigned, assignedFile == nil {
            text = "Incompatible assignment \(assigned.lastPathComponent); runtime uses \(resolved.name)."
            style = Color.red.opacity(0.9)
        } else if let assignedFile {
            text = "Using \(assignedFile.url.lastPathComponent)."
            style = .secondary
        } else {
            text = "No file assigned. Runtime falls back to the built-in default module."
            style = .secondary
        }

        return Text(text)
            .font(.caption2)
            .foregroundStyle(style)
    }
}

private struct ModuleSettingsPanelView: View {
    let kind: ModuleKind
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    @ObservedObject var physicsModuleSettingsStore: MainWindowPhysicsModuleSettingsStore
    @ObservedObject var moduleCatalogStore: MainWindowModuleCatalogStore
    @ObservedObject var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    let particleCountUICap: Int
    let particleCountEngineCap: Int

    private var availableFiles: [ModuleFile] {
        moduleCatalogStore.availableFiles
    }

    private var transportState: SimulationTransportState {
        runtimeConfigCoordinator.transportState
    }

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
                    } else if resolved.name == TypeMatrixLocalPhysicsSettings.moduleName {
                        TypeMatrixLocalPhysicsModuleSettingsPanel(
                            store: editorSettingsStore,
                            physicsModuleSettingsStore: physicsModuleSettingsStore,
                            transportState: transportState,
                            particleCountUICap: particleCountUICap
                        )
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
                    if resolved.name == ModuleCatalog.defaultOptimization.name
                        || resolved.name == FixedGridOptimizationModuleRuntime.moduleName {
                        OptimizationSettingsPanel(store: editorSettingsStore, resolvedOptimization: resolved)
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
            EventuallyAppliedToggle(title: "Inter-Particle Communication", appliedValue: Binding(
                get: { store.editorState.physicsState.allParticlesIntercommunicate },
                set: {
                    var next = store.editorState.physicsState
                    next.allParticlesIntercommunicate = $0
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
                tickBehavior: .visible,
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
                    get: {
                        TimeScaleControlMapping.controlValue(
                            forRuntimeScale: store.editorState.physicsState.timeScale
                        )
                    },
                    set: {
                        var next = store.editorState.physicsState
                        next.timeScale = TimeScaleControlMapping.runtimeScale(forControlValue: $0)
                        store.setPhysicsState(next)
                    }
                ),
                range: TimeScaleControlMapping.sliderRange,
                textEntryRange: TimeScaleControlMapping.textEntryRange,
                step: TimeScaleControlMapping.sliderStep,
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
                range: 0.002...0.015,
                step: 0.0005,
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
    let resolvedOptimization: ModuleDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            if resolvedOptimization.name == FixedGridOptimizationModuleRuntime.moduleName {
                EventuallyAppliedIntSlider(
                    title: "Subdivisions",
                    appliedValue: Binding(
                        get: { store.editorState.optimizationState.fixedGridSubdivisions },
                        set: {
                            var next = store.editorState.optimizationState
                            next.fixedGridSubdivisions = min(
                                FixedGridOptimizationModuleRuntime.maxSubdivisions,
                                max(1, $0)
                            )
                            next.fixedGridSubspaceCap = min(next.fixedGridSubspaceCap, next.fixedGridSubdivisions)
                            store.setOptimizationState(next)
                        }
                    ),
                    range: 1...FixedGridOptimizationModuleRuntime.maxSubdivisions
                )

                EventuallyAppliedIntSlider(
                    title: "Subspace Cap",
                    appliedValue: Binding(
                        get: {
                            min(
                                store.editorState.optimizationState.fixedGridSubspaceCap,
                                store.editorState.optimizationState.fixedGridSubdivisions
                            )
                        },
                        set: {
                            var next = store.editorState.optimizationState
                            next.fixedGridSubspaceCap = min(
                                max(1, $0),
                                next.fixedGridSubdivisions
                            )
                            store.setOptimizationState(next)
                        }
                    ),
                    range: 1...max(1, store.editorState.optimizationState.fixedGridSubdivisions)
                )

                EventuallyAppliedSegmentedPicker(
                    title: "Neighbor Read Mode",
                    appliedValue: Binding(
                        get: { store.editorState.optimizationState.fixedGridNeighborReadMode },
                        set: {
                            var next = store.editorState.optimizationState
                            next.fixedGridNeighborReadMode = $0
                            store.setOptimizationState(next)
                        }
                    ),
                    options: FixedGridNeighborReadMode.allCases,
                    optionTitle: { $0.title }
                )

                Text("Wrapped fixed-grid traversal publishes multi-range candidate spans. Raw mode reads canonical particle storage directly; scratch mode reads a packed fixed-grid scratch view.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Naive all-pairs traversal is the default optimization MVP.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LeaderCommunicationLogPanel: View {
    @ObservedObject var diagnosticsStore: MainWindowDiagnosticsStore

    private var entries: [LeaderCommunicationLogEntry] {
        diagnosticsStore.leaderCommunicationLogEntries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent leader-sweep range summaries from the active optimization runtime.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entries.isEmpty {
                Text("No leader communication entries recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("t=\(entry.recordedAt) target=\(entry.firstTargetIndex) interactions=\(entry.interactionCount)")
                                    .font(.caption.weight(.semibold))
                                Text("ranges=\(entry.workItemStart)..<\(entry.workItemStart + entry.workItemCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(minHeight: 180)
                .scrollIndicators(.visible)
            }
        }
    }
}

private struct FileViewPanel: View {
    @ObservedObject var editorSettingsStore: MainWindowEditorSettingsStore
    @ObservedObject var moduleCatalogStore: MainWindowModuleCatalogStore
    @ObservedObject var chromeStateStore: MainWindowChromeStateStore

    private var availableFiles: [ModuleFile] {
        moduleCatalogStore.availableFiles
    }

    private var selectedFile: ModuleFile? {
        guard let selectedFileID = chromeStateStore.selectedFileID else { return nil }
        return availableFiles.first(where: { $0.id == selectedFileID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Root: \(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Modules", isDirectory: true).path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Refresh", action: moduleCatalogStore.refresh)
                    .font(.caption2)
                    .buttonStyle(AppFramedButtonStyle())
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
                                    Button {
                                        chromeStateStore.setSelectedFileID(file.id)
                                    } label: {
                                        Text(file.url.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(
                                                        chromeStateStore.selectedFileID == file.id
                                                            ? AppControlPalette.accent.opacity(0.18)
                                                            : Color(nsColor: .quaternaryLabelColor).opacity(0.09)
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
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
                        .buttonStyle(AppFramedButtonStyle())
                        if editorSettingsStore.assignedModulePath(for: selectedFile.kind) != nil {
                            Button("Clear \(selectedFile.kind.displayName)") {
                                editorSettingsStore.setAssignedModulePath(nil, for: selectedFile.kind)
                            }
                            .font(.caption)
                            .buttonStyle(AppFramedButtonStyle(.destructive))
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
    @ObservedObject var runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator
    @ObservedObject var diagnosticsStore: MainWindowDiagnosticsStore
    @ObservedObject var chromeStateStore: MainWindowChromeStateStore
    let onStartInteractionSnapshot: () -> Void
    let onSetPerformanceReviewLoggingEnabled: (Bool) -> Void

    private var transportState: SimulationTransportState { runtimeConfigCoordinator.transportState }
    private var validationReport: RuntimeValidationReport { runtimeConfigCoordinator.validationReport }
    private var performanceMetrics: SimulationPerformanceMetrics { diagnosticsStore.performanceMetrics }
    private var panelsCount: Int { chromeStateStore.panels.count }
    private var collapsedPanelsCount: Int { chromeStateStore.collapsedPanelIDs.count }
    private var debugMetricsAreVisible: Bool {
        guard let inspectorPanel = chromeStateStore.panels.first(where: { $0.type == .inspector }) else { return false }
        return !chromeStateStore.collapsedPanelIDs.contains(inspectorPanel.id)
    }
    private var viewportRuntimeError: String? { diagnosticsStore.viewportRuntimeError }

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
            AppCheckboxToggle(
                "Performance Review Logging",
                isOn: Binding(
                    get: { performanceReviewLogger.isEnabled },
                    set: { onSetPerformanceReviewLoggingEnabled($0) }
                )
            )
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
            .buttonStyle(AppFramedButtonStyle())
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
                return "Adaptive logging on. Buffered entries: \(performanceReviewLogger.bufferedSampleCount). Latest combo: \(currentComboFileName)"
            }
            return "Adaptive logging on. Waiting for running simulation data."
        }
        return "Adaptive logging off."
    }
}
