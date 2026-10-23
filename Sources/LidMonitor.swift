import AppKit
import CoreGraphics
import IOKit
import os

/// Puts the Mac to sleep when the lid is closed while an external display is connected,
/// instead of letting macOS switch to clamshell mode.
///
/// Event-driven replacement for noclamshell: noclamshell polled every 5 s and, right after
/// a wake, often read a stale "lid closed" state and slept the Mac again.
@MainActor
final class LidMonitor: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "sleepOnLidClose")
            if !enabled { pendingCheck?.cancel() }
        }
    }
    @Published private(set) var lastSleep: Date?
    @Published private(set) var externalDisplayName: String?

    private let log = Logger(subsystem: "dev.byelior.lumac", category: "lid")
    private let rootDomain: io_service_t
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Only one delayed check at a time. DispatchTime stops while the Mac sleeps, so a check
    /// left pending would otherwise fire right after the next wake, when the lid state is stale.
    private var pendingCheck: DispatchWorkItem?

    /// iokit_family_msg(sub_iokit_powermanagement, 0x100): the macro is not imported into Swift.
    private static let clamshellStateChange: UInt32 = 0xE003_4100
    private static let clamshellClosedBit = 1 << 0
    private static let clamshellSleepBit = 1 << 1

    init() {
        enabled = UserDefaults.standard.object(forKey: "sleepOnLidClose") as? Bool ?? true
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        subscribeToClamshell()
        refreshDisplay()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pendingCheck?.cancel() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplay() }
        }
    }

    // MARK: - Events

    private func subscribeToClamshell() {
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log.error("IOPMrootDomain unavailable")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { refcon, _, type, argument in
            guard let refcon, type == LidMonitor.clamshellStateChange else { return }
            let state = Int(bitPattern: argument)
            let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.clamshellChanged(state: state) }
        }, refcon, &notifier)
        if result != KERN_SUCCESS {
            log.error("Lid notifications unavailable: \(result, privacy: .public)")
        }
    }

    private func clamshellChanged(state: Int) {
        let closed = state & Self.clamshellClosedBit != 0
        let systemWillSleep = state & Self.clamshellSleepBit != 0
        log.info("Lid \(closed ? "closed" : "open", privacy: .public), system sleep: \(systemWillSleep, privacy: .public)")
        guard closed else {
            pendingCheck?.cancel()
            return
        }
        // macOS already sleeps on its own when no external display keeps it awake.
        guard !systemWillSleep else { return }
        // Short delay so the display configuration settles before checking again.
        schedule(after: 1, reason: "lid closed")
    }

    /// Covers a wake with the lid closed (external keyboard or mouse): the Mac goes back to sleep.
    /// The check waits a few seconds because the lid state is stale right after a wake;
    /// opening the lid in the meantime cancels it.
    private func didWake() {
        refreshDisplay()
        schedule(after: 8, reason: "woke with lid closed")
    }

    private func schedule(after seconds: Double, reason: String) {
        pendingCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.sleepIfClamshell(reason: reason) }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: check)
    }

    // MARK: - Checks

    private func sleepIfClamshell(reason: String) {
        guard enabled else { return }
        // Two independent signals must agree: the lid sensor and the built-in panel being off.
        guard lidIsClosed(), !builtInDisplayIsActive(), externalDisplay() != nil else {
            log.info("Sleep skipped (\(reason, privacy: .public)): lid open or no external display")
            return
        }
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        do {
            try pmset.run()
            log.info("Sleeping: \(reason, privacy: .public)")
            lastSleep = Date()
        } catch {
            log.error("pmset sleepnow failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func lidIsClosed() -> Bool {
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool ?? false
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    private func builtInDisplayIsActive() -> Bool {
        activeDisplays().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    private func externalDisplay() -> CGDirectDisplayID? {
        activeDisplays().first { CGDisplayIsBuiltin($0) == 0 }
    }

    private func refreshDisplay() {
        guard let id = externalDisplay() else {
            externalDisplayName = nil
            return
        }
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
        }
        externalDisplayName = screen?.localizedName
    }
}
