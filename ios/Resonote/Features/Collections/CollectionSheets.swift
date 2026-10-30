import ResonoteKit
import SwiftUI

/// "Make a collection": a name in the person's own words and what holds it together.
struct NewCollectionSheet: View {
    /// Called after the collection exists locally (it syncs in the background).
    /// Without one, the new collection opens on the visible tab.
    var onCreated: ((MusicCollection) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    /// Private first: a new collection is only the owner's until they publish it.
    @State private var isPublic = false
    @State private var confirmDiscard = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { !trimmedName.isEmpty || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPublic }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("songs that sound like the room is breathing"))
                        .focused($nameFocused)
                        .submitLabel(.next)
                } header: {
                    Text("Name a relationship between pieces of music in your own language.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .textCase(nil)
                        .padding(.bottom, RN.Space.s)
                }
                .listRowBackground(RN.Palette.paper2)

                Section {
                    TextField("What holds it together?", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("What holds it together?")
                }
                .listRowBackground(RN.Palette.paper2)

                CollectionVisibilitySection(isPublic: $isPublic)
            }
            .journalFormStyle()
            .navigationTitle("Make a collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(trimmedName.isEmpty)
                        .accessibilityLabel("Create collection")
                }
            }
            .confirmationDialog("Discard this collection?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(isDirty)
        .holdsUnsavedInput(isDirty)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty,
              let collection = model.createCollection(name: trimmedName, description: description.trimmingCharacters(in: .whitespacesAndNewlines), isPublic: isPublic) else { return }
        AccessibilityNotification.Announcement(isPublic ? "Collection created and published" : "Collection created").post()
        dismiss()
        if let onCreated {
            onCreated(collection)
        } else if let handle = model.profile?.handle {
            router.push(.collection(handle: handle, id: collection.id))
        }
    }
}

/// Name, description, and visibility of one of the owner's collections.
struct EditCollectionSheet: View {
    let collectionId: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var isPublic: Bool
    @State private var confirmDiscard = false
    private let original: (name: String, description: String, isPublic: Bool)

    init(collection: MusicCollection) {
        collectionId = collection.id
        original = (collection.name, collection.description, collection.isPublic)
        _name = State(initialValue: collection.name)
        _description = State(initialValue: collection.description)
        _isPublic = State(initialValue: collection.isPublic)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool {
        trimmedName != original.name || trimmedDescription != original.description || isPublic != original.isPublic
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text("songs that sound like the room is breathing"))
                }
                .listRowBackground(RN.Palette.paper2)

                Section("What holds it together?") {
                    TextField("What holds it together?", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
                .listRowBackground(RN.Palette.paper2)

                CollectionVisibilitySection(isPublic: $isPublic)
            }
            .journalFormStyle()
            .navigationTitle("Edit collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || !isDirty)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(isDirty)
        .holdsUnsavedInput(isDirty)
    }

    private func save() {
        // Re-read the collection so a reorder made while this sheet was open is kept.
        guard !trimmedName.isEmpty, var latest = model.bundle?.collections.first(where: { $0.id == collectionId }) else {
            dismiss()
            return
        }
        latest.name = trimmedName
        latest.description = trimmedDescription
        latest.isPublic = isPublic
        model.updateCollection(latest)
        dismiss()
    }
}

/// Publish, off by default, with a footer that keeps its height as the switch flips.
private struct CollectionVisibilitySection: View {
    @Binding var isPublic: Bool

    var body: some View {
        Section {
            Toggle(VisibilityCopy.publicLabel, isOn: $isPublic)
                .sensoryFeedback(.selection, trigger: isPublic)
        } footer: {
            ZStack(alignment: .topLeading) {
                ForEach([true, false], id: \.self) { option in
                    Text(VisibilityCopy.collectionNote(isPublic: option))
                        .opacity(option == isPublic ? 1 : 0)
                        .accessibilityHidden(option != isPublic)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(RN.Palette.paper2)
    }
}

/// Edits one of the owner's collections by id, for presenting through `Router.sheet`.
struct EditCollectionHost: View {
    let collectionId: String

    @Environment(AppModel.self) private var model

    var body: some View {
        if let collection = model.bundle?.collections.first(where: { $0.id == collectionId }) {
            EditCollectionSheet(collection: collection)
        }
    }
}

extension View {
    /// Forms on paper: the page background shows through and rows sit on raised paper.
    func journalFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(RN.Palette.paper.ignoresSafeArea())
    }
}
