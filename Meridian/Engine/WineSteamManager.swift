import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "WineSteamManager")

/// Manages the Steam client running inside Wine.
///
/// Responsible for:
///   - Bootstrapping Steam on first run (downloading the full client)
///   - Launching games via steam.exe -applaunch (Steam handles its own init)
///   - Stopping Steam / killing Wine processes
@Observable
@MainActor
final class WineSteamManager {

    private(set) var isRunning: Bool = false

    // MARK: - Bootstrap

    /// Whether Steam needs its first-run bootstrap.
    ///
    /// `SteamSetup.exe /S` installs only the bootstrapper (~2MB). The full
    /// Steam client (including `steamui.dll`) is downloaded when Steam.exe
    /// runs for the first time.
    func needsBootstrap(prefix: WinePrefix) -> Bool {
        let dllPath = prefix.steamInstallDir.appending(path: "steamui.dll")
        let exists = FileManager.default.fileExists(atPath: dllPath.path(percentEncoded: false))
        log.info("[needsBootstrap] steamui.dll exists=\(exists) at \(dllPath.path(percentEncoded: false))")
        return !exists
    }

    /// Runs Steam non-silently to complete the first-run client download.
    ///
    /// Launches Steam.exe without `-silent` so it can show its update UI
    /// and download the full client (~150MB). Waits for `steamui.dll` to
    /// appear on disk, then shuts Steam down.
    func bootstrap(engine: WineEngine, prefix: WinePrefix) async throws {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        log.info("[bootstrap] starting Steam for first-run client download")

        let args = [
            steamExe,
            "-no-browser",
            "-allosarches",
            "+@AllowSkipGameUpdate", "1",
        ]
        log.info("[bootstrap] launching: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.environment(for: prefix)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            log.error("[bootstrap] failed to launch Steam: \(error.localizedDescription)")
            throw error
        }

        isRunning = true
        log.info("[bootstrap] Steam bootstrap started pid=\(process.processIdentifier)")

        let dllPath = prefix.steamInstallDir.appending(path: "steamui.dll").path(percentEncoded: false)
        let started = ContinuousClock.now
        let timeout: Duration = .seconds(300)
        var attempt = 0

        log.info("[bootstrap] waiting for steamui.dll (timeout=\(timeout))")

        while ContinuousClock.now - started < timeout {
            attempt += 1

            if FileManager.default.fileExists(atPath: dllPath) {
                let elapsed = ContinuousClock.now - started
                log.info("[bootstrap] steamui.dll found after \(attempt) checks (\(elapsed))")
                break
            }

            if !process.isRunning {
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log.error("[bootstrap] Steam exited during bootstrap (exit=\(process.terminationStatus))")
                if !stderr.isEmpty {
                    log.error("[bootstrap] stderr: \(stderr.prefix(2000))")
                }

                if FileManager.default.fileExists(atPath: dllPath) {
                    log.info("[bootstrap] steamui.dll present despite exit — bootstrap OK")
                    break
                }

                isRunning = false
                throw SteamError.bootstrapFailed(
                    exitCode: process.terminationStatus,
                    detail: "Steam exited before steamui.dll was downloaded"
                )
            }

            if attempt % 5 == 0 {
                let elapsed = ContinuousClock.now - started
                log.info("[bootstrap] waiting… attempt=\(attempt) elapsed=\(elapsed)")
            }

            try? await Task.sleep(for: .seconds(3))
        }

        guard FileManager.default.fileExists(atPath: dllPath) else {
            log.error("[bootstrap] TIMEOUT: steamui.dll not found after \(timeout)")
            if process.isRunning { process.terminate() }
            isRunning = false
            throw SteamError.bootstrapFailed(exitCode: -1, detail: "Timed out waiting for steamui.dll")
        }

        log.info("[bootstrap] shutting down Steam after successful bootstrap")
        try? await Task.sleep(for: .seconds(5))

        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
        }

