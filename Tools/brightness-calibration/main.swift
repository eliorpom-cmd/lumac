import AppKit
import AVFoundation

// Matches the external display's brightness to the built-in display's, by eye of a camera.
//
// Both displays must be in the camera's frame (an iPhone through Continuity Camera, placed
// where the user's eyes are). The camera's exposure can't be locked, but it applies to the whole
// frame: for each built-in level, the external level that gives the same pixel values in the
// same frame is the one that looks equally bright from there.
//
// With --manual, no camera: the built-in display is set to each level and the user matches
// the external display by eye with the arrow keys, then compares with the camera's curve.
//
// Result: pairs (built-in level, external level) saved as `syncCurve` in Lumac's defaults.
// Build and run: Tools/brightness-calibration/calibrate.sh [--manual]

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
    @MainActor
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

/// Runs the app's event loop for `seconds`: windows draw, keys reach the windows and camera
/// callbacks arrive. A bare run loop would never deliver key events.
@MainActor
func pump(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    repeat {
        if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    } while Date() < until
}

// MARK: - Screens

/// Borderless windows can't take key events unless they say so.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// One borderless window per screen, filled with a flat gray, with an optional caption.
@MainActor
final class Patches {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var captions: [CGDirectDisplayID: NSTextField] = [:]

    init(screens: [NSScreen]) {
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = true
            window.backgroundColor = .black
            window.setFrame(screen.frame, display: true)
            let caption = NSTextField(labelWithString: "")
            caption.font = .systemFont(ofSize: 22, weight: .medium)
            caption.textColor = NSColor(white: 0.25, alpha: 1)
            caption.alignment = .center
            caption.frame = NSRect(x: 0, y: 60, width: screen.frame.width, height: 34)
            window.contentView?.addSubview(caption)
            window.orderFrontRegardless()
            windows[id] = window
            captions[id] = caption
        }
    }

    func fill(_ id: CGDirectDisplayID, gray: Double) {
        windows[id]?.backgroundColor = NSColor(white: gray, alpha: 1)
        windows[id]?.display()
    }

    func caption(_ id: CGDirectDisplayID, _ text: String) {
        captions[id]?.stringValue = text
    }

    /// Makes the window on `id` receive the keyboard.
    func focus(_ id: CGDirectDisplayID) {
        NSApp.activate(ignoringOtherApps: true)
        windows[id]?.makeKeyAndOrderFront(nil)
    }

    func close() { windows.values.forEach { $0.orderOut(nil) } }
}

// MARK: - Calibration

let levels = [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0]
let minimum = 0.1
/// A light gray keeps both screens below the camera's clipping point, and is easy to compare by eye.
let gray = 0.7

@MainActor
func calibrate() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let manual = CommandLine.arguments.contains("--manual")

    guard let builtInID = BuiltInBrightness.displayID(), let builtInStart = BuiltInBrightness.read() else {
        print("Écran intégré introuvable (capot fermé ?)."); return 1
    }
    let builtInScreen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == builtInID }
    guard let builtInScreen,
          let externalScreen = NSScreen.screens.first(where: { $0 != builtInScreen }),
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

    let camera: Camera?
    if manual {
        camera = nil
    } else {
        guard let found = Camera(preferring: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "iPhone") else {
            print("Caméra introuvable. Branche l'iPhone ou vérifie l'autorisation Caméra du Terminal."); return 1
        }
        camera = found
    }
    defer { camera?.stop() }

    let patches = Patches(screens: [builtInScreen, externalScreen])
    let builtIn = BuiltInBrightness()
    defer {
        patches.close()
        builtIn.set(builtInStart)
        if usesDDC, let ddc, let start = ddcStart { try? ddc.write(.brightness, value: start.current) } else { dimmer.restore() }
    }

    let defaults = UserDefaults(suiteName: "dev.byelior.lumac")!
    let previous = (defaults.array(forKey: "syncCurve") as? [[Double]]) ?? []

    let measured: [[Double]]
    if let camera {
        guard let curve = cameraCurve(camera: camera, patches: patches, builtIn: builtIn, builtInID: builtInID, externalID: externalID, setExternal: setExternal) else { return 1 }
        measured = curve
    } else {
        guard let curve = manualCurve(patches: patches, builtIn: builtIn, builtInID: builtInID, externalID: externalID, setExternal: setExternal) else {
            print("Calibration annulée, rien n'a été enregistré."); return 1
        }
        measured = curve
    }

    if manual, !previous.isEmpty {
        print("\n   Mac  |  À l'œil  |  Caméra")
        for pair in measured {
            let other = previous.first { abs($0[0] - pair[0]) < 0.001 }.map { String(format: "%5.0f %%", $0[1] * 100) } ?? "    –"
            print(String(format: "  %3.0f %% |  %5.0f %%  | ", pair[0] * 100, pair[1] * 100) + other)
        }
        print("\nGarder la courbe à l'œil ? (o/n) ", terminator: "")
        guard readLine()?.lowercased().hasPrefix("o") == true else {
            print("Courbe de la caméra gardée."); return 0
        }
    }
    defaults.set(measured, forKey: "syncCurve")
    // The curve replaces the default offset; manual adjustments start again from zero.
    defaults.set(0.0, forKey: "syncOffset")
    print("Courbe enregistrée. Active « Suivre la luminosité de l'écran intégré » dans Lumac.")
    return 0
}

