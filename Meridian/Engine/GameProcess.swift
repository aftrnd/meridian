import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "GameProcess")

/// Monitors a game launched through Wine/Steam.
///
/// After `steam.exe -applaunch`, the game runs as a Wine subprocess.
/// We detect game exit by checking whether Wine processes are still alive.
///
/// Wine games appear as native macOS windows managed by the window server.
/// No display wrapper is needed — the game renders through D3DMetal to Metal.
@Observable
@MainActor
final class GameProcess {

    private(set) var isRunning: Bool = false
    private(set) var appID: Int = 0
    private(set) var logs: [String] = []

    /// PID of the launched Wine process. Used to check if the session is still alive.
    private(set) var launchedPID: Int32 = 0

    private var monitorTask: Task<Void, Never>?

    // MARK: - Public API

    /// Begins monitoring after steam.exe -applaunch dispatch.
    func startMonitoring(
        appID: Int,
        launchedPID: Int32,
        engine: WineEngine,
        prefix: WinePrefix
    ) {
        log.info("[startMonitoring] appID=\(appID) pid=\(launchedPID)")
        self.appID = appID
        self.launchedPID = launchedPID
        self.isRunning = true
        self.logs = []

        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            await self?.monitorLoop(appID: appID, launchedPID: launchedPID, prefix: prefix)
        }
    }

    /// Stops the game by killing the Wine server for the prefix.
    func stopGame(engine: WineEngine, prefix: WinePrefix) {
        let currentAppID = self.appID
        log.info("[stopGame] appID=\(currentAppID) — sending wineserver -k")
        monitorTask?.cancel()
        monitorTask = nil

        let wineserverPath = engine.wineserverURL.path(percentEncoded: false)
        let prefixPath = prefix.path.path(percentEncoded: false)
        Task.detached {
            Self.killWineServer(wineserverPath: wineserverPath, prefixPath: prefixPath)
        }

        isRunning = false
        launchedPID = 0
        log.info("[stopGame] game stopped")
    }

    func appendLog(_ line: String) {
        logs.append(line)
        log.info("[game] \(line)")
    }

    // MARK: - Private

    /// Monitors Wine processes to detect when the game session ends.
    ///
    /// CrossOver's `wineloader` is a launcher that forks and exits immediately
    /// (exit code 0). The actual game runs under the wineserver as a child of
    /// `wine64-preloader`. We therefore rely on two signals:
    ///
    ///   1. **Wine process count** (primary) — counts all processes whose
    ///      environment or command line references our WINEPREFIX.
    ///   2. **Launched PID liveness** (secondary) — supplements the primary
    ///      check but does NOT trigger exit alone, because CrossOver's
    ///      wineloader exits almost immediately by design.
    ///
    /// All blocking operations run on background threads via `Task.detached`.
    private func monitorLoop(
        appID: Int,
        launchedPID: Int32,
        prefix: WinePrefix
    ) async {
        log.info("[monitor] started for appID=\(appID) pid=\(launchedPID)")
        appendLog("Monitoring game (appID=\(appID))")

        log.info("[monitor] grace period (15s) for game process to start")
        try? await Task.sleep(for: .seconds(15))
        log.info("[monitor] grace period ended — starting active polling")

        var pollCount = 0
        var consecutiveEmpty = 0
        var pidExited = false

        while !Task.isCancelled {
            pollCount += 1

            if !pidExited {
                let pidAlive = await Task.detached {
                    Self.isProcessAlive(pid: launchedPID)
                }.value
                if !pidAlive {
                    pidExited = true
                    log.info("[monitor] launched process (pid=\(launchedPID)) exited (expected for CrossOver launcher)")
                }
            }

            let prefixPath = prefix.path.path(percentEncoded: false)
            let (wineProcessCount, matchedLines) = await Task.detached {
                Self.countWineProcessesVerbose(prefixPath: prefixPath)
            }.value

            if wineProcessCount == 0 {
                consecutiveEmpty += 1
                log.info("[monitor] poll=\(pollCount) | pidExited=\(pidExited) | wineProcs=0 (consecutive=\(consecutiveEmpty))")

                if consecutiveEmpty >= 2 {
                    log.info("[monitor] game exited (no Wine processes for 2 consecutive polls)")
                    appendLog("Game exited")
                    break
                }
            } else {
                consecutiveEmpty = 0
                log.info("[monitor] poll=\(pollCount) | pidExited=\(pidExited) | wineProcs=\(wineProcessCount)")
                if pollCount <= 3 || pollCount % 6 == 0 {
                    for line in matchedLines {
                        log.debug("[monitor]   matched: \(line.prefix(200))")
                    }
                }
            }

            try? await Task.sleep(for: .seconds(5))
        }

        if Task.isCancelled {
            log.info("[monitor] cancelled (appID=\(appID))")
        }

        isRunning = false
        self.launchedPID = 0
        log.info("[monitor] ended for appID=\(appID)")
    }

    /// Checks whether a process is still alive without sending a signal.
    private nonisolated static func isProcessAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Counts Wine processes associated with the given prefix path.
    /// Returns the count and the matched lines for diagnostic logging.
    /// Runs on a background thread — never call from MainActor directly.
    private nonisolated static func countWineProcessesVerbose(prefixPath: String) -> (Int, [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["axeww", "-o", "pid,command"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("[countWineProcesses] ps failed: \(error.localizedDescription)")
            return (0, [])
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let matched = output
            .components(separatedBy: .newlines)
            .filter { line in
                line.localizedCaseInsensitiveContains("wine") && line.contains(prefixPath)
            }

        return (matched.count, matched)
    }

    /// Kills the Wine server for the prefix. Runs on a background thread.
    private nonisolated static func killWineServer(wineserverPath: String, prefixPath: String) {
        let process = Process()
        process.executableURL = URL(filePath: wineserverPath)
        process.arguments = ["-k"]
        process.environment = ["WINEPREFIX": prefixPath]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[killWineServer] exit=\(process.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[killWineServer] stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[killWineServer] failed: \(error.localizedDescription)")
        }
    }
}
