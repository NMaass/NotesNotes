import ResonoteKit
import SwiftUI

/// The writing surface: Georgia prose on the editor paper, `\` references in rust,
/// and a placeholder that says how to link music.
struct ComposerEditorSurface: View {
    @Bindable var session: ComposerSession
    let subjectName: String
    var focus: FocusState<ComposerField?>.Binding

    static let placeholder = "Write freely. Type \\ to link a song, album, artist, or genre."

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.xs) {
            if session.flattensStructure {
                Label("Headings, lists, and quotes from the web become plain paragraphs here.", systemImage: "text.alignleft")
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.muted)
                    .padding(.bottom, RN.Space.xs)
            }
            editor
            ReservedErrorRow(message: session.publishError)
        }
    }

    private var editor: some View {
        TextEditor(text: $session.text, selection: $session.selection)
            .font(RN.Typography.prose)
            .lineHeight(.multiple(factor: 1.4))
            .foregroundStyle(RN.Palette.ink)
            .attributedTextFormattingDefinition(NoteFormatting(referenceColor: RN.Palette.rustText))
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .focused(focus, equals: .body)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .padding(.horizontal, RN.Space.s)
            .padding(.vertical, RN.Space.xs)
            .overlay(alignment: .topLeading) { placeholder }
            .background(RN.Palette.paper3, in: RoundedRectangle(cornerRadius: RN.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: RN.Radius.card)
                    .strokeBorder(focus.wrappedValue == .body ? RN.Palette.lineStrong : RN.Palette.line)
            )
            .accessibilityLabel("Journal entry about \(subjectName)")
            .accessibilityHint("Type a backslash, or use Link music above the keyboard, to link a song, album, artist, or genre.")
            .onChange(of: session.text) { _, _ in session.textDidChange() }
            .onChange(of: session.selection) { _, _ in session.selectionDidChange() }
    }

    /// Shown only while the editor is empty; aligned with the editor's own text inset.
    @ViewBuilder
    private var placeholder: some View {
        if session.text.characters.isEmpty {
            Text(Self.placeholder)
                .font(RN.Typography.prose)
                .foregroundStyle(RN.Palette.muted.opacity(0.8))
                .padding(.horizontal, RN.Space.s + 5)
                .padding(.vertical, RN.Space.xs + 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Which field has the keyboard.
enum ComposerField: Hashable {
    case title, body, worked, didntWork
}
