import ResonoteKit
import SwiftUI

/// The share sheet: the shared song, a prompt, a note, and a few tags.
struct ShareCaptureView: View {
    @Bindable var model: ShareModel
    /// Locks swipe-to-dismiss while there is unsaved writing.
    var onUnsavedWorkChange: (Bool) -> Void = { _ in }

    @State private var confirmingCancel = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RN.Space.xl) {
                    switch model.phase {
                    case .signedOut:
                        Notice(title: "Open Resonote and sign in first.", message: "Then share songs here to write about them.")
                    case .noLink:
                        Notice(title: "There’s no song link here.", message: "Share a song from Spotify, Apple Music, or YouTube Music.")
                    case .loading, .unreachable, .unmatched, .ready:
                        songForm
                    }
                }
                .padding(.horizontal, RN.Space.gutter)
                .padding(.vertical, RN.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RN.Palette.paper3.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("Resonote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsForm {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                            .disabled(model.isSaving || model.didSave)
                    }
                }
            }
        }
        .foregroundStyle(RN.Palette.ink)
        .sensoryFeedback(.success, trigger: model.didSave)
        .onChange(of: model.hasUnsavedWork, initial: true) { _, unsaved in
            onUnsavedWorkChange(unsaved)
        }
        .confirmationDialog(cancelTitle, isPresented: $confirmingCancel, titleVisibility: .visible) {
            if model.canKeepDraft {
                Button("Keep as draft") {
                    model.keepDraft()
                    model.onCancel()
                }
            }
            Button("Discard note", role: .destructive) { model.onCancel() }
            Button("Keep writing", role: .cancel) {}
        } message: {
            if model.song != nil {
                Text("A draft waits in Resonote until you publish it.")
            } else if model.canKeepDraft {
                Text("A draft waits in Resonote and joins this song once it's matched.")
            }
        }
    }

    private var showsForm: Bool {
        model.phase != .signedOut && model.phase != .noLink
    }

    private var cancelTitle: String {
        model.canKeepDraft ? "Keep this note?" : "Discard this note?"
    }

    private func cancel() {
        if model.hasUnsavedWork {
            confirmingCancel = true
        } else {
            model.onCancel()
        }
    }

    // MARK: Form

    /// Once Save is tapped, what's being sent can't change underneath it: words typed or
    /// a visibility flipped during "Saving…" would never reach the server.
    private var isLocked: Bool { model.isSaving || model.didSave }

    /// The status (a weak match's candidates, or why it couldn't load) sits below the
    /// note, so it never pushes the field down while the person is typing.
    @ViewBuilder private var songForm: some View {
        SongHeader(model: model)
        VStack(alignment: .leading, spacing: RN.Space.m) {
            Text(model.prompt)
                .font(RN.Typography.serif(18, relativeTo: .body))
                .foregroundStyle(RN.Palette.prose)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Write freely.", text: $model.text, axis: .vertical)
                .font(RN.Typography.prose)
                .lineLimit(4...12)
                .padding(RN.Space.m)
                .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: RN.Radius.input).strokeBorder(RN.Palette.line))
                .accessibilityLabel(model.title.map { "Note about \($0)" } ?? "Note")
                .disabled(isLocked)
            Toggle(isOn: $model.isPublic) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(VisibilityCopy.publicLabel)
                        .font(.subheadline.weight(.semibold))
                    VisibilityNote(isPublic: model.isPublic)
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                }
            }
            .tint(RN.Palette.rust)
            .disabled(isLocked)
        }
        statusBlock
        if model.phase == .ready || model.phase == .loading {
            tagSections
                .disabled(isLocked)
        }
    }

    /// What went wrong or what to pick, between the header and the note.
    @ViewBuilder private var statusBlock: some View {
        switch model.phase {
        case .unreachable(let message):
            VStack(alignment: .leading, spacing: RN.Space.s) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.rustText)
                Button("Retry") { Task { await model.resolve() } }
                    .buttonStyle(ShareOutlineButtonStyle())
            }
        case .unmatched:
            CandidateList(model: model)
        case .loading, .ready, .signedOut, .noLink:
            EmptyView()
        }
    }

    @ViewBuilder private var tagSections: some View {
        let loading = model.phase == .loading
        TagSection(title: "What kind of thought is this?", loading: loading, placeholderWidths: [74, 58, 104, 104, 92, 74]) {
            ForEach(model.lensOptions, id: \.self) { lens in
                ShareChip(title: lens.rawValue, isSelected: model.lenses.contains(lens)) { model.toggle(lens) }
            }
        }
        TagSection(title: "How did this listen feel?", loading: loading, placeholderWidths: [82, 60, 80, 66, 66, 72, 88, 92]) {
            ForEach(model.moodOptions, id: \.self) { mood in
                ShareChip(title: mood, isSelected: model.moods.contains(mood)) { model.toggle(mood: mood) }
            }
        }
        if !model.genreOptions.isEmpty {
            TagSection(title: "How do you hear it?", loading: false, placeholderWidths: []) {
                ForEach(model.genreOptions) { genre in
                    ShareChip(title: genre.name, isSelected: model.genreIds.contains(genre.id)) { model.toggle(genreId: genre.id) }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: RN.Space.xs) {
            if showsForm {
                Text(model.saveError ?? " ")
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.rustText)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .opacity(model.saveError == nil ? 0 : 1)
                    .accessibilityHidden(model.saveError == nil)
                Button {
                    Task { await model.save() }
                } label: {
                    ShareStableLabel(active: model.saveLabel, candidates: ShareModel.saveLabels)
                }
                .buttonStyle(ShareSolidButtonStyle())
                .disabled(!model.canSave)
            } else {
                Button("Done") { model.onCancel() }
                    .buttonStyle(ShareSolidButtonStyle())
            }
        }
        .padding(.horizontal, RN.Space.gutter)
        .padding(.top, RN.Space.s)
        .padding(.bottom, RN.Space.s)
        .background(RN.Palette.paper3)
    }
}