        isRunning = false
        log.info("[bootstrap] Steam bootstrap complete ✓")
    }

    // MARK: - Game Launch

    /// Launches a game via `wine64 steam.exe -applaunch APPID`.
    ///
    /// Steam handles its own initialization, login, and game launch in a
    /// single process tree. The parent steam.exe stays alive as the Steam
    /// client — we do NOT wait for it to exit. Game exit is detected by
    /// GameProcess monitoring Wine processes.
    ///
    /// Steam is launched WITHOUT `-silent` so it can show its login window
    /// if the user hasn't authenticated yet. After first login, Steam
    /// remembers credentials and future launches auto-login.
    @discardableResult
    func launchGame(
        appID: Int,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws -> Int32 {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let args = [steamExe, "-silent", "-applaunch", "\(appID)"]
        log.info("[launchGame] appID=\(appID) | wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args

        let env = engine.environment(for: prefix)
        process.environment = env
        log.info("[launchGame] WINEDLLOVERRIDES=\(env["WINEDLLOVERRIDES"] ?? "unset")")
        log.info("[launchGame] WINEDLLPATH=\(env["WINEDLLPATH"] ?? "unset")")
        log.info("[launchGame] WINEPREFIX=\(env["WINEPREFIX"] ?? "unset")")
        log.info("[launchGame] WINELOADER=\(env["WINELOADER"] ?? "unset")")
        log.debug("[launchGame] DYLD_FALLBACK_LIBRARY_PATH=\(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "unset")")
        log.debug("[launchGame] MTL_HUD_ENABLED=\(env["MTL_HUD_ENABLED"] ?? "unset")")

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            log.info("[launchGame] launched pid=\(process.processIdentifier)")
        } catch {
            log.error("[launchGame] failed to launch: \(error.localizedDescription)")
            throw error
        }

        let pid = process.processIdentifier

        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let lines = stderr.components(separatedBy: .newlines).prefix(100)
                for line in lines where !line.isEmpty {
                    log.info("[launchGame:stderr] \(line)")
                }
                if stderr.count > 5000 {
                    log.info("[launchGame:stderr] (truncated — \(stderr.count) chars total)")
                }
            } else {
                log.debug("[launchGame:stderr] (empty — process pid=\(pid) produced no stderr)")
            }
            if !process.isRunning {
                log.info("[launchGame] process pid=\(pid) exited with code=\(process.terminationStatus)")
            }
        }

        isRunning = true
        log.info("[launchGame] Steam+game process tree started — monitoring handoff to GameProcess")
        return pid
    }

    // MARK: - Process Control

    /// Stops the Steam client gracefully, then falls back to SIGTERM.
    func stop(engine: WineEngine, prefix: WinePrefix) async {
        log.info("[stop] sending -shutdown to Steam")
        let shutdownProcess = Process()
        shutdownProcess.executableURL = engine.wine64URL
        shutdownProcess.arguments = [prefix.steamExePath.path(percentEncoded: false), "-shutdown"]
        shutdownProcess.environment = engine.environment(for: prefix)

        let errPipe = Pipe()
        shutdownProcess.standardOutput = FileHandle.nullDevice
        shutdownProcess.standardError = errPipe

        do {
            try shutdownProcess.run()
            shutdownProcess.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[stop] shutdown exit=\(shutdownProcess.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[stop] shutdown stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[stop] failed to run -shutdown: \(error.localizedDescription)")
        }

        try? await Task.sleep(for: .seconds(3))
        isRunning = false
        log.info("[stop] Steam stopped")
    }

    /// Kills the Wine server for the prefix, terminating all Wine processes.
    func killAll(engine: WineEngine, prefix: WinePrefix) {
        log.info("[killAll] sending wineserver -k")
        let process = Process()
        process.executableURL = engine.wineserverURL
        process.arguments = ["-k"]
        process.environment = engine.environment(for: prefix)

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[killAll] wineserver -k exit=\(process.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[killAll] stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[killAll] failed to run wineserver -k: \(error.localizedDescription)")
        }

        isRunning = false
    }

    // MARK: - Errors

    enum SteamError: LocalizedError {
        case bootstrapFailed(exitCode: Int32, detail: String)

        var errorDescription: String? {
            switch self {
            case .bootstrapFailed(let code, let detail):
                return "Steam bootstrap failed (exit \(code)): \(detail)"
            }
        }
    }
}
