import ResonoteKit
import SwiftUI

/// One journal entry in full: what it is about, who wrote it and when, the writing,
/// its lenses and reflections, and the music it links. Owners can edit, change who
/// can read it, or delete it; anyone can pin it.
struct EntryDetailView: View {
    let entryId: String

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// The last version shown, so a refresh or a delete never blanks the page mid-read.
    @State private var retained: JournalEntry?
    @State private var isDeleting = false
    @State private var isConfirmingDelete = false
    @State private var hasEditDraft = false
    @State private var choosesReportReason = false
    @State private var confirmsBlock = false

    private var entry: JournalEntry? {
        if isDeleting { return retained }
        return model.anyEntry(id: entryId) ?? retained
    }

    var body: some View {
        Group {
            if let entry, let author = model.author(of: entry), model.isBlocked(author.id) {
                ScrollView {
                    BlockedNotice(profile: author)
                        .padding(.horizontal, RN.Space.gutter)
                        .padding(.top, RN.Space.l)
                }
            } else if let entry {
                EntryDetailContent(entry: entry, hasEditDraft: hasEditDraft && isOwner(entry)) {
                    edit(entry)
                }
            } else {
                ScrollView {
                    EmptyStateView(title: "This entry isn't available", message: "It may have been removed or made private.")
                        .padding(.horizontal, RN.Space.gutter)
                        .padding(.top, RN.Space.l)
                }
            }
        }
        .paperBackground()
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let entry, isOwner(entry), !isDeleting {
                ToolbarItem(placement: .topBarTrailing) { ownerMenu(entry) }
            } else if let entry, model.isSignedIn, !isOwner(entry), !entry.profileId.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { readerMenu(entry) }
            }
        }
        .reportReasonDialog(isPresented: $choosesReportReason) { reason in
            if let entry { model.report(.entry, id: entry.id, reason: reason) }
        }
        .blockConfirmation(isPresented: $confirmsBlock, profile: entry.flatMap { model.author(of: $0) })
        .confirmationDialog("Delete this entry?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(hasEditDraft
                 ? "It will be removed from your journal, along with unpublished edits on this device."
                 : "It will be removed from your journal.")
        }
        .onChange(of: model.anyEntry(id: entryId), initial: true) { _, fresh in
            if let fresh, !isDeleting { retained = fresh }
        }
        .task(id: router.sheet == nil) { refreshDraftState() }
    }

    private func isOwner(_ entry: JournalEntry) -> Bool {
        guard let profileId = model.profile?.id else { return false }
        return entry.profileId == profileId
    }

    private func ownerMenu(_ entry: JournalEntry) -> some View {
        Menu {
            Button {
                edit(entry)
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }
            Button {
                toggleVisibility(entry)
            } label: {
                if entry.isPublic {
                    Label("Make private", systemImage: "lock")
                } else {
                    Label("Make public", systemImage: "globe")
                }
            }
            Divider()
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Label("Entry options", systemImage: "ellipsis")
        }
    }

    /// Someone else's entry: report it, or block its writer.
    private func readerMenu(_ entry: JournalEntry) -> some View {
        Menu {
            Button {
                choosesReportReason = true
            } label: {
                Label("Report entry", systemImage: "flag")
            }
            if let author = model.author(of: entry) {
                Button(role: .destructive) {
                    confirmsBlock = true
                } label: {
                    Label("Block @\(author.handle)", systemImage: "hand.raised")
                }
            }
        } label: {
            Label("Entry options", systemImage: "ellipsis")
        }
    }

    // MARK: Actions

    private func edit(_ entry: JournalEntry) {
        router.present(.compose(ComposerContext(entityKind: entry.entityKind, entityId: entry.entityId, entryId: entry.id)))
    }

    /// Visibility is not an edit to the writing, so `updatedAt` (and feed order) stays put.
    /// An unpublished edit of this entry follows the new choice, so publishing it later
    /// never undoes "Make private".
    private func toggleVisibility(_ entry: JournalEntry) {
        var updated = entry
        updated.isPublic.toggle()
        model.save(updated)
        let key = Draft.key(kind: entry.entityKind, entityId: entry.entityId, entryId: entry.id)
        let drafts = model.drafts
        if var draft = drafts.load(key: key), draft.isPublic != updated.isPublic {
            draft.isPublic = updated.isPublic
            draft.updatedAt = Date()
            drafts.save(draft)
        }
    }

    private func delete() {
        guard let entry else { return }
        retained = entry
        isDeleting = true
        model.drafts.delete(key: Draft.key(kind: entry.entityKind, entityId: entry.entityId, entryId: entry.id))
        model.deleteEntry(id: entry.id)
        dismiss()
    }

    private func refreshDraftState() {
        guard let entry, isOwner(entry) else {
            hasEditDraft = false
            return
        }
        let key = Draft.key(kind: entry.entityKind, entityId: entry.entityId, entryId: entry.id)
        hasEditDraft = model.drafts.load(key: key) != nil
    }
}

