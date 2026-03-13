import SwiftUI
import AppKit
import Foundation

extension Notification.Name {
    static let requestAddDockPanel = Notification.Name("PhysicsSim.RequestAddDockPanel")
    static let cancelInProgressOperation = Notification.Name("PhysicsSim.CancelInProgressOperation")
}

enum AppMenuEventKey {
    static let panelType = "panelType"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isHeadless: Bool {
        ProcessInfo.processInfo.environment["PHYSICS_SIM_HEADLESS"] == "1"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isHeadless {
            NSApp.setActivationPolicy(.prohibited)
            fputs("APP_HEADLESS_READY\n", stderr)
            fflush(stderr)
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct PhysicsSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("settings.viewport.invertScrollZoom") private var invertScrollZoom = true
    @AppStorage("settings.viewport.orbitInputMode") private var orbitInputModeRaw = ProgramSettingsStore.OrbitInputMode.clickThenDrag.rawValue
    @AppStorage("settings.ui.panelDragInputMode") private var uiPanelDragInputModeRaw = ProgramSettingsStore.UIPanelDragInputMode.clickThenDrag.rawValue

    var body: some Scene {
        Window("Particularity", id: "main-window") {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
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
