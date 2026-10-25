import ResonoteKit
import SwiftUI

/// The four parts of a profile, as on the web's profile tabs.
enum ProfileSection: String, CaseIterable, Identifiable {
    case journal, listens, library, collections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journal: "Journal"
        case .listens: "Listens"
        case .library: "Library"
        case .collections: "Collections"
        }
    }
}

/// What a profile page lists, derived once per data change rather than per render.
struct ProfileDigest {
    struct Input: Equatable {
        var bundle: ProfileBundle
        var isOwner: Bool
    }

    let entries: [JournalEntry]
    let listenDays: [ListenDay]
    let listenCount: Int
    let collections: [MusicCollection]
    let likedCount: Int
    /// Catalog rows the page may need to fetch.
    let refs: [CatalogRef]

    init(_ input: Input) {
        let bundle = input.bundle
        refs = AppModel.catalogRefs(for: bundle)
        let ownEntries = bundle.entries.filter { $0.profileId == bundle.profile.id || $0.profileId.isEmpty }
        entries = JournalOrder.newestFirst(input.isOwner ? ownEntries : ownEntries.filter(\.isPublic))
        listenDays = input.isOwner ? JournalOrder.listenDays(bundle.listens) : []
        listenCount = input.isOwner ? bundle.listens.count : 0
        let visible = input.isOwner ? bundle.collections : bundle.collections.filter(\.isPublic)
        collections = Self.oldestFirst(visible)
        likedCount = Set(bundle.likes.filter { $0.entityKind != .genre }.map(\.entityId)).count
    }

    /// Collections in the order they were made, as the server lists them; ties keep bundle order.
    private static func oldestFirst(_ collections: [MusicCollection]) -> [MusicCollection] {
        let dated: [(collection: MusicCollection, date: Date, offset: Int)] = collections.enumerated().map { offset, collection in
            (collection, ResonoteDate.parse(collection.createdAt) ?? .distantPast, offset)
        }
        let sorted = dated.sorted { left, right in
            left.date != right.date ? left.date < right.date : left.offset < right.offset
        }
        return sorted.map(\.collection)
    }
}

/// The shared profile layout used by the Journal tab and by public profiles:
/// header, pins, the section picker, and the chosen section. Read-only unless
/// `isOwner`.
struct ProfileContent: View {
    let bundle: ProfileBundle
    let isOwner: Bool
    @Binding var section: ProfileSection
    var onEditProfile: (() -> Void)?
    var onNewCollection: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var digestMemo = JournalMemo<ProfileDigest.Input, ProfileDigest>()
    @State private var unavailable: Set<String> = []

    private var profile: Profile { bundle.profile }

    var body: some View {
        let digest = digestMemo.value(for: ProfileDigest.Input(bundle: bundle, isOwner: isOwner), ProfileDigest.init)
        LazyVStack(alignment: .leading, spacing: RN.Space.xl) {
            ProfileHeader(profile: profile, unavailable: unavailable)
            if isOwner, let onEditProfile, showsOnboarding {
                OnboardingCard(action: onEditProfile)
            }
            ProfilePinsView(bundle: bundle, isOwner: isOwner, unavailable: unavailable)
            ProfileSectionPicker(selection: $section, counts: counts(digest), isOwner: isOwner)
                .padding(.top, RN.Space.s)
            switch section {
            case .journal: journal(digest.entries)
            case .listens: listens(digest)
            case .library: library
            case .collections: collections(digest.collections)
            }
        }
        .padding(.horizontal, RN.Space.gutter)
        .padding(.top, RN.Space.s)
        .padding(.bottom, RN.Space.xxl)
        .loadsMissingCatalog(digest.refs, unavailable: $unavailable)
    }

    private var showsOnboarding: Bool {
        profile.genreIds.isEmpty && bundle.entries.isEmpty && bundle.likes.isEmpty
    }

    private func counts(_ digest: ProfileDigest) -> [ProfileSection: Int] {
        var counts: [ProfileSection: Int] = [
            .journal: digest.entries.count,
            .library: digest.likedCount,
            .collections: digest.collections.count,
        ]
        if isOwner { counts[.listens] = digest.listenCount }
        return counts
    }

    // MARK: Journal

    @ViewBuilder
    private func journal(_ entries: [JournalEntry]) -> some View {
        SectionHeader(eyebrow: isOwner ? "Your writing" : "Public writing", title: "Journal")
        if entries.isEmpty {
            EmptyStateView(
                title: "Nothing published yet",
                message: "Thoughts will appear here without being reduced to scores."
            )
        } else {
            ForEach(entries) { entry in
                let entity = model.catalog.entity(kind: entry.entityKind, id: entry.entityId)
                EntryCard(
                    entry: entry,
                    author: profile,
                    entity: entity,
                    artworkURL: entity.flatMap { model.catalog.artworkURL(for: $0) },
                    onOpen: { router.push(.entry(id: entry.id)) }
                )
            }
        }
    }

    // MARK: Listens

