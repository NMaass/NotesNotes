import ResonoteKit
import SwiftUI

/// Add an entity to one of the person's collections, or make a new one for it.
struct CollectSheet: View {
    let kind: EntityKind
    let id: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var details = ""
    /// Set when the entity had to be loaded because this device hadn't seen it.
    @State private var fetched: CatalogEntity?
    @State private var lookupFailed = false
    @State private var added = 0
    @State private var confirmsDiscard = false
    @State private var lookupAttempt = 0

    private var entity: CatalogEntity? {
        model.catalog.entity(kind: kind, id: id) ?? fetched
    }

    private var hasInput: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        EntitySheetScaffold(onClose: close) {
            EntitySheetHeading(
                title: "Add to a collection",
                message: "Collections are personal explanations of spiritual similarity—not algorithmic genres."
            )
            if !model.isSignedIn {
                EntitySheetSignedOut(message: "Collections belong to your profile, so sign in to keep one.")
            } else if let entity {
                picker(for: entity)
            } else if lookupFailed {
                EmptyStateView(title: "This page didn't load", message: "Resonote can't find this music right now. Try again in a moment.", actionTitle: "Try again") {
                    lookupFailed = false
                    lookupAttempt += 1
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(hasInput)
        .holdsUnsavedInput(hasInput)
        .sensoryFeedback(.success, trigger: added)
        .confirmationDialog("Discard this collection?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .task(id: "\(id)#\(lookupAttempt)") {
            if !model.isSignedIn, lookupAttempt == 0 { model.requireAuth {} }
            if entity == nil {
                fetched = await model.ensureEntity(kind: kind, id: id)
                lookupFailed = fetched == nil
            }
        }
    }

    private func picker(for entity: CatalogEntity) -> some View {
        let collections = model.bundle?.collections ?? []
        return VStack(alignment: .leading, spacing: RN.Space.l) {
            if !collections.isEmpty {
                VStack(spacing: 0) {
                    ForEach(collections) { collection in
                        if collection.id != collections.first?.id {
                            Divider().overlay(RN.Palette.line)
                        }
                        row(collection, entity: entity)
                    }
                }
                .padding(.horizontal, RN.Space.m)
                .cardSurface()
            }

            HStack(spacing: RN.Space.m) {
                Rectangle().fill(RN.Palette.line).frame(height: 1)
                Text("or make one")
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.muted)
                    .fixedSize()
                Rectangle().fill(RN.Palette.line).frame(height: 1)
            }
            .accessibilityElement(children: .combine)

            EntitySheetField(label: "Name", placeholder: "fluorescent parking lots at 2am", text: $name)
            EntitySheetField(label: "What holds it together?", placeholder: "", text: $details, lines: 2...5)
            Button {
                createAndAdd(entity)
            } label: {
                Label("Create and add", systemImage: "plus")
            }
            .buttonStyle(.solid)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func row(_ collection: MusicCollection, entity: CatalogEntity) -> some View {
        let alreadyHere = collection.items.contains { $0.entityId == entity.id }
        let count = collection.items.count
        return Button {
            model.add(entity, toCollection: collection.id)
            added += 1
            AccessibilityNotification.Announcement("Added to collection").post()
            dismiss()
        } label: {
            HStack(spacing: RN.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(2)
                    Text(alreadyHere ? "Already here" : count == 1 ? "1 item" : "\(count) items")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                }
                Spacer(minLength: RN.Space.s)
                Image(systemName: alreadyHere ? "checkmark" : "plus")
                    .foregroundStyle(alreadyHere ? RN.Palette.muted : RN.Palette.ink)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyHere)
        .opacity(alreadyHere ? 0.6 : 1)
    }

    private func createAndAdd(_ entity: CatalogEntity) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let collection = model.createCollection(name: trimmedName, description: details.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        model.add(entity, toCollection: collection.id)
        added += 1
        AccessibilityNotification.Announcement("Collection created").post()
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
