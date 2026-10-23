import ServiceManagement
import SwiftUI

@main
struct LumacApp: App {
    @StateObject private var lid = LidMonitor()
    @StateObject private var brightness = BrightnessController()
    /// Bumped after each login item change so the toggle re-reads the real status.
    @State private var loginItemRevision = 0

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                if let name = lid.externalDisplayName {
                    Text(verbatim: name)
                        .font(.headline)
                } else {
                    Text("No external display")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                if let level = brightness.brightness {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min")
                        // Some displays turn the backlight off at 0, which looks like a dead screen.
                        Slider(value: Binding(get: { level }, set: { brightness.set($0) }), in: 0.1...1)
                            .accessibilityLabel("Brightness")
                        Image(systemName: "sun.max")
                    }
                    .foregroundStyle(.secondary)
                } else if lid.externalDisplayName != nil {
                    Text("Brightness control unavailable for this display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle("Sleep when the lid closes", isOn: $lid.enabled)
                if let lastSleep = lid.lastSleep {
                    Text("Last sleep: \(lastSleep.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Open at login", isOn: openAtLogin)

                Divider()

                Button("Quit Lumac") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .toggleStyle(.checkbox)
            .padding(14)
            .frame(width: 280)
            .onAppear { brightness.refresh() }
        } label: {
            Image("MenuIcon")
                .accessibilityLabel("Lumac")
        }
        .menuBarExtraStyle(.window)
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
