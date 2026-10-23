import CoreGraphics

/// Dims a display by scaling its gamma table, for displays that don't answer over DDC.
/// The backlight stays the same: only the picture gets darker.
@MainActor
final class SoftwareDimmer {
    private(set) var displayID: CGDirectDisplayID?
    /// The display's own table, scaled on each change so its color profile is kept.
    private var original: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])?

    /// Applies `level` (0...1) to `id`. Called again after display changes and wakes,
    /// since macOS resets gamma tables then.
    func apply(_ level: Double, to id: CGDirectDisplayID) {
        if id != displayID || original == nil {
            // Start from the profile's table, not from a table this app already dimmed.
            CGDisplayRestoreColorSyncSettings()
            displayID = id
            original = Self.table(of: id)
        }
        guard let original else { return }
        let scale = CGGammaValue(level)
        let red = original.red.map { $0 * scale }
        let green = original.green.map { $0 * scale }
        let blue = original.blue.map { $0 * scale }
        CGSetDisplayTransferByTable(id, UInt32(red.count), red, green, blue)
    }

    /// Puts every display back on its ColorSync profile.
    func restore() {
        guard displayID != nil else { return }
        CGDisplayRestoreColorSyncSettings()
        displayID = nil
        original = nil
    }

    /// Forgets the captured table after macOS reset it, so the next `apply` captures it again.
    func invalidate() {
        original = nil
    }

    private static func table(of id: CGDirectDisplayID) -> (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        return (Array(red.prefix(Int(count))), Array(green.prefix(Int(count))), Array(blue.prefix(Int(count))))
    }
}
