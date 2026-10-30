import ResonoteKit
import SwiftUI

/// "Journal about song", the subject's name, and the no-score promise.
struct ComposerHeader: View {
    let kind: EntityKind
    /// nil while the subject is still loading.
    let name: String?
    let loadFailed: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Eyebrow("Journal about \(kind.rawValue)")
            Group {
                if let name {
                    Text(name)
                } else if loadFailed {
                    Text("This \(kind.rawValue)")
                } else {
                    Text("Loading the music")
                        .redacted(reason: .placeholder)
                        .accessibilityLabel("Loading")
                }
            }
            .font(RN.Typography.display)
            .foregroundStyle(RN.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            if loadFailed, name == nil {
                HStack(spacing: RN.Space.s) {
                    Text("Its details couldn't load. Your writing is safe.")
                        .foregroundStyle(RN.Palette.muted)
                    Button("Try again", action: retry)
                        .foregroundStyle(RN.Palette.rustText)
                }
                .font(.footnote)
            }
            Text("No score. Describe what you heard.")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet line when the composer opened from a saved draft, with a way to start over.
struct ComposerDraftNotice: View {
    let session: ComposerSession
    @State private var isConfirmingDiscard = false

    var body: some View {
        if session.restoredDraft {
            HStack(spacing: RN.Space.s) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityHidden(true)
                Text("Picking up your draft from this device.")
                    .foregroundStyle(RN.Palette.muted)
                Spacer(minLength: 0)
                Button("Discard") { isConfirmingDiscard = true }
                    .foregroundStyle(RN.Palette.rustText)
            }
            .font(.footnote)
            .confirmationDialog("Discard this draft?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard draft", role: .destructive) { session.discardDraft() }
                Button("Keep writing", role: .cancel) {}
            } message: {
                Text(session.isEditingPublishedEntry
                     ? "The saved entry stays as it is."
                     : "What you wrote here will be gone.")
            }
        }
    }
}

/// One writing prompt at a time. Every prompt sits in the same cell, so the panel's
/// height never changes as they rotate.
struct ComposerPromptPanel: View {
    let session: ComposerSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: RN.Space.m) {
            Image(systemName: "sparkles")
                .foregroundStyle(RN.Palette.rustText)
                .accessibilityHidden(true)
            ZStack(alignment: .topLeading) {
                ForEach(Array(Vocabulary.prompts.enumerated()), id: \.offset) { index, prompt in
                    Text(prompt)
                        .font(RN.Typography.headline.italic())
                        .foregroundStyle(RN.Palette.prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(index == session.promptIndex ? 1 : 0)
                        .accessibilityHidden(index != session.promptIndex)
                }
            }
            Button {
                withAnimation(reduceMotion ? nil : RN.Motion.quick) { session.nextPrompt() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RN.Palette.muted)
            .accessibilityLabel("Another prompt")
        }
        .padding(.leading, RN.Space.l)
        .padding(.trailing, RN.Space.xs)
        .padding(.vertical, RN.Space.s)
        .cardSurface()
    }
}

/// "Optional title" with the web's placeholder.
struct ComposerTitleField: View {
    @Bindable var session: ComposerSession
    var focus: FocusState<ComposerField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.xs) {
            Text("Optional title")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RN.Palette.muted)
            TextField("A thought worth naming", text: $session.title, axis: .vertical)
                .lineLimit(1...3)
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.ink)
                .submitLabel(.next)
                .focused(focus, equals: .title)
                .onSubmit { focus.wrappedValue = .body }
                .onChange(of: session.title) { _, title in
                    // Return moves on to the writing; a title stays one line of thought.
                    guard title.contains(where: \.isNewline) else { return }
                    session.title = title.filter { !$0.isNewline }
                    focus.wrappedValue = .body
                }
                .padding(.horizontal, RN.Space.m)
                .padding(.vertical, RN.Space.m)
                .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: RN.Radius.input).strokeBorder(RN.Palette.line))
                .accessibilityLabel("Optional title")
        }
    }
}

