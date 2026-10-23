import AppKit
import AVFoundation

// Matches the external display's brightness to the built-in display's, by eye of a camera.
//
// Both displays must be in the camera's frame (an iPhone through Continuity Camera, placed
// where the user's eyes are). The camera's exposure can't be locked, but it applies to the whole
// frame: for each built-in level, the external level that gives the same pixel values in the
// same frame is the one that looks equally bright from there.
//
// Result: pairs (built-in level, external level) saved as `syncCurve` in Lumac's defaults.
// Build and run: Tools/brightness-calibration/calibrate.sh

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Camera

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let columns = 64, rows = 36
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let lock = NSLock()
    private var latest: [Double]?
    private var frameCount = 0

    init?(preferring name: String) {
        super.init()
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices
        guard let device = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else { return nil }
        print("Caméra : \(device.localizedName)")
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    /// Mean luma per cell of a 64×36 grid, from a frame taken after `delay`.
    func grid(after delay: TimeInterval) -> [Double] {
        pump(delay)
        lock.lock(); let start = frameCount; lock.unlock()
        // Waits for a frame captured after the screens changed.
        while true {
            pump(0.05)
            lock.lock(); defer { lock.unlock() }
            if frameCount > start + 1, let latest { return latest }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var sums = [Double](repeating: 0, count: Self.columns * Self.rows)
        var counts = [Int](repeating: 0, count: sums.count)
        // Every 4th pixel is enough for cell means.
        for y in Swift.stride(from: 0, to: height, by: 4) {
            let row = base + y * stride
            let cy = y * Self.rows / height
            for x in Swift.stride(from: 0, to: width, by: 4) {
                let p = row + x * 4
                let luma = 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
                let cell = cy * Self.columns + x * Self.columns / width
                sums[cell] += luma / 255
                counts[cell] += 1
            }
        }
        let grid = zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
        lock.lock(); latest = grid; frameCount += 1; lock.unlock()
    }
}

/// Runs the main run loop, so windows draw and camera callbacks arrive.
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - Screens

/// One borderless window per screen, filled with a flat gray.
@MainActor
final class Patches {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    init(screens: [NSScreen]) {
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = true
            window.backgroundColor = .black
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows[id] = window
        }
    }

    func fill(_ id: CGDirectDisplayID, gray: Double) {
        windows[id]?.backgroundColor = NSColor(white: gray, alpha: 1)
        windows[id]?.display()
    }

    func close() { windows.values.forEach { $0.orderOut(nil) } }
}

// MARK: - Calibration

@MainActor
func calibrate() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard let builtInID = BuiltInBrightness.displayID(), let builtInStart = BuiltInBrightness.read() else {
        print("Écran intégré introuvable (capot fermé ?)."); return 1
    }
    let builtInScreen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == builtInID }
    guard let externalScreen = NSScreen.screens.first(where: { $0 != builtInScreen }),
          let externalID = externalScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    else { print("Écran externe introuvable."); return 1 }

    // External control: DDC when the display answers, the gamma table otherwise, as Lumac does.
    let ddc = DDCDisplay.externalDisplays().first
    let usesDDC = ddc?.detectAddressing() == true
    let ddcStart = usesDDC ? try? ddc?.read(.brightness) : nil
    let dimmer = SoftwareDimmer()
    func setExternal(_ level: Double) {
        if usesDDC, let ddc, let maximum = ddcStart?.maximum {
            try? ddc.write(.brightness, value: UInt16((level * Double(maximum)).rounded()))
        } else {
            dimmer.apply(level, to: externalID)
        }
    }
    print("Écran externe : \(externalScreen.localizedName), réglé par \(usesDDC ? "DDC" : "atténuation logicielle")")

    guard let camera = Camera(preferring: CommandLine.arguments.dropFirst().first ?? "iPhone") else {
        print("Caméra introuvable. Branche l'iPhone ou vérifie l'autorisation Caméra du Terminal."); return 1
    }
    defer { camera.stop() }

    let patches = Patches(screens: [builtInScreen!, externalScreen])
    let builtIn = BuiltInBrightness()
    defer {
        patches.close()
        builtIn.set(builtInStart)
        if usesDDC, let ddc, let start = ddcStart { try? ddc.write(.brightness, value: start.current) } else { dimmer.restore() }
    }
    builtIn.set(1)
    setExternal(1)

    // Finds each screen in the frame: light one at a time and keep the cells that brighten.
    print("Repérage des écrans…")
    patches.fill(builtInID, gray: 0); patches.fill(externalID, gray: 0)
    let dark = camera.grid(after: 2)
    patches.fill(externalID, gray: 1)
    let externalLit = camera.grid(after: 1.5)
    patches.fill(externalID, gray: 0); patches.fill(builtInID, gray: 1)
    let builtInLit = camera.grid(after: 1.5)
    func mask(_ lit: [Double]) -> [Int] {
        let gains = zip(lit, dark).map { $0 - $1 }
        guard let best = gains.max(), best > 0.08 else { return [] }
        return gains.indices.filter { gains[$0] > best * 0.6 }
    }
    let externalCells = mask(externalLit), builtInCells = mask(builtInLit)
    print("Cellules trouvées : intégré \(builtInCells.count), externe \(externalCells.count)")
    guard builtInCells.count >= 6, externalCells.count >= 6, Set(builtInCells).isDisjoint(with: externalCells) else {
        print("Les deux écrans doivent être bien visibles sur l'image de l'iPhone. Recadre et relance."); return 1
    }

    // A light gray keeps both screens below the camera's clipping point.
    let gray = 0.7
    patches.fill(builtInID, gray: gray); patches.fill(externalID, gray: gray)
    func ratio() -> Double {
        let grid = camera.grid(after: 0.9)
        let mean = { (cells: [Int]) in cells.map { grid[$0] }.reduce(0, +) / Double(cells.count) }
        return mean(externalCells) / max(mean(builtInCells), 0.001)
    }

    var curve: [[Double]] = []
    for target in [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0] {
        builtIn.set(target)
        // Bisection on the external level: brightness grows with the level on both paths.
        var low = 0.1, high = 1.0
        setExternal(high)
        if ratio() < 1 {
            low = high
        } else {
            for _ in 0..<7 {
                let middle = (low + high) / 2
                setExternal(middle)
                if ratio() < 1 { low = middle } else { high = middle }
            }
        }
        let match = (low + high) / 2
        curve.append([target, match])
        print(String(format: "Intégré %3.0f %%  →  externe %3.0f %%%@", target * 100, match * 100, match >= 0.99 ? "  (externe au maximum)" : ""))
    }

    let defaults = UserDefaults(suiteName: "dev.byelior.lumac")!
    defaults.set(curve, forKey: "syncCurve")
    // The curve replaces the default offset; manual adjustments start again from zero.
    defaults.set(0.0, forKey: "syncOffset")
    print("Courbe enregistrée. Relance Lumac et active « Suivre la luminosité de l'écran intégré ».")
    return 0
}

exit(MainActor.assumeIsolated { calibrate() })
