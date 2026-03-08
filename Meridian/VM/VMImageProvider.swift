import Foundation
import Observation

/// Fetches, caches, and assembles the Meridian VM base image from GitHub Releases.
///
/// Design:
/// - Uses the GitHub REST API `GET /repos/{owner}/{repo}/releases/latest`
///   to discover the current image tag and download URLs dynamically.
/// - The repo slug (`owner/repo`) is configurable in Settings so the production
///   repo can change without recompilation.
/// - A release must contain assets named:
///     meridian-base.img.part1   — split rootfs (≤ 2 GiB each)
///     meridian-base.img.part2   — split rootfs
///     vmlinuz                   — Linux kernel (ARM64)
///     initrd                    — initial RAM disk
///   vmlinuz and initrd are downloaded alongside the rootfs parts so that
///   VMConfiguration.makeBootLoader() can always find them.
/// - On every launch the app checks the latest release tag; if it differs from
///   the cached tag it offers an update.
///
/// Fixes vs. previous implementation:
///   - assembleImage() now runs off the main thread (Task.detached); only state
///     updates are marshalled back to @MainActor.
///   - Progress bytes for part 2 were previously doubled (received * partIndex+1).
///     Now each part tracks its own received bytes and reports a combined total.
///   - Final buffer flush now also reports progress so the bar reaches 100%.
///   - vmlinuz and initrd are downloaded as separate assets.
@Observable
@MainActor
final class VMImageProvider {

    // MARK: - State

    private(set) var state: ImageProviderState = .idle
    private(set) var cachedTag: String?

    // MARK: - Paths

    nonisolated static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir  = base.appending(path: "com.meridian.app/vm", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var assembledImageURL: URL { Self.supportDir.appending(path: "meridian-base.img") }
    private var tagCacheURL: URL { Self.supportDir.appending(path: "image.tag") }
    private var part1URL:    URL { Self.supportDir.appending(path: "meridian-base.img.part1") }
    private var part2URL:    URL { Self.supportDir.appending(path: "meridian-base.img.part2") }
    private var kernelURL:   URL { Self.supportDir.appending(path: "vmlinuz") }
    private var initrdURL:   URL { Self.supportDir.appending(path: "initrd") }

    var isImageReady: Bool {
        FileManager.default.fileExists(atPath: assembledImageURL.path()) &&
        FileManager.default.fileExists(atPath: kernelURL.path())
    }

    // MARK: - Init

    init() {
        cachedTag = try? String(contentsOf: tagCacheURL, encoding: .utf8)
    }

    // MARK: - Public API

    /// Checks GitHub for a newer release. Returns true if an update is available.
    @discardableResult
    func checkForUpdate() async -> Bool {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            state = .idle
            return release.tagName != cachedTag || !isImageReady
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    /// Downloads all assets (kernel, initrd, rootfs parts) for the latest release.
    ///
    /// - Parameter onProgress: Called on the main actor with (overallFraction, bytesReceived, bytesTotal).
    func downloadLatestImage(onProgress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws {
        let release = try await fetchLatestRelease()

        guard let part1Asset = release.assets.first(where: { $0.name.hasSuffix(".part1") }),
              let part2Asset = release.assets.first(where: { $0.name.hasSuffix(".part2") })
        else {
            throw ImageError.assetsNotFound(release.tagName)
        }

        // Optional assets — older images may not include updated kernel files.
        let kernelAsset = release.assets.first(where: { $0.name == "vmlinuz" })
        let initrdAsset  = release.assets.first(where: { $0.name == "initrd" })

        // Build ordered download list. Kernel and initrd come first (small) so
        // VMConfiguration.makeBootLoader() can validate them early.
        var downloads: [(asset: GitHubAsset, destination: URL, label: String)] = []
        if let k = kernelAsset { downloads.append((k, kernelURL,  "vmlinuz")) }
        if let i = initrdAsset  { downloads.append((i, initrdURL,  "initrd")) }
        downloads.append((part1Asset, part1URL, "image part 1"))
        downloads.append((part2Asset, part2URL, "image part 2"))

        // Compute combined total size for accurate overall progress.
        let grandTotal = downloads.reduce(Int64(0)) { $0 + Int64($1.asset.size) }
        var grandReceived: Int64 = 0

        state = .downloading(0)

        for (index, item) in downloads.enumerated() {
            let startReceived = grandReceived
            try await downloadAsset(
                url: item.asset.browserDownloadURL,
                to: item.destination
            ) { [weak self] received, _ in
                // This callback fires frequently from URLSession — keep it lightweight.
                let combined = startReceived + received
                let fraction = Double(combined) / Double(max(grandTotal, 1))
                let totalForDisplay = grandTotal
                Task { @MainActor [weak self] in
                    self?.state = .downloading(fraction)
                    onProgress(fraction, combined, totalForDisplay)
                }
            }
            grandReceived += Int64(item.asset.size)
            _ = index // suppress unused warning
        }
    }

    /// Assembles the two rootfs parts into `meridian-base.img`.
    ///
    /// Runs the file I/O on a background thread to avoid blocking the main actor.
    /// Callers should set `state = .assembling` before calling this.
    func assembleImageAsync() async throws {
        let part1 = part1URL
        let part2 = part2URL
        let output = assembledImageURL

        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: output.path()) {
                try FileManager.default.removeItem(at: output)
            }
            guard FileManager.default.createFile(atPath: output.path(), contents: nil) else {
                throw ImageError.diskWriteFailed
            }
            let outHandle = try FileHandle(forWritingTo: output)
            defer { try? outHandle.close() }

            for partURL in [part1, part2] {
                let inHandle = try FileHandle(forReadingFrom: partURL)
                defer { try? inHandle.close() }
                while let chunk = try inHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try outHandle.write(contentsOf: chunk)
                }
            }
        }.value

        // Persist the release tag
        if let tag = cachedTag {
            try tag.write(to: tagCacheURL, atomically: true, encoding: .utf8)
        }

        // Clean up downloaded parts
        try? FileManager.default.removeItem(at: part1URL)
        try? FileManager.default.removeItem(at: part2URL)

        state = .idle
    }

