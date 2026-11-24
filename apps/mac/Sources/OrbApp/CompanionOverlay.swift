import AppKit
import Observation
import QuartzCore
import OrbKit
import OrbUI
import SwiftUI

/// The companion and the canvas: one transparent, click-through window per screen that never moves. During a call,
/// the window of the screen under the companion moves its view there on every display frame; each window's renderer
/// draws the canvas on its display. The companion flies to the canvas's focus and back (screen-canvas.md).
@MainActor
final class CompanionOverlay {
    let model: AppModel
    var overlays: [ScreenOverlay] = []
    var flight = Flight.follow
    var focus: String?
    var last = NSEvent.mouseLocation

    init(model: AppModel) {
        self.model = model
        build()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.build() } }
        track()
    }

    func build() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { ScreenOverlay(screen: $0, model: model) { [weak self] in self?.position() ?? NSEvent.mouseLocation } }
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
        let canvas = model.canvas
        if canvas.focus?.id != focus {
            focus = canvas.focus?.id
            flight = Flight(to: canvas.focus.map(Self.stand), from: last, start: CACurrentMediaTime(),
                            duration: canvas.focus == nil ? 0.35 : 0.5)
        }
        overlays.forEach { $0.renderer.render(canvas.annotations, appearAfter: flight.duration * 0.7) }
    }

    /// Where the companion stands for an annotation: under the start of a passage, under the middle of a loop.
    static func stand(_ a: Annotation) -> CGPoint {
        let b = a.anchor.bounds
        return a.kind == .mark(.circle) ? CGPoint(x: b.midX, y: b.minY) : CGPoint(x: b.minX, y: b.minY)
    }

    /// Where the companion stands now, in global points: the pointer, or on its way to or from what orb shows.
    func position() -> CGPoint {
        last = flight.position(at: CACurrentMediaTime(), pointer: NSEvent.mouseLocation)
        return last
    }
}

@MainActor
final class ScreenOverlay: NSObject {
    let screen: NSScreen
    let window: NSPanel
    let companion: NSHostingView<CompanionView>
    let renderer: CanvasRenderer
    let position: () -> CGPoint
    var link: CADisplayLink?
    var active = false { didSet { if active != oldValue { activeChanged() } } }

    init(screen: NSScreen, model: AppModel, position: @escaping () -> CGPoint) {
        self.screen = screen
        self.position = position
        renderer = CanvasRenderer(screen: screen)
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
        root.layer?.addSublayer(renderer.root)
        companion.sizingOptions = [.intrinsicContentSize]
        root.addSubview(companion)
        window.contentView = root
        link = root.displayLink(target: self, selector: #selector(tick))
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }

    /// The window is on screen for the whole call: a view's display link ticks only while its window is visible.
    func activeChanged() {
        if active {
            companion.isHidden = true
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
        link?.isPaused = !active
    }

    @objc func tick(_ link: CADisplayLink) {
        let mouse = position()
        let here = NSMouseInRect(mouse, screen.frame, false)
        companion.isHidden = !here
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
