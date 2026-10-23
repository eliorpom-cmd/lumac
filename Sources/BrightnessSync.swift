import AppKit
import CoreGraphics

/// Makes the external display follow the built-in display's brightness, which macOS adjusts
/// with the ambient light sensor.
///
/// Only changes of the built-in level are pushed, so a manual setting of the external display
/// holds until the built-in brightness moves again.
@MainActor
final class BrightnessSync: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "syncBrightness")
            update()
        }
    }

    private let display: DisplayController
    private var timer: Timer?
    private var lastBuiltIn: Double?

    /// DisplayServices has no public header and no stub in the SDK: it is loaded at runtime.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let getBrightness: GetBrightness? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    /// False on Macs without a built-in display or when DisplayServices is missing.
    var available: Bool { Self.getBrightness != nil && builtInDisplay() != nil }

    init(display: DisplayController) {
        self.display = display
        enabled = UserDefaults.standard.bool(forKey: "syncBrightness")
        update()
    }

    private func update() {
        timer?.invalidate()
        timer = nil
        lastBuiltIn = nil
        guard enabled else { return }
        // macOS sends no notification for sensor-driven changes: read the level once a second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        follow()
    }

    private func follow() {
        // Waits for the external display to be found, so the first level isn't lost.
        guard display.brightness != nil, let id = builtInDisplay(), let get = Self.getBrightness else { return }
        var value: Float = 0
        guard get(id, &value) == 0 else { return }
        let level = Double(value)
        // Ignore the noise of the sensor: 1 % of change is not worth a DDC frame.
        if let lastBuiltIn, abs(level - lastBuiltIn) < 0.01 { return }
        lastBuiltIn = level
        let range = DisplayController.range(of: .brightness)
        display.set(.brightness, to: min(range.upperBound, max(range.lowerBound, level)))
    }

    /// The active built-in display; nil with the lid closed, when it is off.
    private func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
