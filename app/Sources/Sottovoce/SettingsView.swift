import ApplicationServices
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

/// Settings window: a segmented control at the top switches between the General, Shortcut, Dictation and Server
/// pages inside a fixed-size window. The form scrolls when its content is taller than the available space.
struct SettingsView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var server: LocalServer
    @ObservedObject var updater: Updater

    @AppStorage(Pref.triggerKey) private var triggerKey = TriggerKey.rightOption.rawValue
    @AppStorage(Pref.tapToToggle) private var tapToToggle = false
    @AppStorage(Pref.microphoneUID) private var microphoneUID = ""
    @AppStorage(Pref.punctuation) private var punctuation = PunctuationMode.dropTrailing.rawValue
    @AppStorage(Pref.livePreview) private var livePreview = true
    @AppStorage(Pref.micAlwaysOn) private var micAlwaysOn = false
    @AppStorage(Pref.copyToClipboard) private var copyToClipboard = true
    @AppStorage(Pref.connection) private var connection = ConnectionMode.local.rawValue
    @AppStorage(Pref.remoteURL) private var remoteURL = ""
    @AppStorage(Pref.remoteToken) private var remoteToken = ""
    @AppStorage(Pref.model) private var model = SpeechModel.accurate.rawValue
    @AppStorage(Pref.shareServer) private var shareServer = false
    @AppStorage(Pref.shareToken) private var shareToken = ""
    @AppStorage(Pref.serverPort) private var serverPort = Pref.defaultPort

    @State private var devices: [AudioInputDevice] = []
    @State private var accessibility = AXIsProcessTrusted()
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var service: Transcriber.Status?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tab = SettingsTab.general
    @State private var addresses: [String] = []

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)

            Form {
                switch tab {
                case .general: generalPage
                case .hotkey: hotkeyPage
                case .recording: recordingPage
                case .service: servicePage
                }
            }
            .formStyle(.grouped)
            // Every page fits the window, so pages never scroll and switching tabs never resizes anything
            .scrollDisabled(true)
            .scrollIndicators(.never)
        }
        // One size for every page: the window and tab bar stay put while pages are swapped
        .frame(width: 460, height: 470, alignment: .top)
        .task { await refresh() }
        .onReceive(poll) { _ in Task { await refresh() } }
    }

    /// General: permission and service status, launch at login, last transcription
    @ViewBuilder private var generalPage: some View {
        Section("Status") {
            status(String(localized: "Accessibility"), ok: accessibility,
                   hint: String(localized: "Used to detect the shortcut and paste text")) {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
            status(String(localized: "Microphone"), ok: microphone == .authorized, hint: String(localized: "Used for recording")) {
                if microphone == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
            }
            status(String(localized: "Transcription service"), ok: service == .ok, hint: serviceHint, action: nil)
        }

        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if Updater.isAvailable {
                Toggle("Update automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
            }
        }

        if !controller.lastText.isEmpty {
            Section("Last transcription") {
                // Two lines at most, so the page still fits without scrolling
                Text(controller.lastText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var hotkeyPage: some View {
        Section {
            Picker(selection: $triggerKey) {
                ForEach(TriggerKey.allCases) { Text($0.title).tag($0.rawValue) }
            } label: {
                Text("Hold to talk")
                Text("Hold to dictate, release to finish").lineLimit(1)
            }
            Toggle(isOn: $tapToToggle) {
                Text("Tap for hands-free")
                Text("Tap to start, tap again to finish, Esc to cancel").lineLimit(1)
            }
        } footer: {
            footnote(String(localized: "Pressing another key while holding cancels, as it's likely a shortcut"))
        }
    }

    @ViewBuilder private var recordingPage: some View {
        Section {
            Picker(selection: $microphoneUID) {
                Text("Automatic").tag("")
                ForEach(devices) { Text($0.name).tag($0.uid) }
            } label: {
                Text("Microphone")
                Text("Default microphone for dictation").lineLimit(1)
            }
            .onChange(of: microphoneUID) { controller.applyMicSettings() }
            Toggle(isOn: $micAlwaysOn) {
                Text("Keep microphone on")
                Text("Catches the first word; the mic indicator stays on").lineLimit(1)
            }
            .onChange(of: micAlwaysOn) { controller.applyMicSettings() }
        }
        Section {
            Toggle(isOn: $livePreview) {
                Text("Live preview")
                Text("Shows words in the text field while you speak").lineLimit(1)
            }
            Picker("Punctuation", selection: $punctuation) {
                ForEach(PunctuationMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle(isOn: $copyToClipboard) {
                Text("Keep result on clipboard")
                Text("In case pasting fails or you cancel").lineLimit(1)
            }
        }
    }

    @ViewBuilder private var servicePage: some View {
        Section {
            Picker("Connection", selection: $connection) {
                ForEach(ConnectionMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if connection == ConnectionMode.remote.rawValue {
                TextField("Address", text: $remoteURL, prompt: Text("http://mac-mini:8008"))
                SecureField("Token", text: $remoteToken, prompt: Text("SOTTOVOCE_TOKEN of the server"))
            }
        } footer: {
            footnote(connection == ConnectionMode.remote.rawValue
                     ? String(localized: "Use the server's LAN or Tailscale IP address")
                     : String(localized: "Runs inside Sottovoce; models are kept in ~/.cache/huggingface"))
        }
        .onChange(of: connection) { Task { await refresh() } }

        if connection == ConnectionMode.local.rawValue {
            Section {
                Picker("Model", selection: $model) {
                    ForEach(SpeechModel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                // Taken when Return is pressed or the field loses focus; an unusable number is dropped
                TextField("Port", value: Binding(get: { Pref.localPort },
                                                 set: { if Pref.validPort($0) { serverPort = $0 } }),
                          format: .number.grouping(.never), prompt: Text(verbatim: String(Pref.defaultPort)))
                    .multilineTextAlignment(.trailing)
                serverStatus
            }

            Section {
                Toggle(isOn: $shareServer) {
                    Text("Share with other devices")
                    Text("Other Macs on your network or Tailscale can use this one").lineLimit(1)
                }
                .onChange(of: shareServer) { _, on in
                    if on { shareToken = Pref.serverToken }
                }
                if shareServer {
                    // One row per network, styled like the token: the address and a copy button. Tailscale is
                    // recommended because it reaches this Mac from anywhere, the LAN address only on the same network
                    ForEach(shareAddresses, id: \.address) { row in
                        LabeledContent {
                            copyable(shareURL(row.address))
                        } label: {
                            HStack(spacing: 6) {
                                Text(row.tailscale ? "Tailscale" : "LAN")
                                if row.tailscale && shareAddresses.count > 1 {
                                    Text("Recommended")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                    LabeledContent("Token") {
                        copyable(shareToken)
                    }
                }
            }
        }
    }

    /// State of the server built into the app: download progress, starting, running, or what went wrong
    @ViewBuilder private var serverStatus: some View {
        switch server.state {
        case .off:
            EmptyView()
        case .needsDownload:
            status(String(localized: "Speech model not downloaded"), ok: false,
                   hint: String(localized: "Downloaded once, then kept on this Mac"),
                   button: "Download \(SpeechModel.downloadSize(Pref.speechModel, preview: server.wantsPreview))") {
                server.approveDownload()
            }
        case .downloading(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading models…")
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(total > 0 ? "\(bytes(done)) of \(bytes(total))" : "Preparing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloadFailed(let message):
            status(String(localized: "Download failed"), ok: false, hint: message, button: "Retry") { server.retry() }
        case .starting:
            // Two lines like the other states, so the rows below don't jump while the server restarts
            HStack {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading) {
                    Text("Starting the server…")
                    Text(verbatim: Pref.localServerURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .running:
            status(String(localized: "Running on this Mac"), ok: true, hint: Pref.localServerURL, action: nil)
        case .external:
            status(String(localized: "Using the server already running on this Mac"), ok: true,
                   hint: String(localized: "Started outside the app; its own model applies"), action: nil)
        case .failed(let message):
            status(String(localized: "The server stopped"), ok: false, hint: message, button: "Restart") { server.retry() }
        }
    }

    private func shareURL(_ address: String) -> String { "http://\(address):\(String(Pref.localPort))" }

    /// The first address on the LAN and the first on Tailscale (100.64.0.0/10), Tailscale last
    private var shareAddresses: [(address: String, tailscale: Bool)] {
        func isTailscale(_ ip: String) -> Bool {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        }
        let lan = addresses.first { !isTailscale($0) }.map { (address: $0, tailscale: false) }
        let tailscale = addresses.first(where: isTailscale).map { (address: $0, tailscale: true) }
        return [lan, tailscale].compactMap { $0 }
    }

    /// A value to hand to another Mac: monospaced, selectable, with a copy button
    private func copyable(_ value: String) -> some View {
        HStack {
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            Button {
                copy(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .memory)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() async {
        devices = Recorder.inputDevices()
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        addresses = NetworkAddresses.current()
        if shareServer && shareToken.isEmpty { shareToken = Pref.serverToken }
        service = Pref.server.isEmpty ? .unreachable : await Transcriber.check(server: Pref.server, token: Pref.token)
    }

    private var serviceHint: String {
        switch service {
        case nil: return String(localized: "Checking…")
        case .ok where Pref.connectionMode == .local:
            return server.state == .external ? String(localized: "Using the server already running on this Mac") : Pref.server
        case .ok: return Pref.server
        case _ where Pref.connectionMode == .local:
            return localProblem
        case .unauthorized: return String(localized: "Invalid token: \(Pref.server)")
        case .unreachable:
            return Pref.server.isEmpty ? String(localized: "No remote address set") : String(localized: "Can't reach \(Pref.server)")
        }
    }

    /// Why the server on this Mac isn't answering, for the General page
    private var localProblem: String {
        switch server.state {
        case .downloading(let done, let total) where total > 0:
            return String(localized: "Downloading models: \(bytes(done)) of \(bytes(total))")
        case .downloading: return String(localized: "Downloading models…")
        case .needsDownload: return String(localized: "Speech model not downloaded")
        case .downloadFailed(let message): return String(localized: "Download failed: \(message)")
        case .failed(let message): return String(localized: "The server stopped: \(message)")
        default: return String(localized: "Starting the server…")
        }
    }

    private func status(_ title: String, ok: Bool, hint: String, button: LocalizedStringKey = "Grant Access",
                        action: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                // Errors can be long: one line here, the whole text on hover
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(hint)
            }
            Spacer()
            if !ok, let action {
                Button(button, action: action)
            }
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, hotkey, recording, service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .hotkey: return String(localized: "Shortcut")
        case .recording: return String(localized: "Dictation")
        case .service: return String(localized: "Server")
        }
    }
}
