import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TunerXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TunerModel()

    var body: some Scene {
        WindowGroup("TunerX") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1400, height: 820)
    }
}
