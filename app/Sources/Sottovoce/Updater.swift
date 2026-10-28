import Combine
import Foundation
import Sparkle

/// Updates through Sparkle, for release builds only. Every GitHub Release carries appcast.xml, which the app reads
/// from releases/latest/download/; the DMG it points to must match the EdDSA public key in Info.plist (SUPublicEDKey),
/// and Sparkle also requires the new app to be signed by the same Developer ID. Updates are checked once a day,
/// downloaded in the background and installed when the app quits; "Check for Updates…" in the menu checks right away.
///
/// app/build.sh leaves SUFeedURL out of source builds, so a build from source never checks or replaces itself with a
/// release (which would also carry a different signature and lose the permissions).
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    /// Whether this build updates itself
    static var isAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    func start() {
        guard Self.isAvailable else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    @objc func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// The Settings switch: daily checks with background download and install on quit, or manual checks only.
    /// Sparkle keeps both in the app's defaults
    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// A menu bar app has no window to come forward with, so Sparkle is told that an alert for a scheduled check
    /// (only shown when an update can't install by itself) may wait for a gentle moment instead of grabbing focus
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
