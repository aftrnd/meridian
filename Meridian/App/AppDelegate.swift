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
        log.info("App terminating — killing Wine processes")
        let prefix = WinePrefix.defaultPrefix
        let prefixPath = prefix.path.path(percentEncoded: false)

        // Try CrossOver wineserver first, then bundled
        let candidates = [
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/wineserver",
            WineEngine.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false),
        ]

        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }

            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = ["-k"]
            process.environment = ["WINEPREFIX": prefixPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                log.info("Wine processes killed via \(path) (exit=\(process.terminationStatus))")
                return
            } catch {
                log.warning("Failed with \(path): \(error.localizedDescription)")
            }
        }

        log.info("No wineserver found — nothing to clean up")
    }
}
