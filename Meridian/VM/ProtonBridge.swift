@preconcurrency import Virtualization
import Foundation

/// Communicates with the meridian-bridge daemon running inside the VM
/// via virtio-vsock (port 1234).
///
/// Why vsock instead of a serial port Unix socket:
///   virtio-vsock gives us proper port-multiplexed bidirectional connections
///   managed entirely by Virtualization.framework. No external socket file is
///   needed; the host calls `vm.socketDevices.first.connect(toPort: 1234)` once
///   the VM is booted and the guest daemon is listening. Additional ports can be
///   used for future services (install progress, resize commands, screenshots)
///   without any plumbing changes.
///
/// Guest side:
///   meridian-bridge listens on AF_VSOCK port 1234 and speaks line-delimited
///   JSON with the host.
///
/// Protocol:
///   Host → Guest:  { "cmd": "launch",  "appid": 1091500, "steamid": "76561..." }
///   Host → Guest:  { "cmd": "install", "appid": 1091500 }
///   Host → Guest:  { "cmd": "stop" }
///   Host → Guest:  { "cmd": "resize",  "w": 1920, "h": 1080 }
///   Guest → Host:  { "event": "started",  "pid": 12345 }
///   Guest → Host:  { "event": "exited",   "code": 0 }
///   Guest → Host:  { "event": "log",      "line": "proton: ..." }
///   Guest → Host:  { "event": "progress", "appid": 1091500, "pct": 42.5 }
actor ProtonBridge {

    // MARK: - Port

    static let vsockPort: UInt32 = VMConfiguration.bridgeVsockPort

    // MARK: - State

    private var socketConnection: VZVirtioSocketConnection?  // retained to keep fd alive
    private var connection: Connection?
    private var logHandler: (@Sendable (String) -> Void)?
    private var exitHandler: (@Sendable (Int) -> Void)?
    private var progressHandler: (@Sendable (Int, Double) -> Void)?

    // MARK: - Public API

    /// Connects to the meridian-bridge daemon in the guest.
    ///
    /// Must be called after the VM is fully booted and the guest daemon is listening.
    /// GameLauncher retries this call until it succeeds or a timeout is reached.
    ///
    /// - Parameter device: The VZVirtioSocketDevice from the running VZVirtualMachine.
    /// Connects to the meridian-bridge daemon in the guest.
    ///
    /// Declared nonisolated so the VZVirtioSocketDevice does not need to cross
    /// an actor boundary.
    nonisolated func connect(to device: VZVirtioSocketDevice) async throws {
        nonisolated(unsafe) let d = device
        let conn = try await vsockConnect(device: d, port: Self.vsockPort)
        // Re-enter the actor to update isolated state.
        await setConnection(conn)
    }

    private func setConnection(_ conn: VZVirtioSocketConnection) {
        socketConnection = conn
        connection = Connection(fileDescriptor: conn.fileDescriptor)
        Task { await readLoop() }
    }

    func disconnect() {
        connection?.close()
        connection = nil
        socketConnection?.close()
        socketConnection = nil
    }

    // MARK: - Commands

    func launchGame(appID: Int, steamID: String) async throws {
        try await send(["cmd": "launch", "appid": appID, "steamid": steamID])
    }

    func installGame(appID: Int) async throws {
        try await send(["cmd": "install", "appid": appID])
    }

    func stopGame() async throws {
        try await send(["cmd": "stop"])
    }

    func resizeDisplay(width: Int, height: Int) async throws {
        try await send(["cmd": "resize", "w": width, "h": height])
    }

    // MARK: - Handlers

    func onLog(_ handler: @escaping @Sendable (String) -> Void) {
        logHandler = handler
    }

    func onExit(_ handler: @escaping @Sendable (Int) -> Void) {
        exitHandler = handler
    }

    func onProgress(_ handler: @escaping @Sendable (Int, Double) -> Void) {
        progressHandler = handler
    }

    // MARK: - Private

    private func send(_ payload: [String: any Sendable]) async throws {
        guard let conn = connection else { throw BridgeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A]) // newline
        try conn.write(data)
    }

    private func readLoop() async {
        guard let conn = connection else { return }
        for await line in conn.lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch json["event"] as? String ?? "" {
            case "log":
                if let text = json["line"] as? String { logHandler?(text) }
            case "exited":
                exitHandler?(json["code"] as? Int ?? -1)
            case "progress":
                if let appid = json["appid"] as? Int, let pct = json["pct"] as? Double {
                    progressHandler?(appid, pct)
                }
            default:
                break
            }
        }
    }

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Not connected to Proton bridge." }
    }
}

// MARK: - Nonisolated vsock connection factory
//
// Keeps the VZVirtioSocketDevice completion handler in a nonisolated scope so
// Swift 6 cannot infer actor isolation on the closure (same defensive pattern
// used for ASWebAuthenticationSession in SteamAuthService).

private func vsockConnect(device: sending VZVirtioSocketDevice, port: UInt32) async throws -> VZVirtioSocketConnection {
    // VZVirtioSocketDevice and VZVirtioSocketConnection are ObjC framework types
    // without formal Sendable conformance. We suppress the data-race warnings via
    // nonisolated(unsafe) since Apple documents these as safe to use across threads.
    nonisolated(unsafe) let d = device
    return try await withCheckedThrowingContinuation { cont in
        d.connect(toPort: port) { result in
            switch result {
            case .success(let connection):
                nonisolated(unsafe) let c = connection
                cont.resume(returning: c)
            case .failure(let error):
                cont.resume(throwing: error)
            }
        }
    }
}

// MARK: - Unix fd connection helper

private final class Connection: @unchecked Sendable {
    private let fd: Int32

    init(fileDescriptor: Int32) {
        fd = fileDescriptor
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { ptr in
            let n = send(fd, ptr.baseAddress!, data.count, 0)
            guard n == data.count else { throw POSIXError(.EIO) }
        }
    }

    /// Returns an AsyncStream of newline-terminated lines read from the fd.
    func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached {
                var buffer = ""
                var chunk  = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let n = recv(self.fd, &chunk, chunk.count, 0)
                    guard n > 0 else { break }
                    buffer += String(bytes: chunk.prefix(n), encoding: .utf8) ?? ""
                    // Split on newlines, yielding each complete line.
                    // Use range.upperBound to consume the newline itself correctly.
                    while let range = buffer.range(of: "\n") {
                        let line = String(buffer[buffer.startIndex ..< range.lowerBound])
                        continuation.yield(line)
                        buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
                    }
                }
                continuation.finish()
            }
        }
    }

    func close() { Darwin.close(fd) }
}
