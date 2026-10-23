import AppKit
import CoreGraphics

/// Brightness of the built-in display, read and set through DisplayServices.
@MainActor
final class BuiltInBrightness: ObservableObject {
    /// 0...1, nil with the lid closed or when DisplayServices is missing.
    @Published private(set) var level: Double?

    private var timer: Timer?

    /// DisplayServices has no public header and no stub in the SDK: it is loaded at runtime.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightness? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let setBrightness: SetBrightness? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    init() {
        refresh()
        // macOS sends no notification for keyboard or sensor changes: read the level once a second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let current = Self.read()
        if current != level { level = current }
    }

    @discardableResult
    func set(_ value: Double) -> Bool {
        guard let id = Self.displayID(), let set = Self.setBrightness else { return false }
        let clamped = min(1, max(0, value))
        guard set(id, Float(clamped)) == 0 else { return false }
        level = clamped
        return true
    }

    /// Moves the level by `delta`. Returns false when the built-in display can't be set.
    @discardableResult
    func step(by delta: Double) -> Bool {
        guard let current = Self.read() else { return false }
        return set(current + delta)
    }

    static func read() -> Double? {
        guard let id = displayID(), let get = getBrightness else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0 else { return nil }
        return Double(value)
    }

    /// The active built-in display; nil with the lid closed, when it is off.
    static func displayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
