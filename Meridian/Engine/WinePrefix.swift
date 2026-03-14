import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "WinePrefix")

/// Manages a Wine prefix (bottle) on disk.
///
/// A prefix is the isolated Windows environment that Wine uses. It contains:
///   - drive_c/        — the virtual C:\ drive
///   - system.reg      — HKEY_LOCAL_MACHINE registry
///   - user.reg        — HKEY_CURRENT_USER registry
///   - dosdevices/     — drive letter symlinks
///
/// Meridian uses a single shared prefix for Steam and all games:
///   ~/Library/Application Support/com.meridian.app/bottles/steam/
///
/// This is the correct approach because Steam manages game installations
/// within its own library folders. Per-game prefixes would each need their
/// own Steam install, wasting disk space.
struct WinePrefix: Sendable {

    let path: URL

    static let defaultPrefix: WinePrefix = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "com.meridian.app/bottles/steam", directoryHint: .isDirectory)
        return WinePrefix(path: dir)
    }()

    // MARK: - Computed Paths

    var driveC: URL {
        path.appending(path: "drive_c")
    }

    var steamInstallDir: URL {
        driveC.appending(path: "Program Files (x86)/Steam")
    }

    var steamExePath: URL {
        steamInstallDir.appending(path: "steam.exe")
    }

    var steamConfigDir: URL {
        steamInstallDir.appending(path: "config")
    }

    // MARK: - State Checks

    var exists: Bool {
        let regPath = path.appending(path: "system.reg").path(percentEncoded: false)
        let result = FileManager.default.fileExists(atPath: regPath)
        log.debug("[exists] system.reg at \(regPath) → \(result)")
        return result
    }

    var isSteamInstalled: Bool {
        let exePath = steamExePath.path(percentEncoded: false)
        let result = FileManager.default.fileExists(atPath: exePath)
        log.debug("[isSteamInstalled] \(exePath) → \(result)")
        return result
    }

    // MARK: - Prefix Lifecycle

    /// Initializes a new Wine prefix by running `wineboot`.
    func create(engine: WineEngine) async throws {
        let fm = FileManager.default
        log.info("[create] prefix path=\(path.path(percentEncoded: false))")

        do {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
            log.info("[create] directory created")
        } catch {
            log.error("[create] failed to create directory: \(error.localizedDescription)")
            throw error
        }

        let process = try await engine.run(args: ["wineboot", "--init"], prefix: self)

        guard process.terminationStatus == 0 else {
            log.error("[create] wineboot --init failed with exit \(process.terminationStatus)")
            throw PrefixError.createFailed(exitCode: process.terminationStatus)
        }

        log.info("[create] prefix created ✓ | system.reg exists=\(fm.fileExists(atPath: path.appending(path: "system.reg").path(percentEncoded: false)))")
    }

    /// Downloads SteamSetup.exe from Valve and installs it into the prefix.
    func installSteam(engine: WineEngine) async throws {
        let setupURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "SteamSetup.exe")

        log.info("[installSteam] downloading from \(setupURL.absoluteString)")

        let (data, response) = try await URLSession.shared.data(from: setupURL)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        log.info("[installSteam] HTTP \(statusCode) | size=\(data.count) bytes")

        guard statusCode == 200 else {
            log.error("[installSteam] download failed: HTTP \(statusCode)")
            throw PrefixError.steamDownloadFailed(statusCode: statusCode)
        }

        do {
            try data.write(to: tempFile)
            log.info("[installSteam] saved SteamSetup.exe to \(tempFile.path(percentEncoded: false))")
        } catch {
            log.error("[installSteam] failed to write SteamSetup.exe: \(error.localizedDescription)")
            throw error
        }

        log.info("[installSteam] running SteamSetup.exe /S in Wine")
        let process = try await engine.run(
            args: [tempFile.path(percentEncoded: false), "/S"],
            prefix: self
        )

        do {
            try FileManager.default.removeItem(at: tempFile)
        } catch {
            log.warning("[installSteam] failed to clean up SteamSetup.exe: \(error.localizedDescription)")
        }

        let steamExists = isSteamInstalled
        log.info("[installSteam] installer exit=\(process.terminationStatus) | steam.exe present=\(steamExists)")

        guard process.terminationStatus == 0 || steamExists else {
            log.error("[installSteam] FAILED: exit=\(process.terminationStatus) and steam.exe not found at \(steamExePath.path(percentEncoded: false))")
            throw PrefixError.steamInstallFailed(exitCode: process.terminationStatus)
        }

        log.info("[installSteam] Steam install complete ✓")
    }

    /// Copies Steam session files from the macOS Steam install into this prefix
    /// to enable auto-login without credentials.
    func copySessionFiles(from macSteamDir: URL) -> Bool {
        let fm = FileManager.default
        let files: [(src: String, dst: String)] = [
            ("config/loginusers.vdf", "config/loginusers.vdf"),
            ("config/config.vdf",     "config/config.vdf"),
            ("registry.vdf",          "registry.vdf"),
        ]

        let steamDir = steamInstallDir
        log.info("[copySession] from=\(macSteamDir.path(percentEncoded: false)) → \(steamDir.path(percentEncoded: false))")

        do {
            try fm.createDirectory(at: steamDir.appending(path: "config"), withIntermediateDirectories: true)
        } catch {
            log.error("[copySession] failed to create config dir: \(error.localizedDescription)")
            return false
        }

        var copiedCount = 0
        var failedCount = 0

        for (src, dst) in files {
            let source = macSteamDir.appending(path: src)
            let destination = steamDir.appending(path: dst)
            guard fm.fileExists(atPath: source.path(percentEncoded: false)) else {
                log.debug("[copySession] skip \(src) — not found")
                continue
            }

            do {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
                copiedCount += 1
                log.info("[copySession] copied \(src)")
            } catch {
                failedCount += 1
                log.error("[copySession] FAILED to copy \(src): \(error.localizedDescription)")
            }
        }

        // Copy ssfn machine auth tokens
        var ssfnCount = 0
        if let children = try? fm.contentsOfDirectory(at: macSteamDir, includingPropertiesForKeys: nil) {
            for token in children where token.lastPathComponent.hasPrefix("ssfn") {
                let destination = steamDir.appending(path: token.lastPathComponent)
                do {
                    try? fm.removeItem(at: destination)
                    try fm.copyItem(at: token, to: destination)
                    ssfnCount += 1
                    log.info("[copySession] copied \(token.lastPathComponent)")
                } catch {
                    failedCount += 1
                    log.error("[copySession] FAILED to copy \(token.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        log.info("[copySession] done: copied=\(copiedCount) ssfn=\(ssfnCount) failed=\(failedCount)")
        return copiedCount > 0 || ssfnCount > 0
    }

    /// Checks whether a specific Steam game is installed by looking for its
    /// appmanifest ACF file.
    func isGameInstalled(appID: Int) -> Bool {
        let manifest = steamInstallDir
            .appending(path: "steamapps/appmanifest_\(appID).acf")
        let result = FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false))
        log.debug("[isGameInstalled] appID=\(appID) manifest=\(manifest.path(percentEncoded: false)) → \(result)")
        return result
    }

    /// Reads the Steam appmanifest for a game and returns the `installdir` value.
    ///
    /// The installdir is the folder name under `steamapps/common/` where the
    /// game is installed (e.g. "Animal Well"). This is used as a `pgrep -f`
    /// pattern to detect whether the game process is running, since Wine on
    /// macOS exposes Windows-style paths in process listings.
    func gameInstallDir(appID: Int) -> String? {
        let manifest = steamInstallDir
            .appending(path: "steamapps/appmanifest_\(appID).acf")
        let manifestPath = manifest.path(percentEncoded: false)

        guard let contents = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            log.warning("[gameInstallDir] cannot read manifest at \(manifestPath)")
            return nil
        }

        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"installdir\"") else { continue }

            let parts = trimmed.components(separatedBy: "\t").filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let value = parts.last!
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            guard !value.isEmpty else { continue }
            log.info("[gameInstallDir] appID=\(appID) → \"\(value)\"")
            return value
        }

        log.warning("[gameInstallDir] 'installdir' not found in manifest for appID=\(appID)")
        return nil
    }

    /// Deletes the entire prefix directory. Use when the prefix is corrupted
    /// or Steam install is in a bad state. A fresh prefix will be created
    /// on the next launch.
    func reset() {
        let prefixPath = path.path(percentEncoded: false)
        log.info("[reset] removing prefix at \(prefixPath)")

        guard FileManager.default.fileExists(atPath: prefixPath) else {
            log.info("[reset] prefix does not exist — nothing to remove")
            return
        }

        do {
            try FileManager.default.removeItem(at: path)
            log.info("[reset] prefix removed")
        } catch {
            log.error("[reset] failed to remove prefix: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    enum PrefixError: LocalizedError {
        case createFailed(exitCode: Int32)
        case steamDownloadFailed(statusCode: Int)
        case steamInstallFailed(exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "Failed to create Wine prefix (wineboot exit \(code))."
            case .steamDownloadFailed(let code):
                return "Failed to download SteamSetup.exe (HTTP \(code))."
            case .steamInstallFailed(let code):
                return "Failed to install Steam (installer exit \(code))."
            }
        }
    }
}
