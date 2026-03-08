@preconcurrency import Virtualization
import Foundation
import Observation

/// Orchestrates the full game launch pipeline:
///   1. Stage Steam session files into the virtio-fs share
///   2. Start the VM if it is not running
///   3. Retry connecting ProtonBridge via vsock until the guest daemon is up
///   4. Register log/exit/progress handlers
///   5. Send the launch command
///   6. Monitor game process exit and clean up
///
/// bridgeConnected lifecycle:
///   Set to true when vsock connect succeeds; cleared when:
///     - the guest exit event fires (game exited)
///     - the VM stops unexpectedly (guestDidStop / didStopWithError via vmStatusTask)
///   This ensures the next launch always reconnects after any VM restart.
@Observable
@MainActor
final class GameLauncher {

    // MARK: - State

    enum LaunchState: Equatable {
        case idle
        case preparingVM
        case connectingBridge
        case launching
        case running(appID: Int)
        case installing(appID: Int, progress: Double)
        case exited(appID: Int, code: Int)
        case failed(String)
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var logs: [String] = []

    // MARK: - Private

    private let bridge = ProtonBridge()
    private var bridgeConnected = false

    /// Observes VMManager state so bridgeConnected is cleared whenever the VM stops.
    private var vmObserverTask: Task<Void, Never>?

    // MARK: - Public API

    func launch(
        game: Game,
        vmManager: VMManager,
        steamAuth: SteamAuthService,
        sessionBridge: SteamSessionBridge
    ) async {
        switch launchState {
        case .preparingVM, .connectingBridge, .launching, .running, .installing:
            return  // already in flight
        case .idle, .exited, .failed:
            break
        }

        logs.removeAll()
        launchState = .preparingVM

        // 1. Stage Steam session files in the virtio-fs share before VM boots.
        await sessionBridge.prepare(auth: steamAuth)

        // 2. Start the VM if it is not already running.
        if !vmManager.state.isRunning {
            do {
                try await vmManager.start()
            } catch {
                launchState = .failed("Failed to start VM: \(error.localizedDescription)")
                return
            }
        }

        // Start observing VM state so we can clear bridgeConnected on any stop.
        startVMObserver(vmManager: vmManager)

        // 3. Connect ProtonBridge (guest daemon takes time to start — retry for 30 s).
        if !bridgeConnected {
            launchState = .connectingBridge
            guard let socketDevice = vmManager.socketDevice else {
                launchState = .failed("VM vsock device is unavailable.")
                return
            }
            let connected = await retryConnect(to: socketDevice, retries: 30, delay: .seconds(1))
            guard connected else {
                launchState = .failed(
                    "Could not connect to Proton bridge after 30 s. " +
                    "Check that meridian-bridge is installed in the base image."
                )
                return
            }
        }

        // 4. Register event handlers (overwrite previous handlers on each launch).
        await bridge.onLog { [weak self] line in
            Task { @MainActor [weak self] in self?.logs.append(line) }
        }
        await bridge.onExit { [weak self] code in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launchState = .exited(appID: game.id, code: code)
                self.bridgeConnected = false  // force reconnect on next launch
            }
        }
        await bridge.onProgress { [weak self] appID, pct in
            Task { @MainActor [weak self] in
                self?.launchState = .installing(appID: appID, progress: pct)
            }
        }

        // 5. Send launch command.
        launchState = .launching
        do {
            try await bridge.launchGame(appID: game.id, steamID: steamAuth.steamID)
            launchState = .running(appID: game.id)
        } catch {
            launchState = .failed("Launch command failed: \(error.localizedDescription)")
        }
    }

    /// Sends an install command for a game that hasn't been downloaded yet.
    func install(game: Game, vmManager: VMManager) async {
        guard vmManager.state.isRunning, bridgeConnected else {
            launchState = .failed("VM must be running to install games.")
            return
        }
        do {
            try await bridge.installGame(appID: game.id)
            launchState = .installing(appID: game.id, progress: 0)
        } catch {
            launchState = .failed("Install failed: \(error.localizedDescription)")
        }
    }

    /// Sends a stop command to the running game (graceful in-guest process kill).
    func stopGame() async {
        guard case .running = launchState else { return }
        try? await bridge.stopGame()
    }

    // MARK: - Private helpers

    private func retryConnect(
        to device: VZVirtioSocketDevice,
        retries: Int,
        delay: Duration
    ) async -> Bool {
        // Copy into local `let` so Swift 6 treats it as a non-isolated sending parameter
        // when we cross into the ProtonBridge actor via bridge.connect(to:).
        nonisolated(unsafe) let socketDevice = device
        for attempt in 1...retries {
            do {
                try await bridge.connect(to: socketDevice)
                bridgeConnected = true
                return true
            } catch {
                // Log every 5 attempts to avoid spamming the console
                if attempt % 5 == 0 {
                    logs.append("[bridge] connect attempt \(attempt)/\(retries) failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: delay)
            }
        }
        return false
    }

    /// Starts a lightweight observation task that clears `bridgeConnected` when
    /// the VM transitions out of `.ready` so the next launch always reconnects.
    private func startVMObserver(vmManager: VMManager) {
        vmObserverTask?.cancel()
        vmObserverTask = Task { [weak self, weak vmManager] in
            guard let vmManager else { return }
            var last = vmManager.state
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let current = vmManager.state
                if current != last {
                    // VM stopped or errored — reset bridge connection state
                    if case .stopped = current { self?.bridgeConnected = false }
                    if case .error   = current { self?.bridgeConnected = false }
                    if case .notProvisioned = current { self?.bridgeConnected = false }
                    last = current
                }
            }
        }
    }
}
