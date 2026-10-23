import AppKit
import ApplicationServices
import CoreGraphics

/// Lets the keyboard's brightness keys drive the external display when the pointer is on it,
/// with the macOS indicator. On the built-in display, the keys keep their usual effect.
///
/// Intercepting the keys takes an event tap, which needs the Accessibility permission.
@MainActor
final class BrightnessKeys: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "brightnessKeys")
            update(prompt: enabled)
        }
    }
    @Published private(set) var trusted = AXIsProcessTrusted()

    private let display: DisplayController
    private let sync: BrightnessSync
    private var tap: CFMachPort?
    private var trustTimer: Timer?

    /// One key press moves the level by 1/16, like the built-in display.
    private static let step = 1.0 / 16
    /// NSEvent.EventType.systemDefined, which carries the media and brightness keys.
    private static let systemDefined: UInt32 = 14
    /// NSEvent subtype of auxiliary control buttons (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    private static let auxControlButtons: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP and NX_KEYTYPE_BRIGHTNESS_DOWN from IOKit's ev_keymap.h.
    private static let brightnessUp = 2
    private static let brightnessDown = 3

    init(display: DisplayController, sync: BrightnessSync) {
        self.display = display
        self.sync = sync
        enabled = UserDefaults.standard.bool(forKey: "brightnessKeys")
        update(prompt: false)
    }

    /// Opens the Accessibility pane of System Settings, where Lumac must be allowed.
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Tap

    /// Starts or stops the tap. Without the permission, checks again every 2 s until it is granted.
    private func update(prompt: Bool) {
        trusted = prompt
            ? AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            : AXIsProcessTrusted()
        trustTimer?.invalidate()
        trustTimer = nil

        guard enabled else { stopTap(); return }
        guard trusted else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.update(prompt: false)
                }
            }
            return
        }
        startTap()
    }

    private func startTap() {
        guard tap == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << Self.systemDefined,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue()
                // The tap runs on the main run loop.
                let consumed = MainActor.assumeIsolated { keys.handle(type: type, event: event) }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    /// Returns true when the event was used for a display and must not reach macOS.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables a tap that is too slow or when secure input starts: turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == Self.systemDefined,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtons
        else { return false }

        let key = (nsEvent.data1 & 0xFFFF_0000) >> 16
        guard key == Self.brightnessUp || key == Self.brightnessDown else { return false }
        let screen = targetScreen()
        let builtInTarget = screen.map(Self.isBuiltIn) ?? false
        // Key down (0xA) and repeats move the level; key up (0xB) is swallowed with them.
        let keyDown = (nsEvent.data1 & 0xFF00) >> 8 == 0xA
        let delta = key == Self.brightnessUp ? Self.step : -Self.step

        // The built-in display keeps the behaviour and indicator of macOS.
        if builtInTarget { return false }

        guard keyDown else { return display.brightness != nil }
        guard display.step(.brightness, by: delta), let level = display.brightness else { return false }
        sync.externalAdjusted(to: level)
        if let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            SystemOSD.showBrightness(level, on: id)
        }
        return true
    }

    /// The screen under the pointer; with the lid closed, the pointer can only be on an external one.
    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.screens.first { !Self.isBuiltIn($0) }
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            .map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }
}
