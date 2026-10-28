import AVFoundation
import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// First-run welcome window: grants Accessibility and the microphone, downloads the speech model, then lets the
/// user try one dictation. Shown on first launch, when Accessibility is missing, and when models start downloading
/// later (a reinstall with Accessibility still granted would otherwise download gigabytes with nothing on screen).
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let controller: Controller
    private let server: LocalServer
    private let finished = WelcomeProgress()
    /// Screen rect of the menu bar icon, where "Download in Background" sends the window
    private let menuBarIcon: () -> NSRect?

    init(controller: Controller, server: LocalServer, menuBarIcon: @escaping () -> NSRect?) {
        self.controller = controller
        self.server = server
        self.menuBarIcon = menuBarIcon
    }

    /// Sent to the background or closed, rather than on screen or minimized by the user
    var isTucked: Bool {
        guard let window else { return false }
        return !window.isVisible && !window.isMiniaturized
    }

    /// activate: false brings the window up without taking focus from what the user is doing (used when a
    /// background download finishes)
    func show(activate: Bool = true) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.zoomButton)?.isHidden = true
            // With the system's open animation running alongside the content's fade-in, controls showed up before
            // the window's background; show() fades the whole window in instead
            w.animationBehavior = .none
            w.delegate = self
            // The desktop shows through behind the content, like the system's own setup windows
            let glass = NSVisualEffectView()
            glass.material = .underWindowBackground
            glass.blendingMode = .behindWindow
            glass.state = .active
            let host = NSHostingView(rootView: WelcomeView(controller: controller, server: server, progress: finished,
                                                           close: { [weak self] in self?.window?.performClose(nil) },
                                                           background: { [weak self] in self?.tuckIntoMenuBar() }))
            host.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                host.topAnchor.constraint(equalTo: glass.topAnchor),
                host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            w.contentView = glass
            w.center()
            window = w
        }
        guard let w = window else { return }
        // Coming up from nothing (first show, or back from the menu bar): background and content fade in as one,
        // and WelcomeView's own reveal starts after this. A minimized window keeps the system's restore animation
        let fadeIn = !w.isVisible && !w.isMiniaturized
        if fadeIn { w.alphaValue = 0 }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        if fadeIn {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
        }
    }

    /// The window rises into the menu bar icon and fades out, so it's clear where the download went on
    private func tuckIntoMenuBar() {
        guard let w = window else { return }
        let home = w.frame
        var target = home
        if let icon = menuBarIcon() {
            // Top center of the window ends under the icon, shrunk around it
            target = NSRect(x: icon.midX - home.width * 0.1, y: icon.minY - home.height * 0.2,
                            width: home.width * 0.2, height: home.height * 0.2)
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                w.orderOut(nil)
                w.setFrame(home, display: false)
                w.alphaValue = 1
            }
        })
    }

    func windowWillClose(_ notification: Notification) {
        // Closed after the last step: don't show it again unless something needs setting up
        if finished.done { UserDefaults.standard.set(true, forKey: Pref.onboarded) }
    }
}

/// Whether the user finished the last step, read when the window closes
@MainActor
final class WelcomeProgress {
    var done = false
}

