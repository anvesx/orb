import AppKit
import SwiftUI

/// A borderless, non-activating panel at the top centre of the main screen, under the menu bar (and the notch).
/// It is as big as its content: the island alone, or the island with the panel. A click outside closes the panel.
@MainActor
final class IslandWindow: NSObject, ObservableObject {
    @Published var expanded = false { didSet { expandedChanged() } }
    let panel: NSPanel
    var outsideClicks: Any?

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    func show<V: View>(_ root: V) {
        let host = FittingHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.onResize = { [weak self] in self?.place() }
        panel.contentView = host
        place()
        panel.orderFrontRegardless()
    }

    @objc func toggle() { expanded.toggle() }

    /// Top centre of the screen with the menu bar, below the menu bar or the notch.
    func place() {
        guard let screen = NSScreen.screens.first, let host = panel.contentView else { return }
        let size = host.fittingSize
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    func expandedChanged() {
        if expanded {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.expanded = false }
            }
        } else if let monitor = outsideClicks {
            NSEvent.removeMonitor(monitor)
            outsideClicks = nil
        }
    }
}

final class FittingHostingView<V: View>: NSHostingView<V> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
