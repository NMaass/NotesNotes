import ResonoteKit
import SwiftUI

/// Log a listen with moods and a note. A listen is an event, not a review.
struct LogListenSheet: View {
    let songId: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selected: [String] = []
    @State private var custom = ""
    @State private var note = ""
    @State private var moods = Vocabulary.moods
    @State private var failure: String?
    @State private var saved = 0
    @State private var confirmsDiscard = false

    private var songName: String? { model.catalog.songs[songId]?.name }
    private var hasInput: Bool {
        !selected.isEmpty || !custom.trimmingCharacters(in: .whitespaces).isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        EntitySheetScaffold(onClose: close) {
            EntitySheetHeading(
                title: songName.map { "Log “\($0)”" } ?? "Log a listen",
                message: "A listen is an event. It does not have to become a review."
            )
            if model.isSignedIn {
                form
            } else {
                EntitySheetSignedOut(message: "Listens are kept in your journal, so sign in to log one.")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasInput)
        .holdsUnsavedInput(hasInput)
        .sensoryFeedback(.success, trigger: saved)
        .confirmationDialog("Discard this listen?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .onAppear(perform: includePersonalMoods)
        .task(id: songId) {
            if songName == nil { _ = await model.ensureEntity(kind: .song, id: songId) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            VStack(alignment: .leading, spacing: RN.Space.s) {
                Text("How did this listen feel?")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityAddTraits(.isHeader)
                FlowLayout {
                    ForEach(moods, id: \.self) { mood in
                        Chip(mood, isSelected: selected.contains(mood)) { toggle(mood) }
                    }
                }
            }
            EntitySheetField(label: "Another mood", placeholder: "your own word", text: $custom, systemImage: "plus")
            EntitySheetField(label: "Optional note", placeholder: "Anything specific about this listen?", text: $note, lines: 3...6)
            VStack(spacing: RN.Space.xs) {
                Button("Save listen", action: save)
                    .buttonStyle(.solid)
                ReservedErrorRow(message: failure)
            }
        }
    }

    private func toggle(_ mood: String) {
        if let index = selected.firstIndex(of: mood) {
            selected.remove(at: index)
        } else {
            selected.append(mood)
        }
    }

    /// Adds words this person has used before to the shared mood vocabulary.
    private func includePersonalMoods() {
        let own = model.habits.moods.filter { !Vocabulary.moods.contains($0) }
        guard !own.isEmpty else { return }
        moods = Vocabulary.moods + own
    }

    private func save() {
        var finalMoods = selected
        let word = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !word.isEmpty, !finalMoods.contains(word) { finalMoods.append(word) }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.logListen(songId: songId, moods: finalMoods, note: trimmedNote.isEmpty ? nil : trimmedNote) != nil else {
            failure = "Sign in to log a listen."
            return
        }
        saved += 1
        AccessibilityNotification.Announcement("Listen logged").post()
        dismiss()
    }

    private func close() {
        if hasInput {
            confirmsDiscard = true
        } else {
            dismiss()
        }
    }
}
