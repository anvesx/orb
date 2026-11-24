import AppKit
@preconcurrency import ApplicationServices
import OrbKit

/// Accessibility's view of the front app: its focused window, the selection (never from a password field) and the
/// file of the open document.
enum FrontApp {
    @MainActor static func read() -> (ScreenReading, document: URL?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (ScreenReading(), nil) }
        var r = ScreenReading(app: app.localizedName), document: URL?
        guard AXIsProcessTrusted() else {
            r.note = "No window, selection or document: orb has no Accessibility permission."
            return (r, nil)
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        if let window: AXUIElement = ax.value(kAXFocusedWindowAttribute) {
            r.window = window.value(kAXTitleAttribute)
            if let path: String = window.value(kAXDocumentAttribute), let url = URL(string: path), url.isFileURL {
                document = url
            }
        }
        if let focused: AXUIElement = ax.value(kAXFocusedUIElementAttribute),
           (focused.value(kAXSubroleAttribute) as String?) != (kAXSecureTextFieldSubrole as String),
           let selected: String = focused.value(kAXSelectedTextAttribute), !selected.isEmpty {
            r.selection = selected
        }
        return (r, document)
    }
}

extension AXUIElement {
    func value<T>(_ attribute: String) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &out) == .success else { return nil }
        return out as? T
    }
}
