import SwiftUI
import AppKit

@main
struct FontwerkApp: App {
    @StateObject private var store = LibraryStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Fontwerk") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.refreshActivationStates()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Schriften importieren …") { store.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("FontExplorer-Bibliothek übernehmen …") { store.showFEXImport = true }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