// MARK: - Pieces

/// Artwork, title, and artist in fixed geometry; a quiet line while the song loads.
private struct SongHeader: View {
    let model: ShareModel

    var body: some View {
        HStack(alignment: .center, spacing: RN.Space.m) {
            ShareArtwork(model.artworkURL, title: model.title ?? "", size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title ?? "Finding the song…")
                    .font(RN.Typography.serif(20, relativeTo: .title3))
                    .foregroundStyle(model.title == nil ? RN.Palette.muted : RN.Palette.ink)
                    .lineLimit(2)
                Text(model.artist ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Weak or missing matches: the closest MusicBrainz recordings, imported only when picked.
private struct CandidateList: View {
    let model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Text("Couldn’t find this song")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
            if model.candidates.isEmpty {
                Text("Try sharing it from another app.")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            } else {
                Text("Is it one of these?")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                VStack(spacing: 0) {
                    ForEach(model.candidates) { candidate in
                        CandidateRow(candidate: candidate, isImporting: model.importingCandidateId == candidate.id) {
                            Task { await model.choose(candidate) }
                        }
                        .disabled(model.importingCandidateId != nil)
                        if candidate.id != model.candidates.last?.id {
                            Divider().overlay(RN.Palette.line)
                        }
                    }
                }
                .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: RN.Radius.card).strokeBorder(RN.Palette.line))
            }
            Text(model.candidateError ?? " ")
                .font(.footnote)
                .foregroundStyle(RN.Palette.rustText)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .opacity(model.candidateError == nil ? 0 : 1)
                .accessibilityHidden(model.candidateError == nil)
        }
    }
}

private struct CandidateRow: View {
    let candidate: SearchResult
    let isImporting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RN.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.entity.name)
                        .font(.body)
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(1)
                    Text(candidate.subtitle)
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ZStack {
                    ProgressView().opacity(isImporting ? 1 : 0)
                    Image(systemName: "plus.circle")
                        .foregroundStyle(RN.Palette.muted)
                        .opacity(isImporting ? 0 : 1)
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, RN.Space.m)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.entity.name), \(candidate.subtitle)")
        .accessibilityHint("Adds this song to Resonote")
    }
}

/// A heading and a wrapping row of chips, or placeholder chips of final size while loading.
private struct TagSection<Chips: View>: View {
    let title: String
    let loading: Bool
    let placeholderWidths: [CGFloat]
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            ShareSectionTitle(text: title)
            ShareFlowLayout {
                if loading {
                    ForEach(Array(placeholderWidths.enumerated()), id: \.offset) { _, width in
                        ShareChipPlaceholder(width: width)
                    }
                } else {
                    chips()
                }
            }
        }
    }
}

/// A calm message with no form, for signed-out and link-less shares.
private struct Notice: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Text(title)
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RN.Space.l)
        .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: RN.Radius.card).strokeBorder(RN.Palette.line))
    }
}
