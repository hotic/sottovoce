import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Lives in the menu bar with no Dock icon (LSUIElement in Info.plist).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller()
    private let server = LocalServer()
    private var hud: HUD?
    private var welcome: WelcomeWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        hud = HUD(controller: controller)
        controller.notReady = { [server] in server.notReadyMessage }
        server.start()
        setupEditMenu()
        setupStatusItem()
        controller.startMonitoring()
        controller.applyMicSettings()
        // A menu-bar app with no visible window gets throttled by App Nap, which delays key callbacks
        // and the HUD; keep App Nap off for the lifetime of the app
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Listening for the dictation hotkey")

        // Without Accessibility permission, poll until granted, then re-register the monitors. The welcome window
        // asks for it, so there is no system prompt at launch
        let trusted = AXIsProcessTrusted()
        if !trusted {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard AXIsProcessTrusted() else { return }
                    timer.invalidate()
                    self?.controller.startMonitoring()
                }
            }
        }

        let welcome = WelcomeWindow(controller: controller, server: server) { [weak self] in
            self?.statusItem?.button?.window?.frame
        }
        self.welcome = welcome
        if !UserDefaults.standard.bool(forKey: Pref.onboarded) || !trusted {
            welcome.show()
        } else {
            // Set up before, but the models are gone (a cleared cache, a new Mac with old settings): bring the
            // window up for the first check after launch that finds them missing
            var checked = false
            server.$state.sink { state in
                guard !checked, state != .off else { return }
                checked = true
                switch state {
                case .needsDownload, .downloading: welcome.show()
                default: break
                }
            }
            .store(in: &cancellables)
        }
        // A download sent to the background during setup: the window comes back, without taking focus, as soon as
        // the download is over, for the last step or to show why it failed (a failure only changes the menu's
        // status line, which nobody would notice). Only on leaving .downloading: the state is reassigned every
        // two seconds, and a window the user closed must not keep coming back
        var previous = LocalServer.State.off
        server.$state.sink { state in
            defer { previous = state }
            guard case .downloading = previous, !UserDefaults.standard.bool(forKey: Pref.onboarded), welcome.isTucked else {
                return
            }
            if case .downloading = state { return }
            welcome.show(activate: false)
        }
        .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// A menu-bar app has no main menu, and shortcuts like ⌘C / ⌘V are dispatched through the Edit menu;
    /// install an invisible main menu so text fields in the settings window can paste
    private func setupEditMenu() {
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        // While the server on this Mac downloads models or starts, a disabled first line says so
        let serverLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        serverLine.isEnabled = false
        let serverSeparator = NSMenuItem.separator()
        menu.addItem(serverLine)
        menu.addItem(serverSeparator)
        server.$state.sink { state in
            let message = LocalServer.message(for: state)
            serverLine.title = message ?? ""
            serverLine.isHidden = message == nil
            serverSeparator.isHidden = message == nil
        }
        .store(in: &cancellables)
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Sottovoce"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // The menu-bar icon is the logo's wave; it turns into a filled badge while recording or transcribing, and
        // carries a progress bar while models download
        let plain = Self.waveIcon(filled: false), filled = Self.waveIcon(filled: true)
        controller.$phase.combineLatest(server.$state).sink { [weak item] phase, state in
            switch (phase, state) {
            case (.recording, _), (.transcribing, _):
                item?.button?.image = filled
            case (_, .downloading(let done, let total)) where total > 0:
                item?.button?.image = Self.waveIcon(filled: false, progress: Double(done) / Double(total))
            default:
                item?.button?.image = plain
            }
        }
        .store(in: &cancellables)
    }

    /// The logo's dying-away wave as an 18 pt template image, so the menu bar tints it for light and dark.
    /// Filled draws a rounded badge with the wave cut out of it; progress (0...1) lifts the wave and draws a bar under it
    private static func waveIcon(filled: Bool, progress: Double? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let wave = NSBezierPath()
            let (x0, width) = (1.5, 12.6)
            let (mid, amp) = progress == nil ? (9.0, 5.6) : (11.0, 4.2)
            for i in 0...80 {
                let t = Double(i) / 80
                let p = NSPoint(x: x0 + width * t, y: mid + amp * sin(t * .pi * 4.5) * pow(1 - t, 1.3))
                i == 0 ? wave.move(to: p) : wave.line(to: p)
            }
            wave.lineWidth = 1.8
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            let dot = NSBezierPath(ovalIn: NSRect(x: 15.2, y: mid - 1, width: 2, height: 2))
            NSColor.black.set()
            if filled {
                NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).fill()
                // Cut the wave and dot out of the badge
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            wave.stroke()
            dot.fill()
            if let progress {
                let track = NSRect(x: 1.5, y: 1.5, width: 15, height: 2.2)
                NSColor.black.withAlphaComponent(0.3).set()
                NSBezierPath(roundedRect: track, xRadius: 1.1, yRadius: 1.1).fill()
                NSColor.black.set()
                var bar = track
                bar.size.width = max(2.2, track.width * min(max(progress, 0), 1))
                NSBezierPath(roundedRect: bar, xRadius: 1.1, yRadius: 1.1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sottovoce"
        return image
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Sottovoce"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller, server: server))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Keep the server address field from grabbing focus as soon as the window opens
        DispatchQueue.main.async { self.settingsWindow?.makeFirstResponder(nil) }
    }
}

// The entry point runs on the main thread; say so explicitly to satisfy AppDelegate's main-actor isolation
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