private struct WelcomeView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var server: LocalServer
    let progress: WelcomeProgress
    let close: () -> Void
    let background: () -> Void

    @AppStorage(Pref.model) private var model = SpeechModel.accurate.rawValue
    @AppStorage(Pref.livePreview) private var livePreview = true
    @AppStorage(Pref.triggerKey) private var triggerKey = TriggerKey.rightOption.rawValue
    @State private var accessibility = AXIsProcessTrusted()
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var remote: Transcriber.Status?
    @State private var tryText = ""
    /// The last transcription when the window opened; a different one means the try-it dictation worked
    @State private var lastTextAtOpen: String?
    @State private var rate = RateMeter()
    @State private var appeared = false
    @State private var showDifference = false
    @FocusState private var tryFocused: Bool

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                WaveHero(controller: controller)
                    .frame(height: 120)
                Text("Welcome to Sottovoce")
                    .font(.system(size: 26, weight: .semibold))
                Text("Hold a key, speak, let go. Your words land where the cursor is.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 34)
            .padding(.bottom, 22)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(reveal(after: 0), value: appeared)

            VStack(spacing: 10) {
                StepCard(number: 1, status: accessibility ? .done : .active,
                         title: "Allow Accessibility", detail: String(localized: "To notice the hotkey and type the text for you")) {
                    if !accessibility {
                        Button("Open System Settings") { openAccessibility() }
                    }
                }
                StepCard(number: 2, status: microphoneOK ? .done : (accessibility ? .active : .waiting),
                         title: "Allow the microphone", detail: String(localized: "Only records while you hold the hotkey")) {
                    if !microphoneOK {
                        Button("Allow") { requestMicrophone() }
                    }
                }
                modelStep
                tryStep
            }
            .padding(.horizontal, 22)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(reveal(after: 0.08), value: appeared)

            Spacer(minLength: 16)

            HStack {
                Button("Quit Sottovoce") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: Pref.onboarded)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!tried)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
            .opacity(appeared ? 1 : 0)
            .animation(reveal(after: 0.16), value: appeared)
        }
        .frame(width: 460, height: 640)
        .onAppear {
            lastTextAtOpen = controller.lastText
            appeared = true
        }
        .onReceive(poll) { _ in Task { await refresh() } }
        .onChange(of: server.state) { _, state in
            if case .downloading(let done, _) = state { rate.add(done) }
        }
        .onChange(of: ready) { _, ready in
            if ready { tryFocused = true }
        }
        .onChange(of: tried) { _, tried in progress.done = tried }
    }

    /// The content's entrance, staggered top to bottom; it waits for WelcomeWindow's 0.25 s window fade-in so
    /// nothing shows before the window's background does
    private func reveal(after delay: Double) -> Animation {
        .easeOut(duration: 0.5).delay(0.25 + delay)
    }

    private var microphoneOK: Bool { microphone == .authorized }

    private var tried: Bool {
        guard let lastTextAtOpen else { return false }
        return controller.lastText != lastTextAtOpen && !controller.lastText.isEmpty
    }

    /// Ready to dictate: permissions granted and a server answering
    private var ready: Bool {
        accessibility && microphoneOK && modelDone
    }

    private var modelDone: Bool {
        switch server.state {
        case .running, .external: return true
        case .off: return remote == .ok
        default: return false
        }
    }

    /// The "?" after the model step's title: how the two models differ
    private var differenceButton: some View {
        Button {
            showDifference = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What's the difference?")
        .accessibilityLabel("What's the difference?")
        .popover(isPresented: $showDifference, arrowEdge: .bottom) { ModelComparison() }
    }

    @ViewBuilder private var modelStep: some View {
        let status: StepStatus = modelDone ? .done : (accessibility && microphoneOK ? .active : .waiting)
        switch server.state {
        case .needsDownload:
            StepCard(number: 3, status: .active, title: "Download the speech model",
                     detail: String(localized: "Downloaded once, then kept on this Mac"), help: AnyView(differenceButton)) {
                Button(String(localized: "Download \(SpeechModel.downloadSize(SpeechModel(rawValue: model) ?? .accurate, preview: livePreview))")) {
                    server.approveDownload()
                }
                .buttonStyle(.borderedProminent)
            } below: {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $model) {
                        Text(verbatim: "Qwen3-ASR 1.7B").tag(SpeechModel.accurate.rawValue)
                        Text(verbatim: "Qwen3-ASR 0.6B").tag(SpeechModel.light.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle(isOn: $livePreview) {
                        Text("Live preview (+0.9 GB)")
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
        case .downloading(let done, let total):
            StepCard(number: 3, status: status, title: "Download the speech model", detail: downloadDetail(done, total)) {
                Button("Download in Background", action: background)
            } below: {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
            }
        case .downloadFailed(let message):
            StepCard(number: 3, status: .failed, title: "Download the speech model",
                     detail: String(localized: "Download failed: \(message)")) {
                Button("Retry") { server.retry() }
            }
        case .starting:
            StepCard(number: 3, status: status, title: "Download the speech model",
                     detail: String(localized: "Starting the server…")) {
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            StepCard(number: 3, status: .failed, title: "Download the speech model",
                     detail: String(localized: "The server stopped: \(message)")) {
                Button("Restart") { server.retry() }
            }
        case .running:
            StepCard(number: 3, status: .done, title: "Download the speech model", detail: String(localized: "Ready")) {
                EmptyView()
            }
        case .external:
            StepCard(number: 3, status: .done, title: "Download the speech model",
                     detail: String(localized: "Using the server already running on this Mac")) {
                EmptyView()
            }
        case .off:
            StepCard(number: 3, status: modelDone ? .done : .active, title: "Connect to the server",
                     detail: modelDone ? String(localized: "Using \(Pref.server)") : String(localized: "Set the address in Settings › Server")) {
                EmptyView()
            }
        }
    }

    private var tryStep: some View {
        let trigger = TriggerKey(rawValue: triggerKey)?.title ?? TriggerKey.rightOption.title
        return StepCard(number: 4, status: tried ? .done : (ready ? .active : .waiting), title: "Try it",
                        detail: tried ? String(localized: "That's it. It works the same in any app.")
                                      : String(localized: "Click the box, hold \(trigger), say something, let go")) {
            EmptyView()
        } below: {
            TextField(String(localized: "Hold \(trigger) and speak…"), text: $tryText, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.plain)
                .padding(8)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(tryFocused ? 0.3 : 0.1)))
                .focused($tryFocused)
                .disabled(!ready)
        }
    }

    private func downloadDetail(_ done: Int64, _ total: Int64) -> String {
        guard total > 0 else { return String(localized: "Preparing…") }
        let have = bytes(done), all = bytes(total)
        guard let speed = rate.bytesPerSecond, speed > 0 else { return String(localized: "\(have) of \(all)") }
        let left = Self.duration.string(from: Double(total - done) / speed) ?? ""
        return String(localized: "\(have) of \(all), \(bytes(Int64(speed)))/s, about \(left) left")
    }

    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.maximumUnitCount = 1
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .memory)
    }

    private func refresh() async {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if Pref.connectionMode == .remote {
            remote = Pref.server.isEmpty ? .unreachable : await Transcriber.check(server: Pref.server, token: Pref.token)
        }
    }

    private func openAccessibility() {
        // Prompting adds the app to the Accessibility list, so the user only has to flip its switch
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                    if granted { controller.applyMicSettings() }
                }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

private enum StepStatus {
    case waiting, active, done, failed
}

/// One setup step: a numbered badge that turns into a checkmark, a title and a detail line, an action on the right,
/// and optional content underneath (a progress bar, the try-it box)
/// The model step's "What's the difference?" popover: the two models side by side, with the numbers from the
/// README's model comparison (WenetSpeech error rates and latency on an M4 Pro, memory from Activity Monitor)
private struct ModelComparison: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1.7B makes fewer mistakes. 0.6B is about twice as fast and needs less than half the memory. Unless memory or disk space is tight, pick 1.7B.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(verbatim: "1.7B").fontWeight(.semibold)
                    Text(verbatim: "0.6B").fontWeight(.semibold)
                }
                Divider()
                row("Error rate, online videos", "4.2%", "6.1%")
                row("Error rate, meetings", "6.6%", "6.7%")
                row("Time per sentence", String(localized: "about 0.26 s"), String(localized: "about 0.14 s"))
                row("Memory", "2.5 GB", "1.1 GB")
                row("Download size", "2.3 GB", "1.0 GB")
            }
            Text("Live preview adds SenseVoice Small (0.9 GB): a quick draft shows up while you speak, and the chosen model writes the final text when you let go. With 1.7B, the two take about 5 GB of memory.")
            Text("Error rates on 60 WenetSpeech sentences per set and times on an M4 Pro Mac mini, October 2026. Lower is better.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 330, alignment: .leading)
        .padding(16)
    }

    private func row(_ label: LocalizedStringKey, _ large: String, _ small: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: large).monospacedDigit()
            Text(verbatim: small).monospacedDigit()
        }
    }
}

