import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "TerminationCleanup")

/// Kills all Wine processes for Meridian's prefix.
///
/// Called on app terminate (normal quit, force quit via Cmd+Q).
/// Uses wineserver -k first, then a nuclear fallback to catch any stragglers.
/// Fully synchronous — safe to call from applicationWillTerminate.
enum TerminationCleanup {

    private static let prefixMarker = "com.meridian.app/bottles"
    private static let ourPID = ProcessInfo.processInfo.processIdentifier

    static func killAllWineProcesses() {
        let prefix = WinePrefix.defaultPrefix
        let prefixPath = prefix.path.path(percentEncoded: false)
        log.info("[cleanup] killing all Wine processes for prefix=\(prefixPath)")

        // 1. Try wineserver -k (same detection order as WineEngine)
        let candidates = wineserverCandidates()
        var killedViaWineserver = false
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
                log.info("[cleanup] wineserver -k via \(path) exit=\(process.terminationStatus)")
                killedViaWineserver = true
                break
            } catch {
                log.warning("[cleanup] wineserver \(path) failed: \(error.localizedDescription)")
            }
        }
        if !killedViaWineserver {
            log.info("[cleanup] no wineserver found or all failed")
        }

        // 2. Brief wait for processes to exit
        Thread.sleep(forTimeInterval: 2)

        // 3. Nuclear fallback: kill any remaining processes that reference our prefix
        let stragglers = findProcessesWithPrefix(prefixPath: prefixPath)
        if !stragglers.isEmpty {
            log.info("[cleanup] killing \(stragglers.count) straggler process(es): \(stragglers)")
            for pid in stragglers {
                kill(pid, 9)
                log.info("[cleanup] sent SIGKILL to pid=\(pid)")
            }
        } else {
            log.info("[cleanup] no stragglers — cleanup complete")
        }
    }

    private static func wineserverCandidates() -> [String] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let engineDir = base.appending(path: "com.meridian.app/engine").path(percentEncoded: false)
        return [
            "\(engineDir)/wine/bin/wineserver",
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/wineserver",
        ]
    }

    /// Finds PIDs of processes whose command line contains our prefix path.
    /// Excludes our own process.
    private static func findProcessesWithPrefix(prefixPath: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["axeww", "-o", "pid,command"]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("[cleanup] ps failed: \(error.localizedDescription)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        var pids: Set<pid_t> = []

        for line in output.components(separatedBy: .newlines) {
            guard line.contains(prefixMarker) || line.contains(prefixPath) else { continue }
            let tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let pidStr = tokens.first, let pid = pid_t(pidStr.trimmingCharacters(in: .whitespaces)) else { continue }
            guard pid != ourPID else { continue }
            pids.insert(pid)
        }

        return Array(pids).sorted()
    }
}
