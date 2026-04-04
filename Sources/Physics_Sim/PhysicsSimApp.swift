import SwiftUI
import AppKit
import Foundation

extension Notification.Name {
    static let requestAddDockPanel = Notification.Name("PhysicsSim.RequestAddDockPanel")
    static let cancelInProgressOperation = Notification.Name("PhysicsSim.CancelInProgressOperation")
    static let rebuildViewport = Notification.Name("PhysicsSim.RebuildViewport")
}

enum AppMenuEventKey {
    static let panelType = "panelType"
}

enum LaunchProgressStage: String, CaseIterable {
    case starting
    case loadingSession
    case loadingEditorStores
    case buildingCoordinator
    case finalizingUI

    var title: String {
        switch self {
        case .starting:
            return "Starting application"
        case .loadingSession:
            return "Creating simulation session"
        case .loadingEditorStores:
            return "Loading editor and module settings"
        case .buildingCoordinator:
            return "Building runtime coordinator"
        case .finalizingUI:
            return "Finalizing main window"
        }
    }

    var detail: String {
        switch self {
        case .starting:
            return "Bootstrapping the single-window shell."
        case .loadingSession:
            return "Compiling Metal runtime state and constructing the main simulation session."
        case .loadingEditorStores:
            return "Loading persisted editor state, diagnostics, module settings, and module catalog data."
        case .buildingCoordinator:
            return "Connecting editor settings to the runtime coordinator."
        case .finalizingUI:
            return "Preparing the main content view and viewport host."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didEmitReady = false

    private var isHeadless: Bool {
        ProcessInfo.processInfo.environment["PHYSICS_SIM_HEADLESS"] == "1"
    }

    private func emitReadyIfNeeded(_ marker: String = "APP_READY") {
        guard !didEmitReady else { return }
        didEmitReady = true
        fputs("\(marker)\n", stderr)
        fflush(stderr)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isHeadless {
            NSApp.setActivationPolicy(.prohibited)
            emitReadyIfNeeded("APP_HEADLESS_READY")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        TestingCommandHandler.shared.start()
        emitReadyIfNeeded()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainWindowViewportStateStore.shared.flushPersistence()
        PerformanceReviewLogger.shared.flushBufferedSamples()
    }
}

@main
struct PhysicsSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("settings.viewport.invertScrollZoom") private var invertScrollZoom = true
    @AppStorage("settings.viewport.orbitInputMode") private var orbitInputModeRaw = ProgramSettingsStore.OrbitInputMode.clickThenDrag.rawValue
    @AppStorage("settings.ui.panelDragInputMode") private var uiPanelDragInputModeRaw = ProgramSettingsStore.UIPanelDragInputMode.clickThenDrag.rawValue
    @State private var contentDependencies: Result<MainWindowContentDependencies, Error>?
    @State private var launchProgressStage: LaunchProgressStage = .starting

    var body: some Scene {
        Window("Particularity", id: "main-window") {
            Group {
                switch contentDependencies {
                case nil:
                    LaunchProgressView(stage: launchProgressStage)
                case .success(let dependencies):
                    ContentView(dependencies: dependencies)
                case .failure(let error):
                    LaunchFailureView(message: error.localizedDescription)
                }
            }
            .frame(minWidth: 900, minHeight: 620)
            .task {
                guard contentDependencies == nil else { return }
                do {
                    launchProgressStage = .starting
                    await Task.yield()
                    let dependencies = try await MainWindowContentDependencies.load { stage in
                        launchProgressStage = stage
                    }
                    contentDependencies = .success(dependencies)
                } catch {
                    contentDependencies = .failure(error)
                }
            }
        }
        .commands {
            CommandMenu("Settings") {
                Menu("Input") {
                    Menu("Camera") {
                        Toggle(
                            "Invert Scroll Zoom",
                            isOn: $invertScrollZoom
                        )

                        Picker(
                            "Orbit Input Mode",
                            selection: Binding(
                                get: {
                                    ProgramSettingsStore.OrbitInputMode(rawValue: orbitInputModeRaw) ?? .clickThenDrag
                                },
                                set: { orbitInputModeRaw = $0.rawValue }
                            )
                        ) {
                            ForEach(ProgramSettingsStore.OrbitInputMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    Menu("UI") {
                        Picker(
                            "Panel Drag Input Mode",
                            selection: Binding(
                                get: {
                                    ProgramSettingsStore.UIPanelDragInputMode(rawValue: uiPanelDragInputModeRaw) ?? .clickThenDrag
                                },
                                set: { uiPanelDragInputModeRaw = $0.rawValue }
                            )
                        ) {
                            ForEach(ProgramSettingsStore.UIPanelDragInputMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                }
            }

            CommandGroup(after: .windowArrangement) {
                Divider()
                Menu("Add Panel") {
                    Menu("Core") {
                        Button("Module Slots") {
                            NotificationCenter.default.post(
                                name: .requestAddDockPanel,
                                object: nil,
                                userInfo: [AppMenuEventKey.panelType: "moduleSlots"]
                            )
                        }
                        Button("File View") {
                            NotificationCenter.default.post(
                                name: .requestAddDockPanel,
                                object: nil,
                                userInfo: [AppMenuEventKey.panelType: "fileView"]
                            )
                        }
                    }
                    Menu("Diagnostics") {
                        Button("Inspector") {
                            NotificationCenter.default.post(
                                name: .requestAddDockPanel,
                                object: nil,
                                userInfo: [AppMenuEventKey.panelType: "inspector"]
                            )
                        }
                    }
                }
                Button("Cancel Operation") {
                    NotificationCenter.default.post(name: .cancelInProgressOperation, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

private struct LaunchProgressView: View {
    let stage: LaunchProgressStage
    @State private var appearedAt = Date()
    @State private var now = Date()

    private var elapsedSeconds: TimeInterval {
        now.timeIntervalSince(appearedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Launching")
                .font(.title2.bold())
            ProgressView()
                .controlSize(.regular)
            VStack(alignment: .leading, spacing: 8) {
                Text(stage.title)
                    .font(.headline)
                Text(stage.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Elapsed: \(String(format: "%.1f", elapsedSeconds))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(elapsedSeconds >= 15 ? Color.orange.opacity(0.95) : .secondary)
                if elapsedSeconds < 0.25 {
                    Text("If elapsed time freezes, the app is blocked in the stage shown below.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LaunchProgressStage.allCases, id: \.rawValue) { candidate in
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: candidate))
                            .foregroundStyle(iconColor(for: candidate))
                            .frame(width: 14)
                        Text(candidate.title)
                            .font(.caption)
                            .foregroundStyle(candidate == stage ? .primary : .secondary)
                    }
                }
            }
        }
        .onAppear {
            appearedAt = Date()
            now = appearedAt
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                now = Date()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusText: String {
        if elapsedSeconds >= 15 {
            return "This stage is taking longer than expected. The app may still be working, but it may also be stuck here."
        }
        if elapsedSeconds >= 5 {
            return "Still working on the current launch stage."
        }
        return "Actively loading."
    }

    private func iconName(for candidate: LaunchProgressStage) -> String {
        if candidate == stage {
            return "arrowtriangle.right.fill"
        }
        if isComplete(candidate) {
            return "checkmark.circle.fill"
        }
        return "circle"
    }

    private func iconColor(for candidate: LaunchProgressStage) -> Color {
        if candidate == stage {
            return .accentColor
        }
        if isComplete(candidate) {
            return Color.green.opacity(0.9)
        }
        return .secondary
    }

    private func isComplete(_ candidate: LaunchProgressStage) -> Bool {
        guard let candidateIndex = LaunchProgressStage.allCases.firstIndex(of: candidate),
              let stageIndex = LaunchProgressStage.allCases.firstIndex(of: stage) else {
            return false
        }
        return candidateIndex < stageIndex
    }
}

private struct LaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Launch Failed")
                .font(.title2.bold())
            Text(message)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("The app stayed running so the failure could be inspected instead of trapping during startup.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