private struct StepCard<Action: View, Below: View>: View {
    let number: Int
    let status: StepStatus
    let title: LocalizedStringKey
    let detail: String
    /// A small button right after the title, such as a "?" that explains the step
    let help: AnyView?
    @ViewBuilder let action: () -> Action
    @ViewBuilder let below: () -> Below

    init(number: Int, status: StepStatus, title: LocalizedStringKey, detail: String, help: AnyView? = nil,
         @ViewBuilder action: @escaping () -> Action, @ViewBuilder below: @escaping () -> Below) {
        self.number = number
        self.status = status
        self.title = title
        self.detail = detail
        self.help = help
        self.action = action
        self.below = below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        help
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                action()
                    .controlSize(.small)
            }
            below()
                .padding(.leading, 40)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        .opacity(status == .waiting ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(status == .done ? AnyShapeStyle(.green) : AnyShapeStyle(.primary.opacity(status == .active ? 0.14 : 0.07)))
            switch status {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
            default:
                Text(verbatim: "\(number)").font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
        .frame(width: 28, height: 28)
    }
}

private extension StepCard where Below == EmptyView {
    init(number: Int, status: StepStatus, title: LocalizedStringKey, detail: String,
         @ViewBuilder action: @escaping () -> Action) {
        self.init(number: number, status: status, title: title, detail: detail, action: action, below: { EmptyView() })
    }
}

/// Liquid Glass on macOS 26 and later; earlier systems get a translucent material
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// The logo's wave, alive: it draws itself in from the left, then keeps flowing into the dot while its envelope
/// dies away, breathing slowly at rest and swelling with the microphone level while the user speaks
private struct WaveHero: View {
    @ObservedObject var controller: Controller
    @State private var start = Date()
    @State private var level = Smoothed()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                // Draw-in over the first second, eased out
                let drawn = 1 - pow(1 - min(t / 1.1, 1), 3)
                let speaking = level.next(target: currentLevel)
                let breathe = 0.86 + 0.14 * sin(t * 1.3)
                let amp = size.height * 0.36 * (speaking > 0.02 ? 0.45 + 0.75 * speaking : breathe)
                let x0 = size.width * 0.2, width = size.width * 0.52, mid = size.height / 2

