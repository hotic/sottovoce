import AppKit
import Combine
import SwiftUI

/// Dictation HUD at the bottom of the screen: a waveform while recording, a progress bar while finalizing,
/// and a checkmark pop before hiding when done.
/// Transcribed text goes straight into the text field, so the HUD never shows it; a short line of text appears
/// only while waiting for a text-field click, for notices and for errors.
/// Never takes focus or mouse events; the window is transparent and wide enough, and the capsule sizes to its
/// content, centered at the bottom.
@MainActor
final class HUD {
    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private static let size = NSSize(width: 480, height: 90)

    init(controller: Controller) {
        // defer: false creates the window-server resources at launch, so the first press doesn't wait
        panel = GlassPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: HUDView(controller: controller))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        host.layoutSubtreeIfNeeded()

        cancellable = controller.$phase.removeDuplicates().sink { [weak self] phase in
            self?.update(phase)
        }
    }

    private func update(_ phase: Controller.Phase) {
        guard phase != .idle else {
            // Hide after fading out; don't hide if a new round started during the fade
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.panel.alphaValue == 0 else { return }
                    self.panel.orderOut(nil)
                }
            })
            return
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            // Appear centered at the bottom of the screen under the mouse
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let f = screen?.visibleFrame, !panel.isVisible {
                panel.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 24))
            }
            panel.alphaValue = 1
        }
        panel.orderFrontRegardless()
    }
}

/// macOS renders Liquid Glass with its clear refraction only while the app is frontmost, otherwise it falls back
/// to frosted. The HUD never takes focus and the app always stays in the background, so override AppKit's private
/// active-appearance checks to draw the glass as active.
/// If the system renames these later, it just falls back to frosted instead of crashing
private final class GlassPanel: NSPanel {
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}

private struct HUDView: View {
    @ObservedObject var controller: Controller
    static let width: CGFloat = 176
    /// Waveform and progress bar share the same width, so the layout doesn't jump from recording to transcribing
    static let contentWidth: CGFloat = 96

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            capsule
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .recording(let handsFree):
                // Hands-free recording uses a different icon of the same width
                Image(systemName: handsFree ? "mic.badge.plus" : "mic.fill").frame(width: 18)
                if controller.micReady {
                    Waveform(levels: controller.levels)
                } else {
                    MicStarting()
                }
            case .transcribing(let started, let expected):
                Image(systemName: "waveform").frame(width: 18)
                ProgressBar(started: started, expected: expected)
            case .done(let started, let expected, let finished):
                DoneCheck().frame(width: 18)
                ProgressBar(started: started, expected: expected, finished: finished)
            case .pending:
                Image(systemName: "cursorarrow.click.2").frame(width: 18)
                Text("Click a text field").foregroundStyle(.secondary)
            case .notice(let message):
                Image(systemName: "doc.on.clipboard").frame(width: 18)
                Text(message).lineLimit(1)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).frame(width: 18)
                Text(message).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 14, weight: .medium))
        // All states share one width so the capsule doesn't resize on switch; long text is truncated
        .frame(width: Self.width, height: 44)
        .modifier(Glass())
        // Summon: the capsule grows in from slightly smaller and transparent, anchored at the bottom edge so it
        // never clips. Recording starts on the press regardless; this only smooths how the HUD arrives
        .scaleEffect(shown ? 1 : 0.82, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: shown)
    }

    private var shown: Bool {
        controller.phase != .idle
    }
}

/// Checkmark on completion: pops from small to normal size. The capsule itself doesn't scale, because it sits on
/// the window's bottom edge and growing it would clip its bottom
private struct DoneCheck: View {
    @State private var popped = false

    var body: some View {
        Image(systemName: "checkmark").fontWeight(.bold)
            .scaleEffect(popped ? 1 : 0.5)
            .onAppear {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { popped = true }
            }
    }
}

/// Finalizing progress bar: the server reports no progress, so it advances by the estimated duration,
/// approaching 92%. When the result arrives it eases from the current position to full instead of jumping;
/// if expected is underestimated it just crawls near the end rather than sticking at full
private struct ProgressBar: View {
    let started: Date
    let expected: TimeInterval
    /// When the result arrived; nil while still transcribing
    var finished: Date? = nil
    private let width = HUDView.contentWidth
    private static let fillDuration: TimeInterval = 0.2

    /// Estimated progress at a moment during transcription
    private func estimate(at date: Date) -> Double {
        0.92 * (1 - exp(-2.3 * date.timeIntervalSince(started) / max(expected, 0.1)))
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let p: Double = {
                guard let finished else { return estimate(at: ctx.date) }
                let from = estimate(at: finished)
                let k = min(max(ctx.date.timeIntervalSince(finished) / Self.fillDuration, 0), 1)
                // Cubic ease-out: starts at roughly the transcribing pace and slows toward the end
                return from + (1 - from) * (1 - pow(1 - k, 3))
            }()
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary).frame(width: max(6, width * p))
            }
            .frame(width: width, height: 6)
        }
    }
}

/// Liquid Glass on macOS 26 and later; earlier systems fall back to translucent material
private struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
    }
}

/// Microphone starting (between the press and the first audio frame): the bars dim and a highlight sweeps left to
/// right, signaling that speech now would be lost. A warm microphone produces sound within tens of milliseconds,
/// so the first 0.15 s looks like a silent waveform to avoid a flash on every press
private struct MicStarting: View {
    @State private var start = Date()
    private let sweep: Double = 0.7  // Seconds per sweep

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            let fade = min(max((t - 0.15) / 0.15, 0), 1)
            // The highlight center travels from just past the left edge to just past the right edge
            let center = (t / sweep).truncatingRemainder(dividingBy: 1) * 1.4 - 0.2
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Controller.barCount, id: \.self) { i in
                    let x = Double(i) / Double(Controller.barCount - 1)
                    let bump = max(0, 1 - abs(x - center) / 0.18) * fade
                    Capsule()
                        .frame(width: 3, height: 4 + CGFloat(bump) * 10)
                        .opacity(1 - 0.7 * fade + 0.6 * bump)
                }
            }
            .frame(width: HUDView.contentWidth, height: 22)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 16)
            }
        }
        .frame(width: HUDView.contentWidth, height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
