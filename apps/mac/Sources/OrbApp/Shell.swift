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
    let screen = MacScreen()
    var companion: CompanionOverlay?
    var optionTap: OptionTap?
    var windows: [String: NSWindow] = [:]

    init() {
        model = AppModel(transport: LiveKitTransport(), screen: screen)
        island = IslandWindow()
        island.show(IslandRoot(model: model, island: island, actions: PanelActions(
            openSettings: { [weak self] in self?.showSettings() },
            allowScreen: { Self.openPrivacy("Privacy_ScreenCapture") })))
        model.talkShortcut = Self.label(KeyboardShortcuts.getShortcut(for: .talk))
        companion = CompanionOverlay(model: model)
        optionTap = OptionTap(model: model)
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
        menu.addItem(withTitle: "Inspector", action: #selector(showInspector), keyEquivalent: "i").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit orb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func showSettings() {
        show("settings", title: "orb Settings", SettingsView(model: model) {
            ShortcutRecorder(name: .talk) { [weak self] in self?.model.talkShortcut = $0 }
        })
    }

    @objc func showInspector() {
        show("inspector", title: "orb Inspector", InspectorView(model: model).frame(minWidth: 860, minHeight: 560))
    }

    /// One window per id: shown again if it exists, made once otherwise.
    func show<V: View>(_ id: String, title: String, _ view: V) {
        island.expanded = false
        NSApp.activate()
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        if let screen = window.screen ?? NSScreen.main {  // below the island, which covers the top of the screen
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: min(window.frame.maxY, screen.visibleFrame.maxY - 90)))
        }
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
    }

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
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
