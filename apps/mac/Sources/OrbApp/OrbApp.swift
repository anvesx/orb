import AppKit
import OrbKit
import SwiftUI

@main
struct OrbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var app

    var body: some Scene {
        Settings { EmptyView() }  // PR 3: the settings window
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shell: Shell?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon (also when run outside the bundle)
        shell = Shell()
    }
}
