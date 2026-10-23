import ServiceManagement
import SwiftUI

@main
struct LumacApp: App {
    @StateObject private var lid = LidMonitor()
    @StateObject private var display = DisplayController()
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

                ForEach(DisplayController.continuous, id: \.self) { code in
                    if let level = display.levels[code] {
                        LevelRow(code: code, level: level) { display.set(code, to: $0) }
                    }
                }
                if display.levels.isEmpty, lid.externalDisplayName != nil {
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
            .onAppear { display.refresh() }
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

/// One slider per DDC control, with its symbol in place of a text label.
private struct LevelRow: View {
    let code: VCP
    let level: Double
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
            Slider(value: Binding(get: { level }, set: change), in: range)
                .accessibilityLabel(title)
        }
        .foregroundStyle(.secondary)
    }

    /// Some displays turn the backlight off at 0, which looks like a dead screen.
    private var range: ClosedRange<Double> { code == .brightness ? 0.1...1 : 0...1 }

    private var symbol: String {
        switch code {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2"
        case .input: return "rectangle.connected.to.line.below"
        }
    }

    private var title: LocalizedStringKey {
        switch code {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .volume: return "Volume"
        case .input: return "Input"
        }
    }
}
