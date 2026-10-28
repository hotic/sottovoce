import AVFoundation
import AppKit

/// State machine for the dictation flow: key events drive recording, live preview (written straight into
/// the text field), transcription and insertion.
@MainActor
final class Controller: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// handsFree is true for hands-free recording started by a tap; pressing the trigger again ends it
        case recording(handsFree: Bool)
        /// Final transcription in progress; expected is the duration estimated from the audio length,
        /// which drives the HUD progress bar
        case transcribing(started: Date, expected: TimeInterval)
        /// Transcribed, but focus is not in a text field; wait for the user to click into one before inserting
        case pending
        /// Inserted; the HUD progress bar fills up from where it was and then hides. started / expected carry
        /// over from transcribing, finished is when the result arrived
        case done(started: Date, expected: TimeInterval, finished: Date)
        /// Informational message (e.g. copied to clipboard), disappears after two seconds
        case notice(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Recent levels, used by the HUD waveform
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: Controller.barCount)
    /// Whether the first audio frame of this recording has arrived. On a cold start the device takes
    /// 0.3–1 s to produce sound; until then the HUD shows a "starting" state
    @Published private(set) var micReady = false
    @Published private(set) var lastText = ""
    /// Why dictation can't start yet (the server on this Mac is downloading models or starting); nil when it can
    var notReady: @MainActor () -> String? = { nil }

    static let barCount = 16  // 16 bars, 3pt wide with 3pt gaps, exactly fill the HUD content area
    /// Holding for less than this counts as an accidental press (or a tap)
    private let tapThreshold: TimeInterval = 0.3
    private let escKeyCode: UInt16 = 53
    /// Preview only sends the most recent audio of this length, so requests don't grow during long dictation
    private let previewWindow: Double = 20
    private let previewInterval: UInt64 = 300_000_000
    /// Longest wait for the user to click a text field; on timeout the text goes to the clipboard
    private let pendingTimeout: TimeInterval = 60

    private let recorder = Recorder()
    private let hotkeys = HotkeyMonitor()
    private let composer = InlineComposer()
    private var pressedAt = Date.distantPast
    /// Incremented on every start or cancel, to discard stale recordings and results
    private var generation = 0
    private var dismissTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var pendingText = ""
    /// Number of loud-enough audio frames in this recording. The fast model hallucinates things like "Yeah."
    /// from background noise and key clicks, so preview starts only after about 0.2 s of speech; a key click
    /// is a spike of one or two frames and won't trigger it
    private var speechFrames = 0
    private let speechLevel: Float = 0.4   // about -30 dB
    private let speechFramesNeeded = 10    // each frame is about 21 ms (1024 samples at 48 kHz)

    init() {
        recorder.onLevel = { [weak self] level in
            guard let self, case .recording = self.phase else { return }
            if !self.micReady { self.micReady = true }
            self.levels.removeFirst()
            self.levels.append(level)
            if level >= self.speechLevel { self.speechFrames += 1 }
        }
        hotkeys.onEvent = { [weak self] in self?.handle($0) }
    }

    /// Global monitors only take effect after re-registering once Accessibility is granted
    func startMonitoring() { hotkeys.start() }

    /// Pre-build the microphone engine from the current settings (also called when the microphone or
    /// always-on setting changes). Skipped without microphone permission, to avoid a prompt at launch
    func applyMicSettings() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let d = UserDefaults.standard
        recorder.prepare(deviceUID: d.string(forKey: Pref.microphoneUID) ?? "", alwaysOn: d.bool(forKey: Pref.micAlwaysOn))
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch (event, phase) {
        case (.triggerDown, .idle), (.triggerDown, .failed), (.triggerDown, .notice), (.triggerDown, .done):
            pressedAt = Date()
            beginRecording()
        case (.triggerDown, .pending):
            // Starting the next take before the last one was inserted: put the last one on the clipboard so it isn't lost
            copyPendingToClipboard()
            pressedAt = Date()
            beginRecording()
        case (.triggerDown, .recording(handsFree: true)):
            finishRecording()
        case (.triggerUp, .recording(handsFree: false)):
            if Date().timeIntervalSince(pressedAt) < tapThreshold {
                if UserDefaults.standard.bool(forKey: Pref.tapToToggle) {
                    phase = .recording(handsFree: true)
                } else {
                    cancel()
                }
            } else {
                finishRecording()
            }
        case (.otherKey, .recording(handsFree: false)):
            // Another key pressed while holding the trigger: it's a key combo, not dictation
            cancel()
        case (.otherKey(let code), .recording(handsFree: true)) where code == escKeyCode,
             (.otherKey(let code), .transcribing) where code == escKeyCode,
             (.otherKey(let code), .pending) where code == escKeyCode:
            cancel()
        default:
            break
        }
    }

    private func beginRecording() {
        // Say so on the press rather than after the user has finished speaking
        if let reason = notReady() {
            fail(reason)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                if ok { Task { @MainActor in self.applyMicSettings() } }
            }
            return
        default:
            fail(String(localized: "Microphone access not granted"))
            return
        }

        generation += 1
        let gen = generation
        dismissTimer?.invalidate()
        pendingTask?.cancel()
        levels = Array(repeating: 0, count: Self.barCount)
        speechFrames = 0
        micReady = false
        // Show the HUD before starting the microphone, so a press gets immediate feedback
        phase = .recording(handsFree: false)
        recorder.start(deviceUID: UserDefaults.standard.string(forKey: Pref.microphoneUID) ?? "") { [weak self] err in
            guard let self, gen == self.generation else { return }
            if let err {
                self.generation += 1
                self.fail(err.localizedDescription)
            } else {
                self.startPreview(gen: gen)
            }
        }
    }

    /// Poll for previews while recording and write them into the current text field. The next request is sent
    /// only after the previous one returns and enough new audio has been recorded, so requests never pile up
    private func startPreview(gen: Int) {
        previewTask?.cancel()
        guard UserDefaults.standard.bool(forKey: Pref.livePreview) else { return }
        let server = Pref.server, token = Pref.token
        previewTask = Task { [weak self] in
            var sent = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.previewInterval ?? 300_000_000)
                guard let self, gen == self.generation, case .recording = self.phase else { return }
                guard self.speechFrames >= self.speechFramesNeeded,
                      let snap = self.recorder.snapshot(maxSeconds: self.previewWindow),
                      snap.total >= 0.5, snap.total - sent >= 0.25 else { continue }
                // Past the preview window only the tail is available, and writing it would drop earlier text;
                // keep the existing preview and finalize on release
                guard snap.total <= self.previewWindow else { return }
                sent = snap.total
                guard let text = try? await Transcriber.transcribe(wav: snap.wav, server: server, token: token,
                                                                    model: "preview", timeout: 5) else {
                    return  // Server doesn't support preview or failed: stop previewing, finalizing is unaffected
                }
                guard gen == self.generation, case .recording = self.phase else { return }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Self.isNoiseHallucination(t) else { continue }
                self.composer.update(t)
            }
        }
    }

    /// Typical fast-model output for noise: a single English word ("Yeah." "The." "I." "Oh.").
    /// A genuinely spoken single English word just shows up in the preview a bit later; the final result is unaffected
    static func isNoiseHallucination(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.count <= 1 && text.unicodeScalars.allSatisfy { $0.isASCII }
    }

    private func finishRecording() {
        let gen = generation
        previewTask?.cancel()
        // Show the progress bar between stopping and the result; recalibrate from the actual length in the stop callback
        phase = .transcribing(started: Date(), expected: 0.5)
        recorder.stop { [weak self] wav, seconds in
            guard let self, gen == self.generation else { return }
            guard seconds >= 0.3 else {
                self.composer.discard()
                self.phase = .idle
                return
            }
            // Measured locally: about 0.03 s + 0.07 s per second of audio; remote adds a network round trip
            let expected = 0.15 + 0.07 * seconds + (Pref.connectionMode == .remote ? 0.15 : 0)
            self.phase = .transcribing(started: Date(), expected: expected)
            Task { await self.transcribe(wav, gen: gen) }
        }
    }

    private func transcribe(_ wav: Data, gen: Int) async {
        do {
            let raw = try await Transcriber.transcribe(wav: wav, server: Pref.server, token: Pref.token)
            guard gen == generation else { return }
            let text = Punctuation.apply(raw, mode: Pref.punctuationMode)
            guard !text.isEmpty else {
                composer.discard()
                phase = .idle
                return
            }
            lastText = text
            // Copy to the clipboard first: if it never gets inserted, or the wait for a click is cancelled, the text survives
            if UserDefaults.standard.bool(forKey: Pref.copyToClipboard) { TextInserter.copy(text) }
            deliver(text, gen: gen)
        } catch {
            guard gen == generation else { return }
            composer.discard()
            fail(error.localizedDescription)
        }
    }

    /// Insert the final text: replace the inline preview in place if there is one; paste if focus is in a text
    /// field (or can't be determined); if focus is clearly not in a text field, wait for the user to click one
    private func deliver(_ text: String, gen: Int) {
        if composer.commit(text) {
            finishWithDone()
            return
        }
        if composer.focusKind() != .notEditable {
            TextInserter.insert(text)
            finishWithDone()
            return
        }
        pendingText = text
        phase = .pending
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(self?.pendingTimeout ?? 60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, gen == self.generation, self.phase == .pending else { return }
                // Insert once focus leaves a place that is clearly not a text field; clicking into a field whose
                // type can't be determined (e.g. WeChat) counts too
                if self.composer.focusKind() != .notEditable {
                    // Wait for this click's mouse-up before pasting
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard gen == self.generation, self.phase == .pending else { return }
                    TextInserter.insert(text)
                    self.pendingText = ""
                    self.finishWithDone()
                    return
                }
            }
            guard let self, gen == self.generation, self.phase == .pending else { return }
            self.copyPendingToClipboard()
            self.show(.notice(String(localized: "Copied to clipboard")), for: 2)
        }
    }

    private func copyPendingToClipboard() {
        guard !pendingText.isEmpty else { return }
        TextInserter.copy(pendingText)
        pendingText = ""
    }

    private func finishWithDone() {
        // Coming straight from transcribing, continue filling from the bar's current position; coming from the
        // click wait, the bar isn't on screen, so show it full
        if case .transcribing(let started, let expected) = phase {
            show(.done(started: started, expected: expected, finished: Date()), for: 0.35)
        } else {
            show(.done(started: .distantPast, expected: 1, finished: .distantPast), for: 0.35)
        }
    }

    private func cancel() {
        generation += 1
        previewTask?.cancel()
        pendingTask?.cancel()
        pendingText = ""
        recorder.cancel()
        composer.discard()
        phase = .idle
    }

    private func fail(_ message: String) {
        previewTask?.cancel()
        show(.failed(message), for: 2)
    }

    /// Show a transient state, then return to idle automatically
    private func show(_ p: Phase, for seconds: TimeInterval) {
        phase = p
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == p else { return }
                self.phase = .idle
            }
        }
    }
}
