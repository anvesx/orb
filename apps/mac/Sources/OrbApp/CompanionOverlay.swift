import AppKit
import Observation
import QuartzCore
import OrbKit
import OrbUI
import SwiftUI

/// The companion next to the pointer: one transparent, click-through window per screen that never moves. During a
/// call, the window of the screen under the companion moves its view there on every display frame. When orb shows
/// something (mac-screen.md section 5), the companion flies to it and the words under it are highlighted.
@MainActor
final class CompanionOverlay {
    let model: AppModel
    var overlays: [ScreenOverlay] = []
    var flight = Flight.follow
    var shown: UUID?
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
        let target = model.pointer
        guard target?.id != shown else { return }
        shown = target?.id
        flight = Flight(to: target?.point, from: last, start: CACurrentMediaTime(), duration: target == nil ? 0.35 : 0.5)
        overlays.forEach { $0.highlight(target?.rects ?? [], after: flight.duration * 0.8) }
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
    let marks = CALayer()
    let position: () -> CGPoint
    var link: CADisplayLink?
    var active = false { didSet { if active != oldValue { activeChanged() } } }

    init(screen: NSScreen, model: AppModel, position: @escaping () -> CGPoint) {
        self.screen = screen
        self.position = position
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
        root.layer?.addSublayer(marks)
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

    /// A highlighter over each rect on this screen: it sweeps in left to right, line after line. No rects clears it.
    func highlight(_ rects: [CGRect], after delay: TimeInterval) {
        let old = marks.sublayers ?? []
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock { old.forEach { $0.removeFromSuperlayer() } }
        old.forEach { $0.opacity = 0 }
        CATransaction.commit()
        let tint = NSColor(Theme.speak2).cgColor
        for (i, rect) in rects.enumerated() where rect.intersects(screen.frame) {
            let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).insetBy(dx: -4, dy: -3)
            let mark = CALayer()
            mark.frame = local
            mark.backgroundColor = tint.copy(alpha: 0.28)
            mark.borderColor = tint.copy(alpha: 0.85)
            mark.borderWidth = 1
            mark.cornerRadius = 5
            mark.shadowColor = tint
            mark.shadowRadius = 10
            mark.shadowOpacity = 0.55
            mark.shadowOffset = .zero
            let sweep = CALayer()
            sweep.backgroundColor = CGColor(gray: 1, alpha: 1)
            sweep.anchorPoint = CGPoint(x: 0, y: 0.5)
            sweep.frame = CGRect(origin: .zero, size: local.size).insetBy(dx: -12, dy: -12)
            mark.mask = sweep
            marks.addSublayer(mark)
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = 0
            grow.toValue = sweep.bounds.width
            grow.duration = 0.35
            grow.beginTime = CACurrentMediaTime() + delay + Double(i) * 0.12
            grow.fillMode = .backwards
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sweep.add(grow, forKey: "sweep")
        }
    }

    func close() {
        link?.invalidate()
        window.close()
    }
}