                var wave = Path()
                let steps = 160
                for i in 0...Int(Double(steps) * drawn) {
                    let u = Double(i) / Double(steps)
                    // 2.25 cycles like the icon, flowing toward the dot
                    let y = mid - amp * sin((u * 4.5 - t * 0.9) * .pi) * pow(1 - u, 1.3)
                    let p = CGPoint(x: x0 + width * u, y: y)
                    i == 0 ? wave.move(to: p) : wave.addLine(to: p)
                }
                let ink = Color.primary
                let style = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                let fade = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [ink.opacity(0.35), ink]),
                    startPoint: CGPoint(x: x0, y: mid), endPoint: CGPoint(x: x0 + width, y: mid))
                // A soft glow under the line
                var glow = context
                glow.addFilter(.blur(radius: 8))
                glow.opacity = 0.35
                glow.stroke(wave, with: fade, style: style)
                context.stroke(wave, with: fade, style: style)

                // The dot pops in once the line arrives, then pulses gently
                let pop = min(max((t - 1.0) / 0.35, 0), 1)
                let r = 5.5 * (pop < 1 ? 1.4 * sin(pop * .pi / 2) : 1 + 0.08 * sin(t * 2.6))
                let dot = Path(ellipseIn: CGRect(x: x0 + width + 26 - r, y: mid - r, width: r * 2, height: r * 2))
                context.opacity = 0.55 * pop
                context.fill(dot, with: .color(ink))
            }
        }
    }

    /// Mean of the most recent microphone levels while recording, 0 otherwise
    private var currentLevel: Double {
        guard case .recording = controller.phase else { return 0 }
        let recent = controller.levels.suffix(4)
        return Double(recent.reduce(0, +)) / Double(max(recent.count, 1))
    }
}

/// Exponential smoothing kept across frames without triggering view updates
private final class Smoothed {
    private var value = 0.0

    func next(target: Double) -> Double {
        value += (target - value) * 0.18
        return value
    }
}

/// Download speed over the last few seconds, from the progress updates
private struct RateMeter {
    private var samples: [(Date, Int64)] = []

    mutating func add(_ done: Int64) {
        let now = Date()
        samples.append((now, done))
        samples.removeAll { now.timeIntervalSince($0.0) > 4 }
    }

    /// nil until a few seconds of samples exist: a download's first second is mostly connection setup, and a speed
    /// from it would promise hours
    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) > 3 else { return nil }
        return Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
    }
}
