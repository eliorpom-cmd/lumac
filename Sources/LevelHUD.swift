import AppKit
import SwiftUI

/// On-screen indicator shown when the brightness keys change a display: the display's name
/// and its level, on the display being adjusted, like the macOS indicator.
@MainActor
final class LevelHUD {
    static let shared = LevelHUD()

    private let model = Model()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    final class Model: ObservableObject {
        @Published var name = ""
        @Published var builtIn = false
        @Published var level = 0.0
    }

    func show(name: String, builtIn: Bool, level: Double, on screen: NSScreen?) {
        model.name = name
        model.builtIn = builtIn
        model.level = level

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 260, height: 64)
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            // Top right of the display, under the menu bar, where macOS shows its own indicators.
            panel.setFrame(NSRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hide?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { panel?.orderOut(nil) }
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }
}

private struct HUDView: View {
    @ObservedObject var model: LevelHUD.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.builtIn ? "laptopcomputer" : "display")
                Text(verbatim: model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(model.level.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
                ProgressView(value: model.level)
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
