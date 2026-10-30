import ResonoteKit
import SwiftUI

/// The published feed (`Route.feed`): recent writing others chose to publish, paged by
/// cursor. Pages arrive as complete batches, a refresh never blanks what is shown,
/// and the first page is kept on disk so the tab opens with words, not skeleton cards.
@Observable
final class NowFeed {
    enum Status: Equatable {
        /// Nothing requested yet.
        case idle
        case loading
        case loaded
        /// The first page failed and there is nothing to show.
        case failed
    }

    private(set) var entries: [JournalEntry] = []
    private(set) var status: Status = .idle
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    /// Writing that arrived with an automatic refresh, waiting for the person to ask for
    /// it, so new cards never push down the ones being read.
    private(set) var newCount = 0

    @ObservationIgnored private var waitingPage: FeedResponse?

    @ObservationIgnored private var loadedAt: Date?
    /// Bumped by every first-page load, so a page requested before it is discarded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restored = false

    private static let pageSize = 20
    private static let freshFor: TimeInterval = 120

    /// Shows the cached first page if nothing is on screen, then refreshes unless the
    /// feed is fresh. Once someone has paged deeper, only pull to refresh replaces the
    /// list, so returning to the tab never pulls the writing they were reading away.
    func appear(model: AppModel) async {
        await restoreIfNeeded(model: model)
        if status == .loaded, let loadedAt {
            if Date().timeIntervalSince(loadedAt) < Self.freshFor || entries.count > Self.pageSize { return }
        }
        await reload(model: model, askedFor: false)
    }

    /// Loads the first page. Asked for (pull to refresh, Retry) or with nothing on screen,
    /// it replaces the list in one batch. Otherwise the cards stay where they are: edits
    /// update in place, and new writing waits behind `newCount` until `showNew()`.
    /// The old list is kept on failure.
    func reload(model: AppModel, askedFor: Bool = true) async {
        generation += 1
        let current = generation
        if entries.isEmpty { status = .loading }
        do {
            let page = try await model.api.feed(limit: Self.pageSize)
            guard current == generation else { return }
            model.absorb(page.catalog)
            model.remember(entries: page.entries, profiles: page.profiles)
            let known = Set(entries.map(\.id))
            let arrivals = page.entries.filter { !known.contains($0.id) }
            if askedFor || entries.isEmpty || status != .loaded {
                replace(with: page)
            } else if arrivals.isEmpty {
                // The same writing: take edits where each card already is.
                let fresh = Dictionary(page.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let updated = entries.map { fresh[$0.id] ?? $0 }
                if updated != entries { entries = updated }
            } else {
                waitingPage = page
                if newCount != arrivals.count { newCount = arrivals.count }
            }
            loadMoreFailed = false
            status = .loaded
            loadedAt = Date()
            let cache = NowFeedCache(entries: page.entries, profiles: page.profiles, nextCursor: page.nextCursor)
            Task { await NowFeedCache.write(cache) }
        } catch is CancellationError {
            guard current == generation, status == .loading else { return }
            status = entries.isEmpty ? .idle : .loaded
        } catch {
            guard current == generation else { return }
            status = entries.isEmpty ? .failed : .loaded
        }
    }

    /// Shows the writing that arrived with an automatic refresh, newest first.
    func showNew() {
        guard let waitingPage else { return }
        replace(with: waitingPage)
    }

    private func replace(with page: FeedResponse) {
        if page.entries != entries { entries = page.entries }
        nextCursor = page.nextCursor
        waitingPage = nil
        if newCount != 0 { newCount = 0 }
    }

    /// Appends the next page, once, when the last card comes into view.
    func loadMore(model: AppModel) async {
        guard let cursor = nextCursor, !isLoadingMore, status == .loaded else { return }
        let current = generation
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }
        do {
            let page = try await model.api.feed(limit: Self.pageSize, before: cursor)
            guard current == generation else { return }
            model.absorb(page.catalog)
            model.remember(entries: page.entries, profiles: page.profiles)
            let known = Set(entries.map(\.id))
            let fresh = page.entries.filter { !known.contains($0.id) }
            if !fresh.isEmpty { entries.append(contentsOf: fresh) }
            // A cursor that yields nothing new would page forever; stop instead.
            nextCursor = fresh.isEmpty && page.nextCursor == cursor ? nil : page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            loadMoreFailed = true
        }
    }

    private func restoreIfNeeded(model: AppModel) async {
        guard !restored else { return }
        restored = true
        guard entries.isEmpty, let cache = await NowFeedCache.read(), !cache.entries.isEmpty, entries.isEmpty else { return }
        model.remember(entries: cache.entries, profiles: cache.profiles)
        entries = cache.entries
        nextCursor = cache.nextCursor
        if status != .loaded { status = .loaded }
    }
}

/// The feed's first page as last seen, in the shared container. Public writing only.
nonisolated struct NowFeedCache: Codable, Sendable {
    static let fileName = "now-feed.json"

    var entries: [JournalEntry]
    var profiles: [Profile]
    var nextCursor: String?

    @concurrent
    static func read() async -> NowFeedCache? {
        SharedFile.read(NowFeedCache.self, from: fileName)
    }

    @concurrent
    static func write(_ cache: NowFeedCache) async {
        SharedFile.write(cache, to: fileName)
    }
}
