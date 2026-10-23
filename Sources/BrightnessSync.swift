import AppKit
import CoreGraphics

/// Makes the external display follow the built-in display's brightness, which macOS adjusts
/// with the ambient light sensor.
///
/// The external display gets the level that matches the built-in one, from a measured curve
/// when there is one, plus an offset, since two displays at the same level rarely look equally bright. Adjusting the external display by hand while following
/// sets that offset, so the pair keeps the balance the user chose.
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
    /// Gap the user set by hand, on top of the curve. Without a measured curve, external displays
    /// usually look darker at the same level, hence the default.
    private var offset: Double {
        get { UserDefaults.standard.object(forKey: "syncOffset") as? Double ?? (Self.curve.isEmpty ? 0.15 : 0) }
        set { UserDefaults.standard.set(newValue, forKey: "syncOffset") }
    }

    /// Pairs (built-in level, external level) that look equally bright, measured by
    /// Tools/brightness-calibration. Empty until a calibration is run.
    private static var curve: [(builtIn: Double, external: Double)] {
        let pairs = UserDefaults.standard.array(forKey: "syncCurve") as? [[Double]] ?? []
        return pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }.sorted { $0.builtIn < $1.builtIn }
    }

    /// External level that looks as bright as `level` on the built-in display, interpolated
    /// between the measured pairs. Same level when there is no curve.
    static func matched(_ level: Double) -> Double {
        let curve = curve
        guard let first = curve.first, let last = curve.last else { return level }
        if level <= first.builtIn { return first.external }
        if level >= last.builtIn { return last.external }
        let upper = curve.firstIndex { $0.builtIn >= level }!
        let (a, b) = (curve[upper - 1], curve[upper])
        return a.external + (b.external - a.external) * (level - a.builtIn) / (b.builtIn - a.builtIn)
    }

    /// False on Macs without a built-in display or when DisplayServices is missing.
    var available: Bool { BuiltInBrightness.read() != nil }

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
        guard display.brightness != nil, let level = BuiltInBrightness.read() else { return }
        // Ignore the noise of the sensor: 1 % of change is not worth a DDC frame.
        if let lastBuiltIn, abs(level - lastBuiltIn) < 0.01 { return }
        lastBuiltIn = level
        let range = DisplayController.range(of: .brightness)
        display.set(.brightness, to: min(range.upperBound, max(range.lowerBound, Self.matched(level) + offset)))
    }

    /// Called when the user sets the external display's brightness by hand: keeps that gap.
    func externalAdjusted(to level: Double) {
        guard enabled, let builtIn = BuiltInBrightness.read() else { return }
        offset = level - Self.matched(builtIn)
        lastBuiltIn = builtIn
    }
}
