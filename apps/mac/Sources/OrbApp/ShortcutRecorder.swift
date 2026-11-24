@preconcurrency import KeyboardShortcuts
import SwiftUI

/// Click, then press the new shortcut (with at least one modifier); Esc cancels. KeyboardShortcuts' own recorder
/// needs a resource bundle that SwiftPM cannot place inside an app bundle (apps/mac/LLD.md, Bundle).
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    let changed: (String) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label: String

    init(name: KeyboardShortcuts.Name, changed: @escaping (String) -> Void) {
        self.name = name
        self.changed = changed
        _label = State(initialValue: Shell.label(KeyboardShortcuts.getShortcut(for: name)))
    }

    var body: some View {
        Button(recording ? "Press a shortcut…" : label) { recording ? stop() : start() }
            .onDisappear(perform: stop)
    }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let escape = event.keyCode == 53
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let pressed = mods.isEmpty ? nil : KeyboardShortcuts.Shortcut(event: event)
            MainActor.assumeIsolated {
                if escape { stop(); return }
                guard let shortcut = pressed else { return }
                KeyboardShortcuts.setShortcut(shortcut, for: name)
                label = Shell.label(shortcut)
                changed(label)
                stop()
            }
            return nil  // the keys go to the recorder, not to the window
        }
    }

    func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
