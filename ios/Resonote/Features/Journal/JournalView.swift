import ResonoteKit
import SwiftUI

/// Journal tab root: drafts and the artists you've written about, or an invitation
/// to sign in. The profile page, library and collections sit behind the profile menu.
struct JournalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSignedIn {
            JournalTabScreen()
        } else if model.isRestoringSession {
            // The session cached on this device is still being read: no welcome flash.
            RN.Palette.paper
                .ignoresSafeArea()
                .navigationTitle("Journal")
                .toolbarTitleDisplayMode(.inline)
        } else {
            JournalWelcome()
        }
    }
}

/// The signed-in Journal tab: `JournalHome`, a profile menu, and a compose button.
private struct JournalTabScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if let bundle = model.bundle {
                JournalHome(bundle: bundle)
                    .refreshable { await model.refreshSession() }
            } else {
                JournalWelcomeContent()
            }
        }
        .paperBackground()
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let handle = model.profile?.handle {
                        Button {
                            router.push(.profile(handle: handle))
                        } label: {
                            Label("Profile and library", systemImage: "person.crop.circle")
                        }
                    }
                    Button {
                        router.present(.editProfile)
                    } label: {
                        Label("Edit profile", systemImage: "pencil")
                    }
                    Button {
                        router.push(.settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("Profile", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                WriteToolbarButton(origin: "journal")
            }
        }
    }
}

/// The owner's profile with everything they can change: profile details,
/// collections, and settings. Shared by the Journal tab and `ProfileView` when the
/// handle is their own.
struct OwnJournalScreen: View {
    @Binding var section: ProfileSection

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if let bundle = model.bundle {
                ScrollView {
                    ProfileContent(
                        bundle: bundle,
                        isOwner: true,
                        section: $section,
                        onEditProfile: { router.present(.editProfile) },
                        onNewCollection: { router.present(.newCollection) }
                    )
                }
                .refreshable { await model.refreshSession() }
            } else {
                JournalWelcomeContent()
            }
        }
        .paperBackground()
        .navigationTitle("Profile")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.present(.editProfile)
                    } label: {
                        Label("Edit profile", systemImage: "pencil")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }
}

/// Signed out: the web onboarding's first screen, with Settings still in reach.
private struct JournalWelcome: View {
    @Environment(Router.self) private var router

    var body: some View {
        JournalWelcomeContent()
            .navigationTitle("Journal")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.push(.settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    WriteToolbarButton(origin: "journal")
                }
            }
    }
}

private struct JournalWelcomeContent: View {
    @Environment(AppModel.self) private var model
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RN.Space.m) {
                Text("Make a place for what you hear.")
                    .font(RN.Typography.display)
                    .foregroundStyle(RN.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(nowPlaying.canOfferSpotify
                     ? "Sign in with Spotify and your Journal is ready. No password."
                     : "Sign in with your email and a one-time code. No password.")
                    .font(.body)
                    .foregroundStyle(RN.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                // Spotify is the login: the server makes or finds the account from it.
                // Sign in with Apple waits for a paid developer account, so there is no Apple button.
                VStack(spacing: RN.Space.m) {
                    if nowPlaying.canOfferSpotify {
                        SpotifySignInButton(title: "Continue with Spotify", onGreen: true)
                            .buttonStyle(.spotifyPill)
                        Button("Use email instead") { model.requireAuth {} }
                            .font(.subheadline)
                            .foregroundStyle(RN.Palette.muted)
                            .frame(minHeight: 44)
                    } else {
                        Button("Continue with email") { model.requireAuth {} }
                            .buttonStyle(.solid)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, RN.Space.l)
                // Drafts kept before signing in stay reachable here.
                JournalDraftsSection()
                    .padding(.top, RN.Space.xl)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RN.Space.gutter)
            .padding(.top, RN.Space.xxl)
        }
        .paperBackground()
    }
}

// MARK: - Journal levels

// The Journal tab in three levels: the artists you've written about, one artist's
// notes, then the note itself (`EntryDetailView`). Every level uses the same row: 44 pt
// art, a title, one muted line, and a hairline inset to the text.

/// Shared measurements for Journal rows, so every level lines up on one edge.
enum JournalRow {
    static let artSize: CGFloat = 44
    /// Where separators start: past the artwork, under the text.
    static let textInset: CGFloat = artSize + RN.Space.m
}

/// One artist's share of the journal, newest note first.
struct JournalArtistGroup: Identifiable, Equatable {
    /// The artist's id, or `JournalArtistGroup.otherId` for notes about genres or
    /// music the catalog hasn't loaded yet.
    let id: String
    let entries: [JournalEntry]

    static let otherId = "_other"
}

/// Groups the owner's entries by artist, newest activity first.
enum JournalGrouping {
    struct Input: Equatable {
        var entries: [JournalEntry]
        /// The artist each entry resolves to, by entry id; missing while its music loads.
        var artistIds: [String: String]
    }

