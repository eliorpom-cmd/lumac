import AppKit
import os

/// Settings of the external display over DDC/CI (brightness, contrast…), for the menu bar panel.
@MainActor
final class DisplayController: ObservableObject {
    /// 0...1 for each control the display answers, missing while unsupported or unreachable.
    @Published private(set) var levels: [VCP: Double] = [:]
    /// Current input source (VCP 0x60 value), nil when the display doesn't report it.
    @Published private(set) var input: UInt8?

    /// Continuous controls read on each refresh, in panel order.
    /// A display without speakers fails the volume read, so its row stays hidden.
    nonisolated static let continuous: [VCP] = [.brightness, .contrast, .volume]

    /// Common input sources from the MCCS standard. Displays accept only the ones they have.
    nonisolated static let inputs: [(value: UInt8, name: String)] = [
        (0x0F, "DisplayPort 1"), (0x10, "DisplayPort 2"), (0x11, "HDMI 1"), (0x12, "HDMI 2"), (0x1B, "USB-C"),
    ]

    private let log = Logger(subsystem: "dev.byelior.lumac", category: "ddc")
    /// DDC calls block for tens of milliseconds: they run off the main thread, one at a time.
    private let queue = DispatchQueue(label: "dev.byelior.lumac.ddc")
    private var display: DDCDisplay?
    private var maximums: [VCP: UInt16] = [:]
    /// Sliders move faster than the display accepts frames: only the latest value per control is sent.
    private var pending: [VCP: UInt16] = [:]
    private var sending = false

    var brightness: Double? { levels[.brightness] }

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Finds the display again and reads its settings, after a wake or a display change.
    func refresh() {
        queue.async { [weak self] in
            let display = DDCDisplay.externalDisplays().first
            var readings: [VCP: VCPReading] = [:]
            var input: UInt8?
            if let display, display.detectAddressing() {
                for code in Self.continuous {
                    if let reading = try? display.read(code), reading.maximum > 0 { readings[code] = reading }
                }
                // Only the low byte holds the source; some displays set flags in the high byte.
                if let reading = try? display.read(.input), reading.current & 0xFF != 0 {
                    input = UInt8(reading.current & 0xFF)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.display = readings.isEmpty ? nil : display
                self.maximums = readings.mapValues(\.maximum)
                var levels = readings.mapValues { Double($0.current) / Double($0.maximum) }
                // Values the user is changing right now win over what the display reported.
                for code in self.pending.keys where levels[code] != nil { levels[code] = self.levels[code] }
                self.levels = levels
                self.input = input
                if let display, !readings.isEmpty {
                    self.log.info("DDC ready (\(display.addressing.description, privacy: .public))")
                }
            }
        }
    }

    func set(_ code: VCP, to level: Double) {
        guard let maximum = maximums[code] else { return }
        levels[code] = level
        pending[code] = UInt16((level * Double(maximum)).rounded())
        sendPending()
    }

    /// Switches the display to another input: the picture leaves this Mac until it switches back.
    func selectInput(_ source: UInt8) {
        guard let display else { return }
        input = source
        queue.async { [weak self] in
            do {
                try display.write(.input, value: UInt16(source))
            } catch {
                DispatchQueue.main.async {
                    self?.log.error("Input switch failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func sendPending() {
        guard !sending, let display, let (code, value) = pending.first else { return }
        pending[code] = nil
        sending = true
        queue.async { [weak self] in
            let error: Error?
            do { try display.write(code, value: value); error = nil } catch let failure { error = failure }
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.log.error("VCP \(code.rawValue, privacy: .public) write failed: \(String(describing: error), privacy: .public)") }
                self.sending = false
                self.sendPending()
            }
        }
    }
}
