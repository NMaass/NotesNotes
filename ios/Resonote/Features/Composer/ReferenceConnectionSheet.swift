import ResonoteKit
import SwiftUI

/// Identifies the reference whose connection is being described.
struct ReferenceEditTarget: Identifiable, Hashable {
    let id: String
}

/// "Describe the connection": how a linked piece of music relates to the subject, and
/// what connects them. Changes apply to the reference in the text immediately.
struct ReferenceConnectionSheet: View {
    let session: ComposerSession
    let referenceId: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let reference = session.reference(id: referenceId) {
                    content(reference)
                } else {
                    EmptyStateView(title: "This link is gone", message: "It was removed from your writing.")
                        .padding(RN.Space.gutter)
                }
            }
            .foregroundStyle(RN.Palette.ink)
            .navigationTitle("Describe the connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func content(_ reference: MusicReference) -> some View {
        VStack(alignment: .leading, spacing: RN.Space.xl) {
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Eyebrow(reference.entityKind.label)
                Text(reference.label)
                    .font(RN.Typography.title)
                    .foregroundStyle(RN.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: RN.Space.s) {
                ComposerSectionTitle(title: "Relationship", note: nil)
                FlowLayout {
                    ForEach(RelationKind.allCases, id: \.self) { relation in
                        Chip(relation.label, isSelected: reference.relation == relation) {
                            session.setRelation(relation, for: reference.id)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Relationship to \(reference.label)")
            }

            VStack(alignment: .leading, spacing: RN.Space.s) {
                ComposerSectionTitle(title: "What connects them?", note: nil)
                FlowLayout {
                    ForEach(MusicLens.allCases, id: \.self) { lens in
                        Chip(lens.rawValue, isSelected: reference.lenses.contains(lens)) {
                            session.toggleLens(lens, for: reference.id)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Connection lenses for \(reference.label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RN.Space.gutter)
        .padding(.vertical, RN.Space.l)
    }
}
