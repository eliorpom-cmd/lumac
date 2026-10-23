import AppKit
import os

/// Brightness of the external display over DDC/CI, for the menu bar slider.
@MainActor
final class BrightnessController: ObservableObject {
    /// 0...1, nil while no display answers over DDC.
    @Published private(set) var brightness: Double?

    private let log = Logger(subsystem: "dev.byelior.lumac", category: "ddc")
    /// DDC calls block for tens of milliseconds: they run off the main thread, one at a time.
    private let queue = DispatchQueue(label: "dev.byelior.lumac.ddc")
    private var display: DDCDisplay?
    private var maximum: UInt16 = 100
    /// Slider moves faster than the display accepts frames: only the latest value is sent.
    private var pendingValue: UInt16?
    private var sending = false

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

    /// Finds the display again and reads its brightness, after a wake or a display change.
    func refresh() {
        queue.async { [weak self] in
            let display = DDCDisplay.externalDisplays().first
            let reading: VCPReading? = display.flatMap { display in
                display.detectAddressing() ? try? display.read(.brightness) : nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.display = reading == nil ? nil : display
                if let reading, reading.maximum > 0 {
                    self.maximum = reading.maximum
                    self.brightness = Double(reading.current) / Double(reading.maximum)
                    self.log.info("DDC ready (\(display?.addressing.description ?? "", privacy: .public))")
                } else {
                    self.brightness = nil
                }
            }
        }
    }

    func set(_ value: Double) {
        brightness = value
        pendingValue = UInt16((value * Double(maximum)).rounded())
        sendPending()
    }

    private func sendPending() {
        guard !sending, let value = pendingValue, let display else { return }
        pendingValue = nil
        sending = true
        queue.async { [weak self] in
            let error: Error?
            do { try display.write(.brightness, value: value); error = nil } catch let failure { error = failure }
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.log.error("Brightness write failed: \(String(describing: error), privacy: .public)") }
                self.sending = false
                self.sendPending()
            }
        }
    }
}
