import AppKit
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    // The size the main window should be at every cold launch.
    private static let launchWindowSize = NSSize(width: 1130, height: 620)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Defer one run-loop pass so SwiftUI has finished constructing its
        // WindowGroup before we touch the underlying NSWindow.
        DispatchQueue.main.async { [weak self] in
            self?.enforceMainWindowLaunchFrame()
        }
    }

    // Sets the main window to the canonical launch size and centers it,
    // and disables NSWindow's automatic frame-save so a previous user
    // resize never overrides this size on the next launch.
    private func enforceMainWindowLaunchFrame() {
        guard let window = NSApp.windows.first(where: {
            !$0.isSheet && $0.styleMask.contains(.titled)
        }) else {
            log.warning("enforceMainWindowLaunchFrame: no eligible window found")
            return
        }

        // An empty autosave name disables frame persistence for this window.
        window.setFrameAutosaveName("")

        window.setContentSize(Self.launchWindowSize)
        window.center()

        log.debug("Main window reset to \(Self.launchWindowSize.width, privacy: .public)×\(Self.launchWindowSize.height, privacy: .public) and centered")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("App terminating — killing all Wine processes")
        TerminationCleanup.killAllWineProcesses()
    }
}