/// Camera mode: finds both screens in the frame, then matches their pixel values level by level.
@MainActor
func cameraCurve(camera: Camera, patches: Patches, builtIn: BuiltInBrightness, builtInID: CGDirectDisplayID, externalID: CGDirectDisplayID, setExternal: (Double) -> Void) -> [[Double]]? {
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
        print("Les deux écrans doivent être bien visibles sur l'image de l'iPhone. Recadre et relance."); return nil
    }

    patches.fill(builtInID, gray: gray); patches.fill(externalID, gray: gray)
    func ratio() -> Double {
        let grid = camera.grid(after: 0.9)
        let mean = { (cells: [Int]) in cells.map { grid[$0] }.reduce(0, +) / Double(cells.count) }
        return mean(externalCells) / max(mean(builtInCells), 0.001)
    }

    var curve: [[Double]] = []
    for target in levels {
        builtIn.set(target)
        // Bisection on the external level: brightness grows with the level on both paths.
        var low = minimum, high = 1.0
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
    return curve
}

/// Manual mode: the user matches the external display by eye. ↑ ↓ change it by 2 %,
/// ⇧↑ ⇧↓ by 10 %, Space validates, Escape cancels; two minutes without a key cancel too.
@MainActor
func manualCurve(patches: Patches, builtIn: BuiltInBrightness, builtInID: CGDirectDisplayID, externalID: CGDirectDisplayID, setExternal: @escaping (Double) -> Void) -> [[Double]]? {
    patches.fill(builtInID, gray: gray); patches.fill(externalID, gray: gray)
    print("Règle le LG pour qu'il paraisse aussi clair que le Mac : ↑ ↓ (⇧ pour aller plus vite), Espace pour valider, Échap pour annuler.")

    var level = 0.5
    var validated = false
    var cancelled = false
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let fast = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126: level = min(1, level + (fast ? 0.1 : 0.02))
        case 125: level = max(minimum, level - (fast ? 0.1 : 0.02))
        case 49: validated = true
        case 53: cancelled = true
        default: return event
        }
        return nil
    }
    defer { monitor.map(NSEvent.removeMonitor) }

    var curve: [[Double]] = []
    for (index, target) in levels.enumerated() {
        builtIn.set(target)
        // Starts from the same level as the Mac, so the camera's answer doesn't steer the eye.
        level = max(minimum, target)
        validated = false
        patches.caption(builtInID, String(format: "Mac : %.0f %%   (%d/%d)", target * 100, index + 1, levels.count))
        patches.focus(externalID)
        var shown = -1.0
        var lastKey = Date()
        var lastLevel = level
        while !validated {
            if cancelled { return nil }
            // The gray windows cover every screen: give up if nobody is at the keyboard.
            if level != lastLevel { lastLevel = level; lastKey = Date() }
            if Date().timeIntervalSince(lastKey) > 120 {
                print("Aucune touche depuis 2 min : calibration arrêtée.")
                return nil
            }
            if level != shown {
                setExternal(level)
                shown = level
                patches.caption(externalID, String(format: "%.0f %%   ↑ ↓ pour régler, Espace pour valider", level * 100))
            }
            pump(0.05)
        }
        curve.append([target, level])
        print(String(format: "Intégré %3.0f %%  →  externe %3.0f %%", target * 100, level * 100))
    }
    return curve
}

exit(MainActor.assumeIsolated { calibrate() })
