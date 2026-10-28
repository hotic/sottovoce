import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Lives in the menu bar with no Dock icon (LSUIElement in Info.plist).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller()
    private var hud: HUD?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var cancellable: AnyCancellable?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        hud = HUD(controller: controller)
        setupEditMenu()
        setupStatusItem()
        controller.startMonitoring()
        controller.applyMicSettings()
        // A menu-bar app with no visible window gets throttled by App Nap, which delays key callbacks
        // and the HUD; keep App Nap off for the lifetime of the app
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Listening for the dictation hotkey")

        // Without Accessibility permission, show the system prompt and poll until granted,
        // then re-register the monitors
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            showSettings()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard AXIsProcessTrusted() else { return }
                    timer.invalidate()
                    self?.controller.startMonitoring()
                }
            }
        }
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
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Sottovoce"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // The menu-bar icon is the logo's wave; it turns into a filled badge while recording or transcribing
        let plain = Self.waveIcon(filled: false), filled = Self.waveIcon(filled: true)
        cancellable = controller.$phase.sink { [weak item] phase in
            switch phase {
            case .recording, .transcribing: item?.button?.image = filled
            default: item?.button?.image = plain
            }
        }
    }

    /// The logo's dying-away wave as an 18 pt template image, so the menu bar tints it for light and dark.
    /// Filled draws a rounded badge with the wave cut out of it
    private static func waveIcon(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let wave = NSBezierPath()
            let (x0, width, mid, amp) = (1.5, 12.6, 9.0, 5.6)
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
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller))
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