    static func groups(_ input: Input) -> [JournalArtistGroup] {
        var order: [String] = []
        var buckets: [String: [JournalEntry]] = [:]
        for entry in JournalOrder.newestFirst(input.entries) {
            let key = input.artistIds[entry.id] ?? JournalArtistGroup.otherId
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        // "Other" always comes last, so the list leads with music.
        order.sort { lhs, rhs in
            (lhs == JournalArtistGroup.otherId ? 1 : 0) < (rhs == JournalArtistGroup.otherId ? 1 : 0)
        }
        return order.map { JournalArtistGroup(id: $0, entries: buckets[$0] ?? []) }
    }

    static func artistIds(for entries: [JournalEntry], catalog: CatalogIndex) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            if let artistId = catalog.entity(kind: entry.entityKind, id: entry.entityId)?.artistId, !artistId.isEmpty {
                result[entry.id] = artistId
            }
        }
        return result
    }

    static func ownEntries(_ bundle: ProfileBundle) -> [JournalEntry] {
        bundle.entries.filter { $0.profileId == bundle.profile.id || $0.profileId.isEmpty }
    }
}

/// Journal's first level: drafts in progress, then one row per artist.
struct JournalHome: View {
    let bundle: ProfileBundle

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var memo = JournalMemo<JournalGrouping.Input, [JournalArtistGroup]>()
    @State private var unavailable: Set<String> = []

    var body: some View {
        let entries = JournalGrouping.ownEntries(bundle)
        let input = JournalGrouping.Input(entries: entries, artistIds: JournalGrouping.artistIds(for: entries, catalog: model.catalog))
        let groups = memo.value(for: input, JournalGrouping.groups)
        ScrollView {
            VStack(spacing: 0) {
                JournalDraftsSection()
                if groups.isEmpty {
                    Text("Notes you save show up here, grouped by artist.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, RN.Space.l)
                } else {
                    ForEach(groups) { group in
                        Button {
                            router.push(.journalArtist(id: group.id))
                        } label: {
                            JournalArtistRow(group: group)
                        }
                        .buttonStyle(.plain)
                        if group.id != groups.last?.id {
                            Divider()
                                .overlay(RN.Palette.line)
                                .padding(.leading, JournalRow.textInset)
                        }
                    }
                }
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.bottom, RN.Space.xxl)
        }
        .loadsMissingCatalog(entries.map { CatalogRef(kind: $0.entityKind, id: $0.entityId) }, unavailable: $unavailable)
    }
}

/// An artist with how many notes and when the newest was written.
private struct JournalArtistRow: View {
    let group: JournalArtistGroup

    @Environment(AppModel.self) private var model

    var body: some View {
        let artist = model.catalog.artists[group.id]
        let name = artist?.name ?? "Other notes"
        HStack(spacing: RN.Space.m) {
            ArtworkView(
                artist.flatMap { model.catalog.artworkURL(for: .artist($0)) },
                title: name,
                size: JournalRow.artSize,
                cornerRadius: artist == nil ? RN.Radius.artwork : JournalRow.artSize / 2
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: RN.Space.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RN.Palette.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, RN.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows these notes")
    }

    private var detail: String {
        let count = JournalCopy.count(group.entries.count, "note")
        guard let newest = group.entries.first, let date = ResonoteDate.parse(newest.updatedAt) else { return count }
        return "\(count) · \(JournalDate.short(date))"
    }
}

/// Journal's second level: one artist's notes, newest first.
struct JournalArtistView: View {
    let artistId: String

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let entries = model.bundle.map(JournalGrouping.ownEntries) ?? []
        let ids = JournalGrouping.artistIds(for: entries, catalog: model.catalog)
        let notes = JournalOrder.newestFirst(entries.filter { (ids[$0.id] ?? JournalArtistGroup.otherId) == artistId })
        ScrollView {
            VStack(spacing: 0) {
                if notes.isEmpty {
                    Text("No notes here anymore.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, RN.Space.l)
                }
                ForEach(notes) { entry in
                    Button {
                        router.push(.entry(id: entry.id))
                    } label: {
                        JournalNoteRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    if entry.id != notes.last?.id {
                        Divider()
                            .overlay(RN.Palette.line)
                            .padding(.leading, JournalRow.textInset)
                    }
                }
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.bottom, RN.Space.xxl)
        }
        .paperBackground()
        .navigationTitle(model.catalog.artists[artistId]?.name ?? "Other notes")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// A note: its title (or first words), a two-line preview, and what it's about and when.
private struct JournalNoteRow: View {
    let entry: JournalEntry

    @Environment(AppModel.self) private var model

    var body: some View {
        let entity = model.catalog.entity(kind: entry.entityKind, id: entry.entityId)
        let prose = PreparedProse.of(entry)
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        HStack(alignment: .top, spacing: RN.Space.m) {
            ArtworkView(entity.flatMap { model.catalog.artworkURL(for: $0) }, title: entity?.name ?? "", size: JournalRow.artSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? (entity?.name ?? "Untitled") : title)
                    .font(RN.Typography.serif(18, relativeTo: .headline))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(prose.preview)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(2)
                Text(meta(entity: entity))
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, RN.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the note")
    }

    private func meta(entity: CatalogEntity?) -> String {
        var parts: [String] = []
        if let entity { parts.append(entity.name) }
        if let date = ResonoteDate.parse(entry.updatedAt) { parts.append(JournalDate.short(date)) }
        parts.append(VisibilityCopy.marker(isPublic: entry.isPublic))
        return parts.joined(separator: " · ")
    }
}

enum JournalDate {
    /// "Today", "Yesterday", "Nov 12", or "Nov 12, 2025" outside this year.
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
