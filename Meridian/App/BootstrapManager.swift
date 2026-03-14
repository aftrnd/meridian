import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "BootstrapManager")

/// Orchestrates the full app initialization pipeline at launch.
///
/// Runs each phase in order, skipping steps that are already complete
/// (prefix exists, Steam installed, etc.). The final phase starts a
/// persistent Steam process so game launches are near-instant via IPC.
///
/// State is published for the splash screen to display real milestones.
@Observable
@MainActor
final class BootstrapManager {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case detectingEngine
        case creatingPrefix
        case installingSteam
        case bootstrappingSteam
        case syncingSession
        case startingSteam
        case waitingForSteam
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Human-readable status line for the splash screen.
    private(set) var statusMessage: String = ""

    var isReady: Bool { phase == .ready }

    private var bootstrapTask: Task<Void, Never>?

    // MARK: - Public API

    func start(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge
    ) {
        guard phase == .idle || isFailed else { return }

        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.runPipeline(
                engine: engine,
                steamManager: steamManager,
                sessionBridge: sessionBridge
            )
        }
    }

    /// Retry after a failure — resets to idle and restarts.
    func retry(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge
    ) {
        phase = .idle
        statusMessage = ""
        start(engine: engine, steamManager: steamManager, sessionBridge: sessionBridge)
    }

    // MARK: - Pipeline

    private let prefix = WinePrefix.defaultPrefix

    private func runPipeline(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge
    ) async {
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP PIPELINE START")
        log.info("║ engine ready=\(engine.isReady)")
        log.info("║ prefix exists=\(self.prefix.exists)")
        log.info("║ steam installed=\(self.prefix.isSteamInstalled)")
        log.info("║ needs bootstrap=\(steamManager.needsBootstrap(prefix: self.prefix))")
        log.info("╚══════════════════════════════════════════════════")

        // 1. Detect engine
        transition(to: .detectingEngine, message: "Detecting Wine engine…")

        guard engine.isReady else {
            fail("Wine engine not installed. Open Settings to download it.")
            return
        }
        log.info("[bootstrap] engine OK — \(engine.backendName)")

        guard !Task.isCancelled else { return }

        // 2. Create prefix if needed
        if !prefix.exists {
            transition(to: .creatingPrefix, message: "Creating Wine environment…")
            do {
                try await prefix.create(engine: engine)
                log.info("[bootstrap] prefix created")
            } catch {
                fail("Failed to create Wine environment: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 3. Install Steam if needed
        if !prefix.isSteamInstalled {
            transition(to: .installingSteam, message: "Downloading and installing Steam…")
            do {
                try await prefix.installSteam(engine: engine)
                log.info("[bootstrap] Steam installed")
            } catch {
                fail("Failed to install Steam: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 4. Bootstrap Steam (first-run client download) if needed
        if steamManager.needsBootstrap(prefix: prefix) {
            transition(to: .bootstrappingSteam, message: "Steam is updating — first launch takes a few minutes…")
            do {
                try await steamManager.bootstrap(engine: engine, prefix: prefix)
                log.info("[bootstrap] Steam client bootstrapped")
            } catch {
                fail("Steam update failed: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 5. Sync macOS Steam session for auto-login
        transition(to: .syncingSession, message: "Syncing Steam session…")
        let strategy = await sessionBridge.prepare(prefix: prefix)
        switch strategy {
        case .sessionFileCopy:
            log.info("[bootstrap] session files copied for auto-login")
        case .none:
            log.info("[bootstrap] no macOS Steam session — manual login may be needed")
        }

        guard !Task.isCancelled else { return }

        // 6. Start persistent Steam process
        transition(to: .startingSteam, message: "Starting Steam…")
        do {
            try steamManager.startPersistent(engine: engine, prefix: prefix)
            log.info("[bootstrap] persistent Steam process launched")
        } catch {
            fail("Failed to start Steam: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        // 7. Wait for Steam to be fully ready
        transition(to: .waitingForSteam, message: "Waiting for Steam to initialize…")
        do {
            try await steamManager.waitUntilReady(prefix: prefix)
            log.info("[bootstrap] Steam is ready ✓")
        } catch {
            fail("Steam failed to start: \(error.localizedDescription)")
            return
        }

        transition(to: .ready, message: "Ready")
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP COMPLETE — Steam is running")
        log.info("╚══════════════════════════════════════════════════")
    }

    // MARK: - Helpers

    private func transition(to newPhase: Phase, message: String) {
        phase = newPhase
        statusMessage = message
        log.info("[bootstrap] phase=\(String(describing: newPhase)) | \(message)")
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        statusMessage = message
        log.error("[bootstrap] FAILED: \(message)")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
