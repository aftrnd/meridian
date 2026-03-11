import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "GameLauncher")

/// Orchestrates the full game launch pipeline via Wine + GPTK:
///
///   1. Verify Wine engine is installed
///   2. Ensure Wine prefix exists (create + install Steam if needed)
///   3. Bootstrap Steam client if first run (download steamui.dll etc.)
///   4. Copy macOS Steam session files into prefix for auto-login
///   5. Launch game via wine64 steam.exe -applaunch
///   6. Monitor Wine processes and report exit
@Observable
@MainActor
final class GameLauncher {

    // MARK: - State

    enum LaunchState: Equatable {
        case idle
        case preparingEngine
        case preparingPrefix
        case bootstrappingSteam
        case launching
        case running(appID: Int)
        case exited(appID: Int)
        case failed(String)
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var logs: [String] = []
    private(set) var currentActivity: String?

    private let gameProcess = GameProcess()
    private let prefix = WinePrefix.defaultPrefix
    private var launchTask: Task<Void, Never>?

    // MARK: - Public API

    func launch(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        library: SteamLibraryStore? = nil
    ) {
        switch launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching:
            log.warning("[launch] ignoring — already in state \(String(describing: self.launchState))")
            return
        case .running:
            log.info("[launch] currently in .running — stopping previous session before re-launch")
            gameProcess.stopGame(engine: engine, prefix: prefix)
        case .idle, .exited, .failed:
            break
        }

        launchTask?.cancel()
        launchTask = Task { [weak self] in
            await self?.executeLaunchPipeline(
                game: game,
                engine: engine,
                steamManager: steamManager,
                sessionBridge: sessionBridge,
                library: library
            )
        }
    }

    /// Cancels an in-progress launch. Cleans up any spawned processes.
    func cancelLaunch(engine: WineEngine, steamManager: WineSteamManager) async {
        log.info("[cancelLaunch] cancelling current launch")
        launchTask?.cancel()
        launchTask = nil

        await cleanupProcesses(engine: engine, steamManager: steamManager)

        launchState = .idle
        currentActivity = nil
        appendLog("Launch cancelled by user")
    }

    /// Stops the currently running game.
    func stopGame(engine: WineEngine, steamManager: WineSteamManager) async {
        guard case .running(let appID) = launchState else {
            log.warning("[stopGame] not in running state — current=\(String(describing: self.launchState))")
            return
        }
        log.info("[stopGame] stopping appID=\(appID)")
        gameProcess.stopGame(engine: engine, prefix: prefix)
        launchState = .exited(appID: appID)
    }

    /// Kills all Wine processes. Call on app termination or prefix reset.
    func cleanupProcesses(engine: WineEngine, steamManager: WineSteamManager) async {
        log.info("[cleanup] killing all Wine processes")
        steamManager.killAll(engine: engine, prefix: prefix)
        launchState = .idle
        currentActivity = nil
    }

    // MARK: - Launch Pipeline

