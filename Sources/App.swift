import ServiceManagement
import SwiftUI

@main
struct LumacApp: App {
    @StateObject private var lid = LidMonitor()
    /// Bumped after each login item change so the toggle re-reads the real status.
    @State private var loginItemRevision = 0

    var body: some Scene {
        MenuBarExtra {
            if let name = lid.externalDisplayName {
                Text(verbatim: name)
            } else {
                Text("No external display")
            }

            Divider()

            Toggle("Sleep when the lid closes", isOn: $lid.enabled)
            if let lastSleep = lid.lastSleep {
                Text("Last sleep: \(lastSleep.formatted(date: .omitted, time: .shortened))")
            }

            Divider()

            Toggle("Open at login", isOn: openAtLogin)
            Button("Quit Lumac") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image("MenuIcon")
                .accessibilityLabel("Lumac")
        }
    }

    /// Reads the status from the system each time, so changes made in System Settings show up.
    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { _ = loginItemRevision; return SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {}
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                loginItemRevision += 1
            }
        )
    }
}