    @ViewBuilder
    private func listens(_ digest: ProfileDigest) -> some View {
        SectionHeader(eyebrow: "Private listening log", title: "Recent listens")
        if !isOwner {
            EmptyStateView(
                title: "Listening history is private",
                message: "Journal entries and liked music remain available on this profile."
            )
        } else if digest.listenDays.isEmpty {
            EmptyStateView(
                title: "No listens logged yet",
                message: "Use “Log listen” on a song page to keep the event without having to turn it into a review."
            )
        } else {
            ForEach(digest.listenDays) { day in
                Text(day.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
                    .padding(.top, RN.Space.s)
                    .accessibilityAddTraits(.isHeader)
                ForEach(day.listens) { listen in
                    ListenRow(listen: listen, isUnavailable: unavailable.contains(listen.songId))
                }
            }
        }
    }

    // MARK: Library

    @ViewBuilder
    private var library: some View {
        SectionHeader(eyebrow: "Affirmative taste", title: "Liked music")
        ProfileLibraryView(bundle: bundle, isOwner: isOwner, unavailable: unavailable)
    }

    // MARK: Collections

    @ViewBuilder
    private func collections(_ collections: [MusicCollection]) -> some View {
        HStack(alignment: .bottom, spacing: RN.Space.m) {
            SectionHeader(eyebrow: "Personal constellations", title: "Collections")
            if isOwner, let onNewCollection {
                Button(action: onNewCollection) {
                    Label("New collection", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 20)
                }
                .buttonStyle(.outline)
                .accessibilityLabel("New collection")
            }
        }
        if collections.isEmpty {
            EmptyStateView(
                title: "No collections yet",
                message: "This is where spiritual similarity gets a name.",
                actionTitle: isOwner && onNewCollection != nil ? "New collection" : nil,
                action: onNewCollection
            )
        } else {
            ForEach(collections) { collection in
                CollectionCard(collection: collection, showsPrivacy: isOwner) {
                    router.push(.collection(handle: profile.handle, id: collection.id))
                }
            }
        }
    }
}

/// Journal / Listens / Library / Collections with counts. Every segment has the
/// same width, and counts use monospaced digits, so nothing moves when a number
/// changes or the selection moves.
struct ProfileSectionPicker: View {
    @Binding var selection: ProfileSection
    let counts: [ProfileSection: Int]
    let isOwner: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var highlight

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: typeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(ProfileSection.allCases) { section in
                segment(section)
            }
        }
        .padding(4)
        .background(RN.Palette.fill, in: RoundedRectangle(cornerRadius: RN.Radius.button + 4))
        .overlay(RoundedRectangle(cornerRadius: RN.Radius.button + 4).strokeBorder(RN.Palette.line))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile sections")
    }

    private func segment(_ section: ProfileSection) -> some View {
        let isSelected = selection == section
        return Button {
            guard selection != section else { return }
            withAnimation(reduceMotion ? nil : RN.Motion.quick) { selection = section }
        } label: {
            VStack(spacing: 1) {
                Text(section.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                countLabel(section)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? RN.Palette.ink : RN.Palette.muted)
            }
            .foregroundStyle(isSelected ? RN.Palette.ink : RN.Palette.prose)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 2)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: RN.Radius.button)
                        .fill(RN.Palette.paper3)
                        .overlay(RoundedRectangle(cornerRadius: RN.Radius.button).strokeBorder(RN.Palette.lineStrong))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: RN.Radius.button))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(section))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func countLabel(_ section: ProfileSection) -> some View {
        if let count = counts[section] {
            Text(count, format: .number)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
        } else {
            Image(systemName: "lock")
                .imageScale(.small)
        }
    }

    private func accessibilityLabel(_ section: ProfileSection) -> String {
        guard let count = counts[section] else { return "\(section.title), private" }
        return "\(section.title), \(count)"
    }
}

/// The web onboarding's first step, offered while a new journal is still empty.
private struct OnboardingCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Eyebrow("First, tune the starting shelf")
            Text("What do you find yourself listening to?")
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.ink)
            Text("Pick a few genres for your profile. It does not lock you into a genre profile.")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
            Button("Choose genres", action: action)
                .buttonStyle(.outline)
                .padding(.top, RN.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RN.Space.l)
        .cardSurface()
    }
}

/// One logged listen: the song, its moods and note, and a way to write about it.
private struct ListenRow: View {
    let listen: ListenLog
    let isUnavailable: Bool

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let song = model.catalog.songs[listen.songId]
        HStack(alignment: .top, spacing: RN.Space.m) {
            if let song {
                Button {
                    router.push(.entity(kind: .song, id: song.id))
                } label: {
                    content(song)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the song")
            } else {
                CatalogRowPlaceholder(isUnavailable: isUnavailable)
            }
            Button {
                router.present(.compose(ComposerContext(entityKind: .song, entityId: listen.songId)))
            } label: {
                Label("Write", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.outline)
            .accessibilityLabel(song.map { "Write about \($0.name)" } ?? "Write about this song")
        }
        .padding(.vertical, RN.Space.xs)
    }

    private func content(_ song: Song) -> some View {
        let entity = CatalogEntity.song(song)
        return HStack(alignment: .top, spacing: RN.Space.m) {
            ArtworkView(model.catalog.artworkURL(for: entity), title: song.name, size: 46)
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(2)
                    Text(model.catalog.subtitle(for: entity))
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                if !listen.moods.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(listen.moods, id: \.self) { JournalTag(text: $0) }
                    }
                }
                if let note = listen.note, !note.isEmpty {
                    Text(note)
                        .font(RN.Typography.serif(16, relativeTo: .callout))
                        .foregroundStyle(RN.Palette.prose)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
