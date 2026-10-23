import AppKit
import os

/// Settings of the external display over DDC/CI (brightness, contrast…), for the menu bar panel.
@MainActor
final class DisplayController: ObservableObject {
    /// 0...1 for each control the display answers, missing while unsupported or unreachable.
    @Published private(set) var levels: [VCP: Double] = [:]

    /// Continuous controls read on each refresh, in panel order.
    nonisolated static let continuous: [VCP] = [.brightness, .contrast]

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
            if let display, display.detectAddressing() {
                for code in Self.continuous {
                    if let reading = try? display.read(code), reading.maximum > 0 { readings[code] = reading }
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
