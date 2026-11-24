import AppKit
@preconcurrency import ApplicationServices
import OrbKit
import os

private let log = Logger(subsystem: "ai.anvesx.orb", category: "keys")

/// Watches for a double tap of ⌥ anywhere and toggles hands-free. macOS shows a lone modifier key to an app only when
/// it has the Accessibility permission, so it asks once and waits until it is given.
@MainActor
final class OptionTap {
    let model: AppModel
    var detector = DoubleTap()
    var optionDown = false
    var monitors: [Any] = []
    var waiting: Timer?

    init(model: AppModel) {
        self.model = model
        // asked only when a feature needs it: the double tap, and the window, selection and document of the screen
        let ask = model.settings.doubleTapOption || model.settings.screen
        let prompt = ["AXTrustedCheckOptionPrompt": ask] as CFDictionary  // kAXTrustedCheckOptionPrompt
        let trusted = AXIsProcessTrustedWithOptions(prompt)
        trusted ? install() : wait()
    }

    func wait() {
        model.doubleTapBlocked = "Double-tap ⌥ needs orb in System Settings › Privacy & Security › Accessibility. Holding the talk key works without it."
        waiting = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                self?.waiting?.invalidate()
                self?.install()
            }
        }
    }

    func install() {
        model.doubleTapBlocked = nil
        let handle: (NSEvent) -> Void = { [weak self] event in
            let type = event.type, flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, flags, time) }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { handle($0); return $0 } as Any)
    }

    func handle(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ time: TimeInterval) {
        guard model.settings.doubleTapOption else { return }
        if type == .keyDown { return detector.otherKey() }
        if flags == .option, !optionDown {
            optionDown = true
            detector.modifierDown(at: time)
        } else if flags.isEmpty, optionDown {
            optionDown = false
            if detector.modifierUp(at: time) {
                log.debug("double tap of the option key")
                model.toggleHandsFree()
            }
        } else {  // another modifier with ⌥, or alone
            optionDown = false
            detector.otherKey()
        }
    }
}
