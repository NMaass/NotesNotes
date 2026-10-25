import ResonoteKit
import SwiftUI

/// The frame every entity sheet shares: a scrolling column with the page gutter and a
/// close button. `onClose` lets a sheet with unsaved input ask before closing.
struct EntitySheetScaffold<Content: View>: View {
    var onClose: (() -> Void)?
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    init(onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RN.Space.l) {
                    content
                }
                .padding(.horizontal, RN.Space.gutter)
                .padding(.bottom, RN.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    EntitySheetCloseButton {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
            }
        }
    }
}

struct EntitySheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Close", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
    }
}

/// The serif title and one explanatory sentence, as at the top of the web dialogs.
struct EntitySheetHeading: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Text(title)
                .font(RN.Typography.title)
                .foregroundStyle(RN.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labeled text input in the sheet style.
struct EntitySheetField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var systemImage: String?
    var lines: ClosedRange<Int> = 1...1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(RN.Palette.muted)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: RN.Space.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(RN.Palette.muted)
                        .accessibilityHidden(true)
                }
                TextField(placeholder, text: $text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
                    .lineLimit(lines)
                    .foregroundStyle(RN.Palette.ink)
                    .accessibilityLabel(label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RN.Palette.fill, in: RoundedRectangle(cornerRadius: RN.Radius.input))
            .overlay(RoundedRectangle(cornerRadius: RN.Radius.input).strokeBorder(RN.Palette.line))
        }
    }
}

/// "Sign in to …" in place of a sheet's content when the person is signed out.
struct EntitySheetSignedOut: View {
    let message: String

    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(title: "Sign in first", message: message, actionTitle: "Sign in") {
            model.requireAuth {}
        }
    }
}

extension AppModel {
    /// The entity from this device's catalog, loading its page when it hasn't been seen yet.
    func ensureEntity(kind: EntityKind, id: String) async -> CatalogEntity? {
        if let known = catalog.entity(kind: kind, id: id) { return known }
        guard let loaded = try? await EntityDetailStore.shared.load(kind: kind, id: id, api: api, viewer: profile?.id) else { return nil }
        absorb(loaded.detail)
        return loaded.detail.entity
    }
}
