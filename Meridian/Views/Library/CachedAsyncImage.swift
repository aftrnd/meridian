import SwiftUI
import AppKit

/// An AsyncImage replacement that caches images in memory via NSCache.
/// Prevents images from re-fetching when SwiftUI rebuilds views
/// (e.g., switching tabs, scrolling offscreen).
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    private func loadImage() async {
        guard let url else {
            phase = .empty
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(nsImage: cached))
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let nsImage = NSImage(data: data) else {
                phase = .failure(ImageError.invalidData)
                return
            }
            ImageCache.shared.store(nsImage, for: url)
            phase = .success(Image(nsImage: nsImage))
        } catch {
            phase = .failure(error)
        }
    }

    private enum ImageError: Error {
        case invalidData
    }
}

/// Thread-safe in-memory image cache backed by NSCache.
private final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
