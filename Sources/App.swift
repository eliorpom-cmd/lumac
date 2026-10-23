import ServiceManagement
import SwiftUI

@main
struct LumacApp: App {
    @StateObject private var lid = LidMonitor()
    @StateObject private var display: DisplayController
    @StateObject private var keys: BrightnessKeys
    @StateObject private var sync: BrightnessSync
    @StateObject private var builtIn: BuiltInBrightness

    init() {
        let display = DisplayController()
        let builtIn = BuiltInBrightness()
        let sync = BrightnessSync(display: display)
        _display = StateObject(wrappedValue: display)
        _builtIn = StateObject(wrappedValue: builtIn)
        _sync = StateObject(wrappedValue: sync)
        _keys = StateObject(wrappedValue: BrightnessKeys(display: display, builtIn: builtIn, sync: sync))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(lid: lid, display: display, builtIn: builtIn, keys: keys, sync: sync)
        } label: {
            Image("MenuIcon")
                .accessibilityLabel("Lumac")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Content of the menu bar panel.
struct PanelView: View {
    @ObservedObject var lid: LidMonitor
    @ObservedObject var display: DisplayController
    @ObservedObject var builtIn: BuiltInBrightness
    @ObservedObject var keys: BrightnessKeys
    @ObservedObject var sync: BrightnessSync
    /// Bumped after each login item change so the toggle re-reads the real status.
    @State private var loginItemRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayHeader(
                symbol: "display",
                name: lid.externalDisplayName.map { Text(verbatim: $0) } ?? Text("No external display"),
                dimmed: lid.externalDisplayName == nil,
                subtitle: display.softwareDimming ? Text("Software dimming") : nil
            )
            .help(display.softwareDimming ? Text("This display doesn't accept brightness commands: the picture is darkened instead of the backlight.") : Text(verbatim: ""))

            if lid.externalDisplayName != nil {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DisplayController.continuous, id: \.self) { code in
                        if let level = display.levels[code] {
                            LevelRow(code: code, level: level) { value in
                                display.set(code, to: value)
                                if code == .brightness { sync.externalAdjusted(to: value) }
                            }
                        }
                    }
                    if let input = display.input {
                        InputRow(current: input) { display.selectInput($0) }
                    }
                    if display.levels.isEmpty {
                        Text("Brightness control unavailable for this display")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 12)
            }

            if let level = builtIn.level {
                DisplayHeader(symbol: "laptopcomputer", name: Text("Built-in display"), dimmed: false, subtitle: nil)
                    .padding(.top, lid.externalDisplayName == nil ? 8 : 0)
                LevelRow(code: .brightness, level: level) { builtIn.set($0) }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 12)
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                if sync.available {
                    SwitchRow("Follow the built-in display's brightness", isOn: $sync.enabled)
                }
                SwitchRow("Brightness keys adjust the display under the pointer", isOn: $keys.enabled)
                if keys.enabled, !keys.trusted {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Allow Lumac in Privacy & Security > Accessibility.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open Settings") { keys.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
                SwitchRow("Sleep when the lid closes", isOn: $lid.enabled)
                if let lastSleep = lid.lastSleep {
                    Text("Last sleep: \(lastSleep.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                SwitchRow("Open at login", isOn: openAtLogin)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)

            Divider().padding(.vertical, 4)

            MenuRowButton(title: "Quit Lumac", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { display.refresh() }
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

/// Rounded card with a display's symbol and name, like the display modules of Control Center.
private struct DisplayHeader: View {
    let symbol: String
    let name: Text
    let dimmed: Bool
    let subtitle: Text?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(dimmed ? .secondary : .primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                name
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                if let subtitle {
                    subtitle
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Titled slider with its value, one per DDC control.
private struct LevelRow: View {
    let code: VCP
    let level: Double
    let change: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(level.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: Binding(get: { level }, set: change), in: DisplayController.range(of: code))
                    .accessibilityLabel(title)
                    .accessibilityValue(level.formatted(.percent.precision(.fractionLength(0))))
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Input source")
                Spacer()
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
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Input source")
            }

            if let requested {
                Text("Switch to \(requested.name)? This Mac's picture will disappear from the display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
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

/// Label on the left, switch on the right; long labels wrap instead of being cut.
private struct SwitchRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Full-width row that highlights on hover, like a menu item.
private struct MenuRowButton: View {
    let title: LocalizedStringKey
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: shortcut)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
