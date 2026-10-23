import ServiceManagement
import SwiftUI

@main
struct LumacApp: App {
    @StateObject private var lid = LidMonitor()
    @StateObject private var display: DisplayController
    @StateObject private var keys: BrightnessKeys
    @StateObject private var sync: BrightnessSync
    /// Bumped after each login item change so the toggle re-reads the real status.
    @State private var loginItemRevision = 0

    init() {
        let display = DisplayController()
        _display = StateObject(wrappedValue: display)
        _keys = StateObject(wrappedValue: BrightnessKeys(display: display))
        _sync = StateObject(wrappedValue: BrightnessSync(display: display))
    }

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
                if display.softwareDimming {
                    Text("Software dimming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This display doesn't accept brightness commands: the picture is darkened instead of the backlight.")
                }
                if let input = display.input {
                    InputRow(current: input) { display.selectInput($0) }
                }
                if display.levels.isEmpty, lid.externalDisplayName != nil {
                    Text("Brightness control unavailable for this display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                if sync.available {
                    Toggle("Follow the built-in display's brightness", isOn: $sync.enabled)
                }
                Toggle("Brightness keys control the external display", isOn: $keys.enabled)
                if keys.enabled, !keys.trusted {
                    Text("Allow Lumac in Privacy & Security > Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { keys.openAccessibilitySettings() }
                        .controlSize(.small)
                }
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
            Slider(value: Binding(get: { level }, set: change), in: DisplayController.range(of: code))
                .accessibilityLabel(title)
        }
        .foregroundStyle(.secondary)
    }

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

/// Input source picker. Switching moves the picture away from this Mac, so it asks first.
private struct InputRow: View {
    let current: UInt8
    let select: (UInt8) -> Void
    @State private var requested: (value: UInt8, name: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(DisplayController.inputs, id: \.value) { source in
                        Button {
                            if source.value != current { requested = source }
                        } label: {
                            if source.value == current {
                                Label(source.name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: source.name)
                            }
                        }
                    }
                } label: {
                    Text(verbatim: currentName)
                }
                .accessibilityLabel("Input")
            }

            if let requested {
                Text("Switch to \(requested.name)? This Mac's picture will disappear from the display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { self.requested = nil }
                    Button("Switch") {
                        select(requested.value)
                        self.requested = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
    }

    private var currentName: String {
        DisplayController.inputs.first { $0.value == current }?.name ?? String(format: "Input 0x%02X", current)
    }
}