/// The entry's page content. Separate from the screen so toolbar and dialog state
/// changes don't re-render the writing.
private struct EntryDetailContent: View {
    let entry: JournalEntry
    let hasEditDraft: Bool
    let onContinueEditing: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RN.Space.xl) {
                EntrySubjectHeader(kind: entry.entityKind, id: entry.entityId)
                byline
                if hasEditDraft { draftNotice }
                VStack(alignment: .leading, spacing: RN.Space.m) {
                    if let title = entry.title, !title.isEmpty {
                        Text(title)
                            .font(RN.Typography.title)
                            .foregroundStyle(RN.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    RichDocumentView(blocks: PreparedProse.of(entry).blocks)
                }
                if !entry.lenses.isEmpty { lenses }
                if hasReflections { reflections }
                if !entry.references.isEmpty { EntryLinkedMusic(references: entry.references) }
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.top, RN.Space.s)
            .padding(.bottom, RN.Space.xxl)
        }
    }

    // MARK: Byline

    private var byline: some View {
        HStack(alignment: .center, spacing: RN.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                if let author = model.author(of: entry) {
                    Button {
                        router.push(.profile(handle: author.handle))
                    } label: {
                        HStack(spacing: 6) {
                            Text(author.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RN.Palette.ink)
                            Text("@\(author.handle)")
                                .font(.subheadline)
                                .foregroundStyle(RN.Palette.muted)
                        }
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(author.displayName), @\(author.handle)")
                    .accessibilityHint("Opens their profile")
                }
                HStack(spacing: 6) {
                    if let date = ResonoteDate.parse(entry.updatedAt) {
                        Text(date, format: .dateTime.month(.wide).day().year())
                    }
                    if !entry.isPublic {
                        Text("·").accessibilityHidden(true)
                        Label("Only you", systemImage: "lock")
                            .labelStyle(.titleAndIcon)
                            .imageScale(.small)
                    }
                }
                .font(.footnote)
                .foregroundStyle(RN.Palette.muted)
            }
            Spacer(minLength: 0)
            EntryPinButton(entryId: entry.id)
        }
    }

    private var draftNotice: some View {
        HStack(spacing: RN.Space.s) {
            Image(systemName: "tray.and.arrow.down")
                .accessibilityHidden(true)
            Text("You have unpublished edits on this device.")
            Spacer(minLength: 0)
            Button("Continue editing", action: onContinueEditing)
                .foregroundStyle(RN.Palette.rustText)
        }
        .font(.footnote)
        .foregroundStyle(RN.Palette.muted)
        .padding(RN.Space.m)
        .cardSurface()
    }

    // MARK: Lenses and reflections

    private var hasReflections: Bool {
        !(entry.worked ?? "").isEmpty || !(entry.didntWork ?? "").isEmpty
    }

    private var lenses: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(entry.lenses, id: \.self) { lens in
                Text(lens.rawValue)
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(RN.Palette.line))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lenses: \(entry.lenses.map(\.rawValue).joined(separator: ", "))")
    }

    private var reflections: some View {
        VStack(spacing: RN.Space.s) {
            if let worked = entry.worked, !worked.isEmpty {
                EntryReflection(title: "What worked for me", text: worked)
            }
            if let didntWork = entry.didntWork, !didntWork.isEmpty {
                EntryReflection(title: "What didn’t work for me", text: didntWork)
            }
        }
    }
}