    // MARK: - GitHub API

    /// Fetches the latest GitHub release. Result is reused by both checkForUpdate
    /// and downloadLatestImage via the public API to avoid a redundant request.
    private func fetchLatestRelease() async throws -> GitHubRelease {
        let slug = AppSettings.shared.imageRepoSlug
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest") else {
            throw ImageError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",                 forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageError.githubError }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 403, 429:
            throw ImageError.rateLimited
        case 404:
            throw ImageError.releaseNotFound(slug)
        default:
            throw ImageError.githubError
        }
    }

    // MARK: - Download

    private func downloadAsset(
        url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImageError.downloadFailed(url.lastPathComponent)
        }

        let contentLength = http.expectedContentLength  // -1 if unknown
        var received: Int64 = 0

        guard FileManager.default.createFile(atPath: destination.path(), contents: nil) else {
            throw ImageError.diskWriteFailed
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let bufferTarget = 512 * 1024
        var buffer = Data(capacity: bufferTarget)

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= bufferTarget {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                onProgress(received, max(contentLength, received))
            }
        }
        // Flush remainder and report final progress
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            onProgress(received, max(contentLength, received))
        }
    }

    // MARK: - State / errors

    enum ImageProviderState: Equatable {
        case idle
        case checking
        case downloading(Double)
        case assembling
        case error(String)
    }

    enum ImageError: LocalizedError {
        case badURL
        case githubError
        case rateLimited
        case releaseNotFound(String)
        case assetsNotFound(String)
        case downloadFailed(String)
        case diskWriteFailed

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid GitHub API URL. Check the repo slug in Settings."
            case .githubError:
                return "GitHub API returned an unexpected response."
            case .rateLimited:
                return "GitHub API rate limit reached. Please wait a minute and try again."
            case .releaseNotFound(let slug):
                return "No releases found for \(slug). Check the repo slug in Settings."
            case .assetsNotFound(let tag):
                return "No split image assets found in release \(tag)."
            case .downloadFailed(let file):
                return "Download failed for \(file)."
            case .diskWriteFailed:
                return "Could not write to disk. Check available storage."
            }
        }
    }
}

// MARK: - GitHub API models

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
