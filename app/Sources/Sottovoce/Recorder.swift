import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Microphone recording. Audio is converted to 16 kHz mono on the fly, which is exactly the format the server
/// decodes to, and keeps uploads small.
///
/// Measured startup latency (USB audio interface): creating the input node of a new engine takes 0.1–1.2 s, and
/// starting the device until the first frame takes 0.25–0.6 s; speech during that time after the press is lost. So:
/// - The engine is built once and reused, rebuilt only when the device changes; a press only starts the device
/// - After recording, the device stays warm for warmSeconds before stopping, so consecutive dictation starts instantly
/// - With "Keep microphone on" the engine runs all the time and keeps the prerollSeconds before the press, for zero
///   latency; the cost is a permanently lit orange mic dot in the menu bar and Bluetooth headsets stuck in call quality
final class Recorder {
    /// Live level (0...1), called back on the main thread only while recording, for the HUD waveform
    var onLevel: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "sottovoce.recorder")
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// The orange mic dot stays lit while warm; 2 minutes covers the "say something, glance, say more" gap
    private let warmSeconds: TimeInterval = 120
    private let prerollSeconds: Double = 0.3

    // Accessed only on queue
    private var engine: AVAudioEngine?
    private var engineUID: String?
    private var running = false
    private var alwaysOn = false
    private var idleStop: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?

    // Written by the audio thread and read elsewhere; guarded by lock
    private let lock = NSLock()
    private var recording = false
    private var samples: [Float] = []
    private var preroll: [Float] = []

    /// Build the engine ahead of time (without starting the device) to skip creating the input node on the first
    /// press. Requires microphone permission
    func prepare(deviceUID: String, alwaysOn: Bool) {
        queue.async { [self] in
            self.alwaysOn = alwaysOn
            _ = ensureEngine(uid: deviceUID)
            if alwaysOn {
                _ = startEngine()
            } else if running, !isRecording {
                scheduleIdleStop()
            }
        }
    }

    /// Start recording. An empty deviceUID follows the system default input. Completion or failure is called back
    /// on the main thread.
    func start(deviceUID: String, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            idleStop?.cancel()
            var err = ensureEngine(uid: deviceUID)
            if err == nil {
                lock.lock()
                // If the engine is already running (always on or warm), include a short stretch of audio from before the press
                samples = running ? preroll : []
                recording = true
                lock.unlock()
                err = startEngine()
            }
            if err != nil {
                lock.lock(); recording = false; lock.unlock()
            }
            DispatchQueue.main.async { completion(err) }
        }
    }

    /// Stop recording and return the WAV data and its duration in seconds.
    func stop(completion: @escaping (Data, Double) -> Void) {
        queue.async { [self] in
            let pcm = takeSamples()
            scheduleIdleStop()
            let wav = Self.wav(pcm[...])
            let seconds = Double(pcm.count) / Self.target.sampleRate
            DispatchQueue.main.async { completion(wav, seconds) }
        }
    }

    /// Discard the current recording
    func cancel() {
        queue.async { [self] in
            _ = takeSamples()
            scheduleIdleStop()
        }
    }

    /// Snapshot during recording: WAV of the last maxSeconds and the total recorded duration, for live preview.
    /// Callable from any thread
    func snapshot(maxSeconds: Double) -> (wav: Data, total: Double)? {
        lock.lock()
        guard recording else { lock.unlock(); return nil }
        let maxCount = Int(maxSeconds * Self.target.sampleRate)
        let tail = samples.suffix(maxCount)
        let total = Double(samples.count) / Self.target.sampleRate
        lock.unlock()
        return (Self.wav(tail), total)
    }

    private var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recording
    }

    private func takeSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        recording = false
        let pcm = samples
        samples = []
        preroll = []
        return pcm
    }

    /// Keep the device warm for a while after recording before stopping it; never stop in always-on mode
    private func scheduleIdleStop() {
        idleStop?.cancel()
        guard running, !alwaysOn else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording, !self.alwaysOn else { return }
            self.stopEngine()
        }
        idleStop = item
        queue.asyncAfter(deadline: .now() + warmSeconds, execute: item)
    }

    /// Build a new engine when needed: first use, a different microphone, or a system audio configuration change
    /// (device plugged or unplugged, default input switched)
    private func ensureEngine(uid: String) -> Error? {
        if engine != nil, engineUID == uid { return nil }
        teardownEngine()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !uid.isEmpty, let dev = Self.inputDevices().first(where: { $0.uid == uid }), let unit = input.audioUnit {
            var id = dev.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: Self.target) else {
            return RecorderError(String(localized: "No microphone available"))
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter)
        }
        engine.prepare()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Device changed: drop the old engine and rebuild for the new device on next use; rebuild right away when
            // always on or recording
            guard let self else { return }
            self.queue.async {
                let restart = self.alwaysOn || self.isRecording
                let uid = self.engineUID ?? ""
                self.teardownEngine()
                if restart, self.ensureEngine(uid: uid) == nil { _ = self.startEngine() }
            }
        }
        self.engine = engine
        engineUID = uid
        return nil
    }

    private func startEngine() -> Error? {
        guard let engine else { return RecorderError(String(localized: "No microphone available")) }
        if running { return nil }
        do {
            try engine.start()
            running = true
            return nil
        } catch {
            return RecorderError(String(localized: "Microphone failed to start: \(error.localizedDescription)"))
        }
    }

    private func stopEngine() {
        guard running else { return }
        engine?.stop()
        running = false
        lock.lock(); preroll = []; lock.unlock()
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        engineUID = nil
        running = false
    }

    /// Audio thread: resample and append to the recording buffer (or the preroll ring buffer when not recording),
    /// and compute the level
    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))

        lock.lock()
        let isRecording = recording
        if isRecording {
            samples.append(contentsOf: chunk)
        } else {
            preroll.append(contentsOf: chunk)
            let keep = Int(prerollSeconds * Self.target.sampleRate)
            if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
        }
        lock.unlock()
        guard isRecording else { return }

        // RMS to dB, mapped to 0...1; below -50 dB counts as silence
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = sqrt(sum / Float(chunk.count))
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 50) / 50, 0), 1)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Encode Float32 samples as 16-bit PCM WAV
    static func wav(_ pcm: ArraySlice<Float>) -> Data {
        let rate = UInt32(target.sampleRate)
        let dataSize = UInt32(pcm.count * 2)
        var d = Data(capacity: 44 + Int(dataSize))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        var ints = [Int16](repeating: 0, count: pcm.count)
        for (i, v) in pcm.enumerated() { ints[i] = Int16(max(-1, min(1, v)) * Float(Int16.max)).littleEndian }
        ints.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Enumerate all audio devices with input channels
    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