/// What the entry is about: artwork, name, and subtitle, opening the music's page.
/// The row's geometry is fixed before the catalog row arrives.
private struct EntrySubjectHeader: View {
    let kind: EntityKind
    let id: String

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var loadFailed = false

    var body: some View {
        let entity = model.catalog.entity(kind: kind, id: id)
        let name = entity?.name ?? (loadFailed ? "This \(kind.rawValue)" : nil)
        let subtitle = entity.map { model.catalog.subtitle(for: $0) } ?? (loadFailed ? "Details couldn't load." : "")
        let artwork = entity.flatMap { model.catalog.artworkURL(for: $0) }
        Button {
            router.push(.entity(kind: kind, id: id))
        } label: {
            HStack(spacing: RN.Space.m) {
                ArtworkView(artwork, title: name ?? "", size: 56, cornerRadius: kind == .artist ? 28 : RN.Radius.artwork)
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(kind.label)
                    Group {
                        if let name {
                            Text(name)
                        } else {
                            Text("Loading the music")
                                .redacted(reason: .placeholder)
                        }
                    }
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(2)
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(RN.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(RoundedRectangle(cornerRadius: RN.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { "\($0), \(kind.label)" } ?? kind.label)
        .accessibilityValue(subtitle)
        .accessibilityHint("Opens the music page")
        .accessibilityAddTraits(.isButton)
        .task(id: "\(kind.rawValue)/\(id)") { await load() }
    }

    /// Fetches the subject when this device hasn't seen it. On failure the row says so
    /// and still opens the music page, which retries on its own.
    private func load() async {
        guard model.catalog.entity(kind: kind, id: id) == nil else { return }
        do {
            let detail = try await model.api.entity(kind: kind, id: id)
            model.absorb(detail)
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            loadFailed = true
        }
    }
}

/// Pin / Pinned, the same width either way.
private struct EntryPinButton: View {
    let entryId: String
    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        let pinned = model.isPinned(.entry, entryId)
        Button {
            taps += 1
            model.togglePin(.entry, entryId)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .imageScale(.small)
                StableLabel(pinned ? "Pinned" : "Pin", among: ["Pin", "Pinned"])
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(pinned ? RN.Palette.rustText : RN.Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(RN.Palette.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(RN.Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pinned ? "Pinned to your profile" : "Pin to your profile")
        .accessibilityAddTraits(pinned ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: taps)
    }
}

/// A collapsible reflection, closed by default like the web's accordion.
private struct EntryReflection: View {
    let title: String
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isExpanded },
            set: { open in withAnimation(reduceMotion ? nil : RN.Motion.settle) { isExpanded = open } }
        )) {
            Text(text)
                .font(.body)
                .foregroundStyle(RN.Palette.prose)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, RN.Space.s)
                .textSelection(.enabled)
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(RN.Palette.ink)
        }
        .padding(RN.Space.l)
        .cardSurface()
    }
}

/// The music this entry links, with how each relates and what connects them.
private struct EntryLinkedMusic: View {
    let references: [MusicReference]

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            Eyebrow("Linked music")
            VStack(spacing: 0) {
                ForEach(Array(references.enumerated()), id: \.element.id) { offset, reference in
                    if offset > 0 { Divider().overlay(RN.Palette.line) }
                    row(reference)
                }
            }
            .cardSurface()
        }
    }

    private func row(_ reference: MusicReference) -> some View {
        let entity = model.catalog.entity(kind: reference.entityKind, id: reference.entityId)
        let name = entity?.name ?? reference.label
        let artwork = entity.flatMap { model.catalog.artworkURL(for: $0) }
        let summary = ComposerLinkedMusic.summary(reference)
        return Button {
            router.push(.entity(kind: reference.entityKind, id: reference.entityId))
        } label: {
            HStack(spacing: RN.Space.m) {
                ArtworkView(artwork, title: name, size: 40, cornerRadius: reference.entityKind == .artist ? 20 : RN.Radius.artwork)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(1)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RN.Space.m)
            .padding(.vertical, RN.Space.s)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(reference.entityKind.label)")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the music page")
        .accessibilityAddTraits(.isButton)
    }
}
