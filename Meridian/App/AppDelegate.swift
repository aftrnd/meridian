import AppKit
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("App terminating — killing all Wine processes")
        TerminationCleanup.killAllWineProcesses()
    }
}
