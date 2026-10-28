import ApplicationServices
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

/// Settings window: a segmented control at the top switches between the General, Shortcut, Dictation and Server
/// pages inside a fixed-size window. The form scrolls when its content is taller than the available space.
struct SettingsView: View {
    @ObservedObject var controller: Controller

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

    @State private var devices: [AudioInputDevice] = []
    @State private var accessibility = AXIsProcessTrusted()
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var service: Transcriber.Status?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tab = SettingsTab.general

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
        }
        // Keep the window and tab bar steady while pages with different content heights are swapped.
        .frame(width: 460, height: 460, alignment: .top)
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
        }

        if !controller.lastText.isEmpty {
            Section("Last transcription") {
                // Show only a few lines of long text so the window doesn't grow too tall
                Text(controller.lastText)
                    .lineLimit(4)
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
                Text("Hold to dictate, release to finish")
            }
            Toggle(isOn: $tapToToggle) {
                Text("Tap for hands-free")
                Text("Tap once to start recording, tap again to finish, Esc to cancel")
            }
        } footer: {
            footnote(String(localized: "Pressing another key while holding is treated as a key combo and cancels the recording. Pick another key if your external keyboard has no fn key."))
        }
    }

    @ViewBuilder private var recordingPage: some View {
        Section {
            Picker(selection: $microphoneUID) {
                Text("Automatic").tag("")
                ForEach(devices) { Text($0.name).tag($0.uid) }
            } label: {
                Text("Microphone")
                Text("Default microphone for dictation")
            }
            .onChange(of: microphoneUID) { controller.applyMicSettings() }
            Toggle(isOn: $micAlwaysOn) {
                Text("Keep microphone on")
                Text("Records the instant you press without losing the start; the orange mic dot in the menu bar stays on, and Bluetooth headsets stay in call quality")
            }
            .onChange(of: micAlwaysOn) { controller.applyMicSettings() }
        }
        Section {
            Toggle(isOn: $livePreview) {
                Text("Live preview")
                Text("Writes the fast model's result into the text field as you speak and replaces it with the final text on release; unsupported text fields get the text only on release")
            }
            Picker("Punctuation", selection: $punctuation) {
                ForEach(PunctuationMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle(isOn: $copyToClipboard) {
                Text("Keep result on clipboard")
                Text("Also copies the result to the clipboard, so you can still paste it if it wasn't inserted or you cancelled; when off, the previous clipboard contents are restored after pasting")
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
                     ? String(localized: "Connect to the Sottovoce server on another machine on your LAN or Tailscale. Use the server's LAN or Tailscale IP; with a fake-IP proxy (e.g. Clash) running, hostnames may resolve to fake addresses.")
                     : String(localized: "Use the Sottovoce server running on this Mac (127.0.0.1:8008)."))
        }
        .onChange(of: connection) { Task { await refresh() } }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() async {
        devices = Recorder.inputDevices()
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        service = Pref.server.isEmpty ? .unreachable : await Transcriber.check(server: Pref.server, token: Pref.token)
    }

    private var serviceHint: String {
        switch service {
        case nil: return String(localized: "Checking…")
        case .ok: return Pref.server
        case .unauthorized: return String(localized: "Invalid token: \(Pref.server)")
        case .unreachable:
            return Pref.server.isEmpty ? String(localized: "No remote address set") : String(localized: "Can't reach \(Pref.server)")
        }
    }

    private func status(_ title: String, ok: Bool, hint: String, action: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok, let action {
                Button("Grant Access", action: action)
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
