import SwiftUI
import UIKit

/// Loads and caches artwork. Memory hits are synchronous, so a cover that was on
/// screen once reappears without a placeholder flash; disk caching is URLCache's.
/// The memory cache keeps the largest copy decoded per URL, so a cover first seen
/// as a small row is decoded again (from disk) when it is shown larger. Rows asking
/// for the same cover at the same moment share one download and decode.
final class ImagePipeline: Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCacheBox()
    private let session: URLSession
    private let loads = InFlightLoads()

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 200 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    /// The cached copy of `url`, when it is sharp at `minPixel` pixels on its longest
    /// edge (or is the source's full size). Any cached size when `minPixel` is 0.
    func cached(_ url: URL, minPixel: CGFloat = 0) -> UIImage? {
        guard let entry = memory.entry(for: url) else { return nil }
        return entry.isFullSize || Self.pixels(entry.image) + 1 >= minPixel ? entry.image : nil
    }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(url, minPixel: maxPixel) { return hit }
        let session = session
        let memory = memory
        return await loads.value(for: url, maxPixel: maxPixel) {
            await Self.download(url, maxPixel: maxPixel, session: session, memory: memory)
        }
    }

    private static func download(_ url: URL, maxPixel: CGFloat, session: URLSession, memory: NSCacheBox) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = UIImage(data: data) else { return nil }
        let target = Self.fit(image.size, maxPixel: maxPixel)
        let isFullSize = target.width >= image.size.width && target.height >= image.size.height
        let prepared = await image.byPreparingThumbnail(ofSize: target) ?? image
        // Another view may have cached a larger copy meanwhile; keep the larger one.
        if let existing = memory.entry(for: url), existing.isFullSize || Self.pixels(existing.image) >= Self.pixels(prepared) {
            return existing.image
        }
        memory.set(CachedImage(image: prepared, isFullSize: isFullSize), for: url)
        return prepared
    }

    static func pixels(_ image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    private static func fit(_ size: CGSize, maxPixel: CGFloat) -> CGSize {
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// A decoded cover and whether it is the source's full size (nothing sharper exists).
private final class CachedImage: Sendable {
    let image: UIImage
    let isFullSize: Bool

    init(image: UIImage, isFullSize: Bool) {
        self.image = image
        self.isFullSize = isFullSize
    }
}

/// NSCache is thread-safe but not marked Sendable. Bounded by decoded size as well as
/// count: a header cover at 3x is about a megabyte.
private final class NSCacheBox: @unchecked Sendable {
    private let cache: NSCache<NSURL, CachedImage> = {
        let cache = NSCache<NSURL, CachedImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    func entry(for url: URL) -> CachedImage? { cache.object(forKey: url as NSURL) }

    func set(_ entry: CachedImage, for url: URL) {
        let size = entry.image.size
        let scale = entry.image.scale
        let cost = Int(size.width * scale * size.height * scale * 4)
        cache.setObject(entry, forKey: url as NSURL, cost: cost)
    }
}

/// Downloads in flight, so concurrent requests for one cover wait on the same work.
private actor InFlightLoads {
    private var tasks: [URL: (maxPixel: CGFloat, task: Task<UIImage?, Never>)] = [:]

    func value(for url: URL, maxPixel: CGFloat, load: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        if let running = tasks[url], running.maxPixel >= maxPixel {
            return await running.task.value
        }
        let task = Task { await load() }
        tasks[url] = (maxPixel, task)
        let image = await task.value
        if tasks[url]?.task == task { tasks[url] = nil }
        return image
    }
}

/// Square artwork with its size declared before anything loads, so rows never
/// shift when a cover arrives. Falls back to the entity's initials on a soft gradient.
struct ArtworkView: View {
    let url: URL?
    let fallbackTitle: String
    var size: CGFloat = 46
    var cornerRadius: CGFloat = RN.Radius.artwork

    @State private var image: UIImage?
    /// The URL `image` belongs to, so a reused view never shows the previous cover.
    @State private var imageURL: URL?
    @Environment(\.displayScale) private var displayScale

    init(_ urlString: String?, title: String, size: CGFloat = 46, cornerRadius: CGFloat = RN.Radius.artwork) {
        let url = urlString.flatMap(URL.init(string:))
        self.url = url
        self.fallbackTitle = title
        self.size = size
        self.cornerRadius = cornerRadius
        // Any cached size draws in the first frame; a sharper copy replaces it if needed.
        let hit = url.flatMap { ImagePipeline.shared.cached($0) }
        _image = State(initialValue: hit)
        _imageURL = State(initialValue: hit == nil ? nil : url)
    }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(RN.Palette.line))
        .accessibilityHidden(true)
        .task(id: url) { await load() }
    }

    private func load() async {
        let pipeline = ImagePipeline.shared
        if imageURL != url {
            // A different cover: what the cache has for it, or the initials until it arrives.
            let hit = url.flatMap { pipeline.cached($0) }
            image = hit
            imageURL = hit == nil ? nil : url
        }
        guard let url else { return }
        let target = size * displayScale
        if let image, pipeline.cached(url, minPixel: target) === image { return }
        guard let loaded = await pipeline.image(for: url, maxPixel: target), !Task.isCancelled, loaded !== image else { return }
        if image == nil {
            withAnimation(RN.Motion.quick) { image = loaded }
        } else {
            image = loaded
        }
        imageURL = url
    }

    private var placeholder: some View {
        ZStack {
            RadialGradient(colors: [RN.Palette.paper3, RN.Palette.paper2], center: .topLeading, startRadius: 0, endRadius: size * 1.2)
            Text(Self.initials(fallbackTitle))
                .font(.system(size: max(10, size * 0.3), weight: .semibold, design: .serif))
                .foregroundStyle(RN.Palette.muted)
        }
    }

    static func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// The vinyl motif from the web player: the cover becomes the center label of a
/// record that spins only while the source confirms playback.
struct VinylView: View {
    let artworkURL: String?
    let title: String
    let isPlaying: Bool
    var size: CGFloat = 132

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rotation accumulated across pauses, so stopping leaves the record where it was.
    @State private var restingAngle: Double = 0
    @State private var spinningSince: Date?

    private var spins: Bool { isPlaying && !reduceMotion }

    var body: some View {
        // Built once per render, outside the timeline: each frame only turns it.
        let disc = self.disc
        TimelineView(.animation(paused: !spins)) { context in
            disc.rotationEffect(.degrees(angle(at: context.date)))
        }
        .frame(width: size, height: size)
        .onChange(of: spins, initial: true) { _, spinning in
            let now = Date()
            if spinning {
                spinningSince = now
            } else {
                restingAngle = angle(at: now)
                spinningSince = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isPlaying ? "\(title), playing" : title)
    }

    private func angle(at date: Date) -> Double {
        guard let spinningSince else { return restingAngle }
        let turns = date.timeIntervalSince(spinningSince) / RN.Motion.spinPeriod
        return (restingAngle + turns * 360).truncatingRemainder(dividingBy: 360)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(RN.Palette.disc)
            ForEach(1..<6) { ring in
                Circle()
                    .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
                    .padding(size * 0.05 * CGFloat(ring))
            }
            ArtworkView(artworkURL, title: title, size: size * 0.42, cornerRadius: size * 0.21)
            Circle()
                .fill(RN.Palette.rust)
                .frame(width: size * 0.05, height: size * 0.05)
        }
    }
}
