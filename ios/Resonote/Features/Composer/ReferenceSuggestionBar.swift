import ResonoteKit
import SwiftUI

/// `\` reference suggestions: the Search tab's local index and ranking
/// (`CatalogSearchRank`: exact 100 · prefix 70 · contains 40, then name), up to eight.
enum ComposerReferenceSearch {
    static let limit = 8
}

/// The strip above the keyboard while a `\` reference is being typed: up to eight
/// matches, instant from this device and then completed by the server as one batch.
struct ReferenceSuggestionBar: View {
    let session: ComposerSession
    let query: String

    @Environment(AppModel.self) private var model
    @State private var results: [SearchResult] = []
    @State private var status: Status = .waiting
    @State private var insertions = 0

    private enum Status: Equatable {
        /// Nothing typed after `\` yet.
        case waiting
        case searching
        case done
        case failed
    }

    static let height: CGFloat = 60

    var body: some View {
        ZStack(alignment: .leading) {
            if results.isEmpty {
                Text(message)
                    .lineLimit(1)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .padding(.horizontal, RN.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: RN.Space.s) {
                        ForEach(results) { result in
                            suggestion(result)
                        }
                    }
                    .padding(.horizontal, RN.Space.m)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, RN.Space.s)
        .padding(.bottom, RN.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music to link")
        .sensoryFeedback(.selection, trigger: insertions)
        .task(id: query) { await search() }
    }

    private var message: String {
        switch status {
        case .waiting: "Keep typing to find music."
        case .searching: "Looking for “\(query)”"
        case .done: "Nothing matches “\(query)” yet."
        case .failed: "Search isn't reachable right now. Keep typing to try again."
        }
    }

    private func suggestion(_ result: SearchResult) -> some View {
        let entity = result.entity
        let artwork = model.catalog.artworkURL(for: entity) ?? entity.imageUrl
        let subtitle = result.subtitle.isEmpty ? entity.kind.label : result.subtitle
        return Button {
            model.absorb(entity)
            if session.insertReference(to: entity) { insertions += 1 }
        } label: {
            HStack(spacing: RN.Space.s) {
                ArtworkView(artwork, title: entity.name, size: 36, cornerRadius: entity.kind == .artist ? 18 : RN.Radius.artwork)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RN.Palette.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(RN.Palette.muted)
                }
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 46)
            .background(RN.Palette.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(RN.Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entity.name), \(entity.kind.label)")
        .accessibilityValue(result.subtitle)
        .accessibilityHint("Links it in your writing.")
    }

    /// Local matches (searched off the main actor) replace the strip at once when there
    /// are any; server matches the strip doesn't have follow after them, so a chip never
    /// moves under a finger. Stale queries are cancelled by `task(id:)`.
    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let folded = TrackText.fold(trimmed)
        guard !folded.isEmpty else {
            results = []
            status = .waiting
            return
        }
        let catalog = model.catalog
        let index = await LocalCatalogIndex.shared.current(for: catalog, revision: model.catalogRevision)
        let entities = await index.matches(folded, kind: nil, limit: ComposerReferenceSearch.limit)
        guard !Task.isCancelled else { return }
        let local = entities.map { SearchResult(entity: $0, subtitle: catalog.subtitle(for: $0), source: .local) }
        if !local.isEmpty { results = local }
        status = .searching

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            return
        }

        do {
            let remote = try await model.api.searchCatalog(trimmed, limit: ComposerReferenceSearch.limit)
            guard !Task.isCancelled else { return }
            results = local.isEmpty
                ? Array(remote.prefix(ComposerReferenceSearch.limit))
                : CatalogSearchRank.appending(remote, to: local, kind: nil, limit: ComposerReferenceSearch.limit)
            status = .done
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = local
            status = local.isEmpty ? .failed : .done
        }
    }
}
