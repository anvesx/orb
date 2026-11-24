import AppKit
@preconcurrency import KeyboardShortcuts
import OrbKit
import OrbUI
import OrbVoice
import SwiftUI

extension KeyboardShortcuts.Name {
    nonisolated(unsafe) static let talk = Self("talk", default: .init(.space, modifiers: [.option]))
    nonisolated(unsafe) static let panel = Self("panel", default: .init(.space, modifiers: [.option, .shift]))
}

/// Owns the model and the app's surfaces: the island window, the menu bar item and the shortcuts.
@MainActor
final class Shell {
    let model: AppModel
    let island: IslandWindow
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let files = FilesProvider()

    init() {
        model = AppModel(transport: LiveKitTransport(), providers: [files])
        island = IslandWindow()
        island.show(IslandRoot(model: model, island: island, actions: PanelActions(
            pickFiles: { [weak self] in self?.pickFiles() },
            openSettings: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
            talkShortcut: Self.label(KeyboardShortcuts.getShortcut(for: .talk)))))
        setUpStatusItem()
        KeyboardShortcuts.onKeyDown(for: .talk) { [weak self] in self?.model.talkDown() }
        KeyboardShortcuts.onKeyUp(for: .talk) { [weak self] in self?.model.talkUp() }
        KeyboardShortcuts.onKeyDown(for: .panel) { [weak self] in self?.island.expanded.toggle() }
        model.refresh()
    }

    /// "⌥ Space" rather than the menu glyph for the space bar.
    static func label(_ shortcut: KeyboardShortcuts.Shortcut?) -> String {
        guard let shortcut else { return "the talk shortcut" }
        return shortcut.key == .space ? shortcut.modifiers.description + " Space" : shortcut.description
    }

    func setUpStatusItem() {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 2.2
            NSColor.black.setStroke()
            ring.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 1, y: rect.midY - 0.5, width: 5.5, height: 5.5)).fill()
            return true
        }
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel("orb")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open orb", action: #selector(IslandWindow.toggle), keyEquivalent: "").target = island
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit orb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders that orb can talk about."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { model.add(files.item(for: $0)) }
    }
}

/// The island's SwiftUI root: it binds the window's expanded state.
struct IslandRoot: View {
    let model: AppModel
    @ObservedObject var island: IslandWindow
    let actions: PanelActions

    var body: some View {
        IslandView(model: model, expanded: $island.expanded, actions: actions)
            .onChange(of: island.expanded) { _, open in if open { model.refresh() } }
    }
}
