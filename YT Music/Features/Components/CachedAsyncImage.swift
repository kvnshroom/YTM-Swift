//
//  CachedAsyncImage.swift
//  YT Music
//

import SwiftUI
import AppKit

/// Process-wide artwork cache so images already downloaded for a shelf/grid
/// card don't re-fetch and re-decode every time the card scrolls off/on-screen.
/// Also shared directly by views that need the `NSImage` itself (e.g. the
/// account avatar, which must be pre-scaled — see `AccountControl`).
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Drop-in `AsyncImage` replacement backed by `ImageCache`.
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    init<I: View, P: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == AnyView {
        self.url = url
        self.content = { phase in
            if case .success(let image) = phase {
                AnyView(content(image))
            } else {
                AnyView(placeholder())
            }
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
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
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            ImageCache.shared.insert(nsImage, for: url)
            phase = .success(Image(nsImage: nsImage))
        } catch {
            phase = .failure(error)
        }
    }
}
