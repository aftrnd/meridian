import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "TerminationCleanup")

/// Kills all Wine/Steam processes owned by Meridian.
///
/// Designed to be called from `applicationShouldTerminate` on a background
/// thread so the main thread never blocks. Uses SIGKILL directly — Wine and
/// Steam have no meaningful graceful shutdown path, so skipping SIGTERM avoids
/// the extra sleep/wait cycle that caused the previous freeze.
enum TerminationCleanup {

    /// Immediately SIGKILLs all steam.exe, wineserver, and wineloader processes.
    /// Fast and synchronous — suitable for a background dispatch.
    static func killAllWineProcesses() {
        log.info("[cleanup] SIGKILLing all Wine/Steam processes")
        pkill(["-9", "-f", "steam.exe"])
        pkill(["-9", "-x", "wineserver"])
        pkill(["-9", "-x", "wineloader"])
        log.info("[cleanup] done")
    }

    @discardableResult
    private static func pkill(_ args: [String]) -> Int32 {
        let t = Process()
        t.executableURL = URL(filePath: "/usr/bin/pkill")
        t.arguments = args
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        return t.terminationStatus
    }
}