    private func executeLaunchPipeline(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        library: SteamLibraryStore?
    ) async {
        logs.removeAll()
        currentActivity = nil

        log.info("╔══════════════════════════════════════════════════")
        log.info("║ LAUNCH: appID=\(game.id) '\(game.name)'")
        log.info("║ engine ready=\(engine.isReady)")
        log.info("║ prefix exists=\(self.prefix.exists)")
        log.info("║ steam installed=\(self.prefix.isSteamInstalled)")
        log.info("║ needs bootstrap=\(steamManager.needsBootstrap(prefix: self.prefix))")
        log.info("║ prefix path=\(self.prefix.path.path(percentEncoded: false))")
        log.info("║ wine64=\(engine.wine64URL.path(percentEncoded: false))")
        log.info("╚══════════════════════════════════════════════════")

        // 1. Verify engine.
        transition(to: .preparingEngine, activity: "Checking Wine runtime...")
        appendLog("[1/6] Checking Wine runtime...")

        guard engine.isReady else {
            fail("Wine runtime is not installed. Go to Settings to download it.")
            return
        }
        appendLog("[1/6] Wine runtime OK")

        guard !Task.isCancelled else { return }

        // 2. Ensure prefix exists.
        transition(to: .preparingPrefix, activity: "Preparing Wine environment...")

        if !prefix.exists {
            appendLog("[2/6] Creating Wine prefix...")
            do {
                try await prefix.create(engine: engine)
                appendLog("[2/6] Wine prefix created")
            } catch {
                fail("Failed to create Wine environment: \(error.localizedDescription)", error: error)
                return
            }
        } else {
            appendLog("[2/6] Wine prefix exists")
        }

        guard !Task.isCancelled else { return }

        // 3. Install Steam bootstrapper if needed.
        if !prefix.isSteamInstalled {
            transition(to: .preparingPrefix, activity: "Installing Steam...")
            appendLog("[3/6] Installing Steam into Wine prefix...")
            do {
                try await prefix.installSteam(engine: engine)
                appendLog("[3/6] Steam installed")
            } catch {
                fail("Failed to install Steam: \(error.localizedDescription)", error: error)
                return
            }
        } else {
            appendLog("[3/6] Steam already installed")
        }

        guard !Task.isCancelled else { return }

        // 4. Bootstrap Steam (first-run client download) if needed.
        if steamManager.needsBootstrap(prefix: prefix) {
            transition(to: .bootstrappingSteam, activity: "Steam is updating for the first time — this may take a few minutes...")
            appendLog("[4/6] Bootstrapping Steam (first-time client download)...")

            do {
                try await steamManager.bootstrap(engine: engine, prefix: prefix)
                appendLog("[4/6] Steam bootstrap complete")
            } catch {
                fail("Steam bootstrap failed: \(error.localizedDescription)", error: error)
                await cleanupProcesses(engine: engine, steamManager: steamManager)
                return
            }
        } else {
            appendLog("[4/6] Steam client ready")
        }

        guard !Task.isCancelled else { return }

        // 5. Copy session files from macOS Steam.
        currentActivity = "Syncing Steam session..."
        appendLog("[5/6] Syncing Steam session...")
        let strategy = await sessionBridge.prepare(prefix: prefix)
        switch strategy {
        case .sessionFileCopy:
            appendLog("[5/6] Copied macOS Steam session for auto-login")
        case .none:
            appendLog("[5/6] No macOS Steam session found — manual login may be required")
        }

        guard !Task.isCancelled else {
            log.info("[launch] cancelled before step 6")
            return
        }

        // 6. Launch game directly via steam.exe -applaunch.
        //    Steam handles its own initialization, login, and game launch
        //    in a single process tree. No need to pre-start Steam or wait
        //    for IPC — this is the standard approach used by Whisky/Mythic.
        transition(to: .launching, activity: "Launching \(game.name) — sign into Steam if prompted...")
        appendLog("[6/6] Launching steam.exe -applaunch \(game.id)")

        let launchedPID: Int32
        do {
            launchedPID = try await steamManager.launchGame(
                appID: game.id,
                engine: engine,
                prefix: prefix
            )
            appendLog("[6/6] Launch dispatched (pid=\(launchedPID))")
            log.info("[launch] wine process pid=\(launchedPID)")
        } catch {
            fail("Launch failed: \(error.localizedDescription)", error: error)
            await cleanupProcesses(engine: engine, steamManager: steamManager)
            return
        }

        // 7. Monitor Wine processes for game exit.
        launchState = .running(appID: game.id)
        currentActivity = nil
        appendLog("Game is running")
        library?.setInstalled(true, for: game.id)
        log.info("[launch] state=RUNNING appID=\(game.id) | monitoring pid=\(launchedPID)")

        gameProcess.startMonitoring(appID: game.id, launchedPID: launchedPID, engine: engine, prefix: prefix)

        while gameProcess.isRunning {
            if Task.isCancelled {
                log.info("[launch] task cancelled during monitoring — stopping game")
                gameProcess.stopGame(engine: engine, prefix: prefix)
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }

        guard !Task.isCancelled else {
            log.info("[launch] task cancelled — not setting exited state")
            return
        }

        appendLog("Game session ended")
        launchState = .exited(appID: game.id)
        currentActivity = nil
        log.info("[launch] state=EXITED appID=\(game.id)")
    }

    // MARK: - Private helpers

    private func transition(to state: LaunchState, activity: String) {
        launchState = state
        currentActivity = activity
        log.info("[launch] state=\(String(describing: state)) | \(activity)")
    }

    private func fail(_ message: String, error: Error? = nil) {
        launchState = .failed(message)
        currentActivity = nil
        appendLog("FAILED: \(message)")
        if let error {
            log.error("[launch] FAILED: \(message) | \(String(describing: error))")
        } else {
            log.error("[launch] FAILED: \(message)")
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        log.info("[log] \(line)")
    }
}
