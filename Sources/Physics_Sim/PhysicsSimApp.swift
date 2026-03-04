import SwiftUI
import AppKit
import Foundation

extension Notification.Name {
    static let requestAddDockPanel = Notification.Name("PhysicsSim.RequestAddDockPanel")
    static let cancelAddDockPanel = Notification.Name("PhysicsSim.CancelAddDockPanel")
}

enum AppMenuEventKey {
    static let panelType = "panelType"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isHeadless: Bool {
        ProcessInfo.processInfo.environment["PHYSICS_SIM_HEADLESS"] == "1"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    var body: some Scene {
        Window("Physics Sim", id: "main-window") {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Divider()
                Menu("Add Panel") {
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
                    Button("Inspector") {
                        NotificationCenter.default.post(
                            name: .requestAddDockPanel,
                            object: nil,
                            userInfo: [AppMenuEventKey.panelType: "inspector"]
                        )
                    }
                }
                Button("Cancel Add Panel") {
                    NotificationCenter.default.post(name: .cancelAddDockPanel, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
