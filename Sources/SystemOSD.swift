import CoreGraphics
import Foundation
import ObjectiveC

/// The macOS brightness indicator, shown on a given display through the private OSD framework.
@MainActor
enum SystemOSD {
    private typealias Show = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
    private static let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
    private static let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY) != nil,
              let type = objc_getClass("OSDManager") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("sharedManager")),
              let manager = type.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject,
              manager.responds(to: selector)
        else { return nil }
        return manager
    }()

    /// Image 1 is the brightness symbol; the level is drawn as 16 segments, like the built-in display.
    static func showBrightness(_ level: Double, on display: CGDirectDisplayID) {
        guard let manager else { return }
        let show = unsafeBitCast(manager.method(for: selector), to: Show.self)
        show(manager, selector, 1, display, 0x1F4, 1000, UInt32((level * 16).rounded()), 16, false)
    }
}
