import AppKit
import Observation
import OrbKit
import OrbUI
import SwiftUI

/// The companion next to the pointer: one transparent, click-through window per screen that never moves. During a
/// call, the window of the screen under the pointer moves its companion view to the pointer on every display frame.
@MainActor
final class CompanionOverlay {
    let model: AppModel
    var overlays: [ScreenOverlay] = []

    init(model: AppModel) {
        self.model = model
        build()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.build() } }
        track()
    }

    func build() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { ScreenOverlay(screen: $0, model: model) }
        apply()
    }

    /// Runs the display links only while a call is on and the companion is wanted.
    func track() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    func apply() {
        let on = model.settings.companion && model.call.phase != .idle
        overlays.forEach { $0.active = on }
    }
}

@MainActor
final class ScreenOverlay: NSObject {
    let screen: NSScreen
    let window: NSPanel
    let companion: NSHostingView<CompanionView>
    var link: CADisplayLink?
    var active = false { didSet { if active != oldValue { activeChanged() } } }

    init(screen: NSScreen, model: AppModel) {
        self.screen = screen
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        companion = NSHostingView(rootView: CompanionView(model: model))
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        companion.sizingOptions = [.intrinsicContentSize]
        root.addSubview(companion)
        window.contentView = root
        link = root.displayLink(target: self, selector: #selector(tick))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }

    func activeChanged() {
        link?.isPaused = !active
        if !active { window.orderOut(nil) }
    }

    @objc func tick(_ link: CADisplayLink) {
        let mouse = NSEvent.mouseLocation
        let here = NSMouseInRect(mouse, screen.frame, false)
        if here != window.isVisible { here ? window.orderFrontRegardless() : window.orderOut(nil) }
        guard here else { return }
        let size = companion.intrinsicContentSize
        var x = mouse.x - screen.frame.minX + 14
        if x + size.width > screen.frame.width { x = mouse.x - screen.frame.minX - 14 - size.width }  // near the right edge
        let y = max(mouse.y - screen.frame.minY - 16 - size.height, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        companion.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        CATransaction.commit()
    }

    func close() {
        link?.invalidate()
        window.close()
    }
}
