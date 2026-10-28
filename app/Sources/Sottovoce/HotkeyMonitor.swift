import AppKit

/// Global monitor for the trigger key. Only observes, never intercepts; needs Accessibility permission,
/// without which global monitors receive no key events.
final class HotkeyMonitor {
    enum Event {
        case triggerDown
        case triggerUp
        /// Any key other than the trigger (including other modifiers), used to detect key combos and Esc
        case otherKey(UInt16)
    }

    var onEvent: ((Event) -> Void)?
    private var monitors: [Any] = []
    private var triggerHeld = false

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(g)
        }
        // Global monitors get no events while this app's own window is frontmost, so add a local monitor too
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        triggerHeld = false
    }

    private func handle(_ e: NSEvent) {
        let trigger = Pref.trigger
        switch e.type {
        case .flagsChanged where e.keyCode == trigger.keyCode:
            let down = e.modifierFlags.rawValue & trigger.deviceMask != 0
            guard down != triggerHeld else { return }
            triggerHeld = down
            onEvent?(down ? .triggerDown : .triggerUp)
        case .flagsChanged:
            // Only presses matter; releasing another modifier doesn't count
            let pressed = e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue != 0
            if pressed { onEvent?(.otherKey(e.keyCode)) }
        case .keyDown:
            if !e.isARepeat { onEvent?(.otherKey(e.keyCode)) }
        default:
            break
        }
    }
}
