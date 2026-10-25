import Foundation
import ImageIO
import ResonoteKit
import UniformTypeIdentifiers

/// Fetches cover art for the widget as a small JPEG. The extension runs under a
/// tight memory limit, so images are decoded straight to a thumbnail and the last
/// one is kept in the App Group so an unchanged song never downloads twice.
nonisolated enum WidgetArtwork {
    /// Largest edge, in pixels: the medium widget's cover is about 140 pt, at 3x. One JPEG
    /// this size (tens of kilobytes) is cached, well within the extension's memory budget.
    static let maxPixel = 420

    private struct Cached: Codable {
        var url: String
        var data: Data
    }

    private static let fileName = "widget-artwork.json"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    /// The cover for `urlString` if it was fetched before.
    static func cached(for urlString: String?) -> Data? {
        guard let urlString,
              let cached = SharedFile.read(Cached.self, from: fileName),
              cached.url == urlString else { return nil }
        return cached.data
    }

    /// The cover for `urlString`, from the cache or the network (about two seconds at most).
    static func data(for urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        if let hit = cached(for: urlString) { return hit }
        guard let (data, response) = try? await session.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let thumbnail = thumbnail(from: data) else { return nil }
        SharedFile.write(Cached(url: urlString, data: thumbnail), to: fileName)
        return thumbnail
    }

    private static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
