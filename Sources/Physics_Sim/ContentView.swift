import SwiftUI
import UniformTypeIdentifiers
import Foundation

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

private enum ModuleKind: String, CaseIterable, Identifiable {
    case physics
    case visual
    case optimization

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .physics: return "Physics Module"
        case .visual: return "Visual Module"
        case .optimization: return "Optimization Module"
        }
    }

    var folderName: String {
        switch self {
        case .physics: return "Physics"
        case .visual: return "Visual"
        case .optimization: return "Optimization"
        }
    }
}

private enum DockPanelType: String, CaseIterable, Codable {
    case moduleSlots
    case fileView
    case inspector

    var title: String {
        switch self {
        case .moduleSlots: return "Module Slots"
        case .fileView: return "File View"
        case .inspector: return "Inspector"
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

private struct ModuleFile: Identifiable {
    let id: String
    let kind: ModuleKind
    let url: URL
}

private struct DockLayoutState: Codable {
    let panels: [DockPanel]
    let collapsedPanelIDs: [UUID]
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

private struct DockPanelDropDelegate: DropDelegate {
    let zone: DockZone
    let isHorizontal: Bool
    let panelIDsInOrder: [UUID]
    let panelFrames: [UUID: CGRect]
    @Binding var currentlyDraggingPanelID: UUID?
    @Binding var dropHighlights: [DockZone: Bool]
    @Binding var previewInsertionIndex: [DockZone: Int]
    let movePanel: (UUID, DockZone, Int?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        dropHighlights[zone] = true
        previewInsertionIndex[zone] = insertionIndex(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropHighlights[zone] = true
        previewInsertionIndex[zone] = insertionIndex(for: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropHighlights[zone] = false
        previewInsertionIndex[zone] = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            currentlyDraggingPanelID = nil
            dropHighlights[zone] = false
            previewInsertionIndex[zone] = nil
        }

        guard let dragID = currentlyDraggingPanelID else { return false }
        movePanel(dragID, zone, previewInsertionIndex[zone] ?? insertionIndex(for: info.location))
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
    @State private var panels: [DockPanel] = [
        DockPanel(id: UUID(), type: .moduleSlots, zone: .left),
        DockPanel(id: UUID(), type: .fileView, zone: .right),
        DockPanel(id: UUID(), type: .inspector, zone: .center),
    ]

    @State private var assignedModules: [ModuleKind: URL] = [:]
    @State private var availableFiles: [ModuleFile] = []
    @State private var selectedFileID: String?
    @State private var isImporterPresented = false
    @State private var importerTargetKind: ModuleKind = .physics
    @State private var hoveredGrabPanelID: UUID?
    @State private var dropHighlights: [DockZone: Bool] = [:]
    @State private var currentlyDraggingPanelID: UUID?
    @State private var previewInsertionIndex: [DockZone: Int] = [:]
    @State private var collapsedPanelIDs: Set<UUID> = []
    @State private var menuInsertionType: DockPanelType?
    @State private var menuHoverZone: DockZone?
    @State private var panelFramesByZone: [DockZone: [UUID: CGRect]] = [:]

    private let projectRootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    var body: some View {
        GeometryReader { geo in
            let sideWidth = min(max(geo.size.width * 0.22, 220), 340)

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                HStack(spacing: 10) {
                    dockColumn(.left)
                        .frame(width: sideWidth)

                    centerColumn
                        .frame(maxWidth: .infinity)

                    dockColumn(.right)
                        .frame(width: sideWidth)
                }
                .padding(12)
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
            refreshModuleFiles()
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
        .onReceive(NotificationCenter.default.publisher(for: .cancelAddDockPanel)) { _ in
            cancelMenuInsertionMode()
        }
        .onExitCommand {
            cancelMenuInsertionMode()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json, .data, .text],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                assignedModules[importerTargetKind] = url
            }
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Physics Sim")
                    .font(.headline)
                Spacer()
                Text("Checkpoint 00: Orbit Cube")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            MetalViewportView()
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

            dropZoneSurface(for: .center, panels: panelsInZone(.center))
                .frame(minHeight: 180)
        }
    }

    private func dockColumn(_ zone: DockZone) -> some View {
        dropZoneSurface(for: zone, panels: panelsInZone(zone))
    }

    private func dropZoneSurface(for zone: DockZone, panels: [DockPanel]) -> some View {
        let previews = previewPanelsInZone(zone, fallback: panels)
        let isAddMode = menuInsertionType != nil
        let isHoverTarget = menuHoverZone == zone
        let zoneFrames = panelFramesByZone[zone] ?? [:]
        let dropDelegate = DockPanelDropDelegate(
            zone: zone,
            isHorizontal: zone == .center,
            panelIDsInOrder: panels.map(\.id),
            panelFrames: zoneFrames,
            currentlyDraggingPanelID: $currentlyDraggingPanelID,
            dropHighlights: $dropHighlights,
            previewInsertionIndex: $previewInsertionIndex,
            movePanel: movePanel
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
                                    if !preview.isGhost {
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
                        VStack(alignment: .leading, spacing: 10) {
                        ForEach(previews) { preview in
                            panelCard(preview.panel, isGhost: preview.isGhost, isShifted: preview.isShifted)
                                .background {
                                    if !preview.isGhost {
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
            if dropHighlights[zone] == true || isAddMode {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        Color.accentColor.opacity(
                            isHoverTarget ? 0.14 : (isAddMode ? 0.07 : 0.10)
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    dropHighlights[zone] == true || isAddMode
                        ? Color.accentColor.opacity(0.85)
                        : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: (dropHighlights[zone] == true || isAddMode) ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .coordinateSpace(name: zone.rawValue)
        .onPreferenceChange(DockPanelFramesPreferenceKey.self) { framesByZone in
            panelFramesByZone.merge(framesByZone) { _, new in new }
        }
        .onHover { hovering in
            guard isAddMode else { return }
            if hovering {
                menuHoverZone = zone
            } else if menuHoverZone == zone {
                menuHoverZone = nil
            }
        }
        .highPriorityGesture(
            TapGesture().onEnded {
                guard let insertionType = menuInsertionType else { return }
                addPanel(type: insertionType, to: zone)
                cancelMenuInsertionMode()
            }
        )
        .onDrop(of: [.text], delegate: dropDelegate)
    }

    private func zoneHeader(for zone: DockZone) -> some View {
        HStack {
            Text(zone.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Spacer()

            Menu {
                ForEach(DockPanelType.allCases, id: \.rawValue) { type in
                    Button("Add \(type.title)") {
                        addPanel(type: type, to: zone)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))
                    )
            }
            .menuStyle(.borderlessButton)
            .help("Add panel")
        }
    }

    private func panelCard(_ panel: DockPanel, isGhost: Bool = false, isShifted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(panel.type.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isGhost ? .secondary : .primary)
                Spacer()
                if !isGhost {
                    Button {
                        togglePanelCollapsed(panel.id)
                    } label: {
                        Image(systemName: collapsedPanelIDs.contains(panel.id) ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(collapsedPanelIDs.contains(panel.id) ? "Expand panel" : "Collapse panel")
                }
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(hoveredGrabPanelID == panel.id ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            hoveredGrabPanelID == panel.id
                                ? Color.accentColor.opacity(0.18)
                                : Color(nsColor: .quaternaryLabelColor).opacity(0.16)
                        )
                )
                .contentShape(Rectangle())
                .opacity(isGhost ? 0.0 : 1.0)
                .allowsHitTesting(!isGhost)
                .overlay(alignment: .center) {
                    if !isGhost {
                        Color.clear
                            .contentShape(Rectangle())
                            .onDrag {
                                currentlyDraggingPanelID = panel.id
                                return NSItemProvider(object: panel.id.uuidString as NSString)
                            } preview: {
                                dragPreview(for: panel)
                            }
                    }
                }
                .onHover { hovering in
                    hoveredGrabPanelID = hovering ? panel.id : (hoveredGrabPanelID == panel.id ? nil : hoveredGrabPanelID)
                }
                if !isGhost {
                    Button(role: .destructive) {
                        removePanel(panel.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove panel")
                }
            }

            if !collapsedPanelIDs.contains(panel.id) || isGhost {
                switch panel.type {
                case .moduleSlots:
                    moduleSlotsBlock
                case .fileView:
                    fileViewBlock
                case .inspector:
                    inspectorBlock
                }
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

    private var moduleSlotsBlock: some View {
        VStack(spacing: 8) {
            ForEach(ModuleKind.allCases) { kind in
                let assigned = assignedModules[kind]
                Button {
                    importerTargetKind = kind
                    isImporterPresented = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(assigned?.lastPathComponent ?? "Click to choose file")
                            .font(.caption2)
                            .foregroundStyle(assigned == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let selected = selectedFile, selected.kind == kind {
                        Button("Assign Selected File") {
                            assignedModules[kind] = selected.url
                        }
                    }
                    if assigned != nil {
                        Button("Clear Assignment", role: .destructive) {
                            assignedModules.removeValue(forKey: kind)
                        }
                    }
                }
            }
        }
    }

    private var fileViewBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Root: \(modulesRootURL.path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Refresh") { refreshModuleFiles() }
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
                                    Button {
                                        selectedFileID = file.id
                                    } label: {
                                        HStack {
                                            Text(file.url.lastPathComponent)
                                                .font(.caption)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(
                                                    selectedFileID == file.id
                                                        ? Color.accentColor.opacity(0.22)
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

            if let selected = selectedFile {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected: \(selected.url.lastPathComponent)")
                        .font(.caption)
                        .lineLimit(1)
                    Button("Assign to \(selected.kind.displayName)") {
                        assignedModules[selected.kind] = selected.url
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var inspectorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assigned Modules")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(ModuleKind.allCases) { kind in
                HStack {
                    Text(kind.displayName)
                        .font(.caption)
                    Spacer()
                    Text(assignedModules[kind]?.lastPathComponent ?? "Unassigned")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var modulesRootURL: URL {
        projectRootURL.appendingPathComponent("Modules", isDirectory: true)
    }

    private var selectedFile: ModuleFile? {
        guard let selectedFileID else { return nil }
        return availableFiles.first(where: { $0.id == selectedFileID })
    }

    private var currentlyDraggingPanel: DockPanel? {
        guard let currentlyDraggingPanelID else { return nil }
        return panels.first(where: { $0.id == currentlyDraggingPanelID })
    }

    private func panelsInZone(_ zone: DockZone) -> [DockPanel] {
        panels.filter { $0.zone == zone }
    }

    private func movePanel(id: UUID, to zone: DockZone) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].zone = zone
    }

    private func addPanel(type: DockPanelType, to zone: DockZone) {
        panels.append(DockPanel(id: UUID(), type: type, zone: zone))
    }

    private func removePanel(_ id: UUID) {
        panels.removeAll { $0.id == id }
        collapsedPanelIDs.remove(id)
        if currentlyDraggingPanelID == id {
            currentlyDraggingPanelID = nil
        }
    }

    private func togglePanelCollapsed(_ id: UUID) {
        if collapsedPanelIDs.contains(id) {
            collapsedPanelIDs.remove(id)
        } else {
            collapsedPanelIDs.insert(id)
        }
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
            return
        }

        if indexInZone >= destinationCandidates.count {
            panels.insert(moved, at: destinationCandidates.last! + 1)
        } else {
            panels.insert(moved, at: destinationCandidates[indexInZone])
        }
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

    private func refreshModuleFiles() {
        let fm = FileManager.default
        var scanned: [ModuleFile] = []

        for kind in ModuleKind.allCases {
            let dir = modulesRootURL.appendingPathComponent(kind.folderName, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items where !url.hasDirectoryPath {
                scanned.append(ModuleFile(id: "\(kind.rawValue)|\(url.path)", kind: kind, url: url))
            }
        }

        availableFiles = scanned.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        if selectedFileID == nil || !availableFiles.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = availableFiles.first?.id
        }
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

        guard dropHighlights[zone] == true, let dragID = currentlyDraggingPanelID else {
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
            max(previewInsertionIndex[zone] ?? defaultInsertionIndex, 0),
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

    private func inferredInsertionIndex(for zone: DockZone) -> Int {
        guard let draggingID = currentlyDraggingPanelID else {
            return panels.filter { $0.zone == zone }.count
        }
        guard let draggedGlobalIndex = panels.firstIndex(where: { $0.id == draggingID }) else {
            return panels.filter { $0.zone == zone }.count
        }
        return panels.enumerated().reduce(into: 0) { partial, pair in
            let (idx, candidate) = pair
            if idx < draggedGlobalIndex && candidate.zone == zone && candidate.id != draggingID {
                partial += 1
            }
        }
    }

    private func cancelMenuInsertionMode() {
        menuInsertionType = nil
        menuHoverZone = nil
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
            panels = decoded.panels
        }
        collapsedPanelIDs = Set(decoded.collapsedPanelIDs)
    }
}