/// Every reference in the text, each with a way to say why it is there.
struct ComposerLinkedMusic: View {
    let session: ComposerSession
    let onDescribe: (String) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if !session.references.isEmpty {
            VStack(alignment: .leading, spacing: RN.Space.m) {
                VStack(alignment: .leading, spacing: RN.Space.xs) {
                    Eyebrow("Linked music")
                    Text("The link is enough. Open a connection only when you want to describe why it is here.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(session.references.enumerated()), id: \.element.id) { offset, reference in
                        if offset > 0 { Divider().overlay(RN.Palette.line) }
                        row(reference)
                    }
                }
                .cardSurface()
            }
        }
    }

    private func row(_ reference: MusicReference) -> some View {
        let entity = model.catalog.entity(kind: reference.entityKind, id: reference.entityId)
        let artwork = entity.flatMap { model.catalog.artworkURL(for: $0) }
        return Button {
            onDescribe(reference.id)
        } label: {
            HStack(spacing: RN.Space.m) {
                ArtworkView(artwork, title: reference.label, size: 40, cornerRadius: reference.entityKind == .artist ? 20 : RN.Radius.artwork)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(1)
                    Text(ComposerLinkedMusic.summary(reference))
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Describe")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.rustText)
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
        .accessibilityLabel("\(reference.label), \(reference.entityKind.label)")
        .accessibilityValue(ComposerLinkedMusic.summary(reference))
        .accessibilityHint("Describe the connection")
    }

    /// "Song · reminds me of · feeling, lyrics"
    static func summary(_ reference: MusicReference) -> String {
        var parts = [reference.entityKind.label, reference.relation.label]
        if !reference.lenses.isEmpty { parts.append(reference.lenses.map(\.rawValue).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// "What kind of thought is this?" lens chips.
struct ComposerLensSection: View {
    let session: ComposerSession

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            ComposerSectionTitle(title: "What kind of thought is this?", note: "Optional. Choose any that help someone find the angle you took.")
            FlowLayout {
                ForEach(MusicLens.allCases, id: \.self) { lens in
                    Chip(lens.rawValue, isSelected: session.lenses.contains(lens)) {
                        session.toggleEntryLens(lens)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Lenses")
        }
    }
}

/// "+ What worked for me" / "+ What did not work for me", each revealing its own field.
struct ComposerReflections: View {
    @Bindable var session: ComposerSession
    var focus: FocusState<ComposerField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            ComposerSectionTitle(title: "Optional reflection prompts", note: nil)
            if session.showsWorked {
                field(title: "What worked for me", text: $session.worked, field: .worked)
            } else {
                Button("+ What worked for me") {
                    session.showsWorked = true
                    focus.wrappedValue = .worked
                }
                .buttonStyle(.outline)
            }
            if session.showsDidntWork {
                field(title: "What did not work for me", text: $session.didntWork, field: .didntWork)
            } else {
                Button("+ What did not work for me") {
                    session.showsDidntWork = true
                    focus.wrappedValue = .didntWork
                }
                .buttonStyle(.outline)
            }
        }
    }

    private func field(title: String, text: Binding<String>, field: ComposerField) -> some View {
        VStack(alignment: .leading, spacing: RN.Space.xs) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RN.Palette.muted)
            TextField("", text: text, axis: .vertical)
                .lineLimit(3...10)
                .font(.body)
                .foregroundStyle(RN.Palette.ink)
                .focused(focus, equals: field)
                .padding(RN.Space.m)
                .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: RN.Radius.input).strokeBorder(RN.Palette.line))
                .accessibilityLabel(title)
        }
    }
}

/// Only me / Published. Private comes first and is where every new entry starts.
struct ComposerVisibility: View {
    @Bindable var session: ComposerSession

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            ComposerSectionTitle(title: "Who can read this", note: nil)
            Picker("Who can read this", selection: $session.isPublic) {
                Text(VisibilityCopy.privateLabel).tag(false)
                Text(VisibilityCopy.publishedLabel).tag(true)
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: session.isPublic)
            // Both explanations share one cell so the section never changes height.
            VisibilityNote(isPublic: session.isPublic)
                .font(.footnote)
                .foregroundStyle(RN.Palette.muted)
        }
    }
}

/// A serif section heading with an optional muted note, like the web's `.editor-section h2`.
struct ComposerSectionTitle: View {
    let title: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.xs) {
            Text(title)
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
