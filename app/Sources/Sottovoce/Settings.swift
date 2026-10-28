import Foundation

/// Key that triggers recording. Only single modifier keys, so holding one doesn't clash with regular shortcuts.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, rightShift, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return String(localized: "Right ⌥")
        case .rightCommand: return String(localized: "Right ⌘")
        case .rightControl: return String(localized: "Right ⌃")
        case .rightShift: return String(localized: "Right ⇧")
        case .fn: return "fn"
        }
    }

    /// Virtual key code (Carbon kVK_*)
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// Device-dependent bit in the modifier flags that tells left from right (IOKit NX_DEVICER*KEYMASK);
    /// fn uses the generic function bit
    var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .rightShift: return 0x04
        case .fn: return 0x800000
        }
    }
}

/// How punctuation in transcription results is handled; the "Punctuation" setting.
enum PunctuationMode: String, CaseIterable, Identifiable {
    case smart, full, dropTrailing, spaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return String(localized: "Smart punctuation")
        case .full: return String(localized: "Add full punctuation")
        case .dropTrailing: return String(localized: "Drop trailing punctuation")
        case .spaces: return String(localized: "Spaces instead of punctuation")
        }
    }
}

/// How to reach the transcription service: the server built into the app (or one already running on this Mac), or one
/// on another machine over the LAN / Tailscale.
enum ConnectionMode: String, CaseIterable, Identifiable {
    case local, remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return String(localized: "This Mac")
        case .remote: return String(localized: "Remote")
        }
    }
}

/// UserDefaults key names and defaults live here; the settings window reads and writes the same keys via @AppStorage.
enum Pref {
    static let triggerKey = "triggerKey"
    static let tapToToggle = "tapToToggle"
    static let microphoneUID = "microphoneUID"
    static let punctuation = "punctuation"
    static let livePreview = "livePreview"
    static let micAlwaysOn = "micAlwaysOn"
    static let copyToClipboard = "copyToClipboard"
    static let connection = "connection"
    static let remoteURL = "remoteURL"
    static let remoteToken = "remoteToken"
    static let model = "model"
    static let shareServer = "shareServer"
    static let shareToken = "shareToken"
    /// Set once the welcome window's last step is done
    static let onboarded = "onboarded"
    /// The user chose a model and started the first download; until then nothing is downloaded on its own
    static let downloadApproved = "downloadApproved"

    /// Port of the server on this Mac; 8008 unless another app needs it
    static let serverPort = "serverPort"
    static let defaultPort = 8008

    /// The port setting, back to the default when it holds something unusable
    static var localPort: Int {
        let port = UserDefaults.standard.integer(forKey: serverPort)
        return validPort(port) ? port : defaultPort
    }

    /// Ports below 1024 need root
    static func validPort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    static var localServerURL: String { "http://127.0.0.1:\(localPort)" }

    static func register() {
        UserDefaults.standard.register(defaults: [
            triggerKey: TriggerKey.rightOption.rawValue,
            tapToToggle: false,
            microphoneUID: "",
            punctuation: PunctuationMode.dropTrailing.rawValue,
            livePreview: true,
            micAlwaysOn: false,
            copyToClipboard: true,
            connection: ConnectionMode.local.rawValue,
            remoteURL: "",
            remoteToken: "",
            model: SpeechModel.accurate.rawValue,
            shareServer: false,
            shareToken: "",
            serverPort: defaultPort,
            onboarded: false,
            downloadApproved: false,
        ])
    }

    static var trigger: TriggerKey {
        TriggerKey(rawValue: UserDefaults.standard.string(forKey: triggerKey) ?? "") ?? .rightOption
    }

    static var punctuationMode: PunctuationMode {
        PunctuationMode(rawValue: UserDefaults.standard.string(forKey: punctuation) ?? "") ?? .dropTrailing
    }

    static var connectionMode: ConnectionMode {
        ConnectionMode(rawValue: UserDefaults.standard.string(forKey: connection) ?? "") ?? .local
    }

    static var speechModel: SpeechModel {
        SpeechModel(rawValue: UserDefaults.standard.string(forKey: model) ?? "") ?? .accurate
    }

    /// Token other devices use to reach this Mac's server when sharing is on; created on first use
    static var serverToken: String {
        if let token = UserDefaults.standard.string(forKey: shareToken), !token.isEmpty { return token }
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        UserDefaults.standard.set(token, forKey: shareToken)
        return token
    }

    /// Server address in use: 127.0.0.1 and the port setting in local mode, the configured address in remote mode
    /// (http:// may be omitted)
    static var server: String {
        guard connectionMode == .remote else { return localServerURL }
        let s = UserDefaults.standard.string(forKey: remoteURL)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.contains("://") || s.isEmpty ? s : "http://" + s
    }

    /// Bearer token for a remote server; not needed in local mode
    static var token: String {
        guard connectionMode == .remote else { return "" }
        return UserDefaults.standard.string(forKey: remoteToken)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
