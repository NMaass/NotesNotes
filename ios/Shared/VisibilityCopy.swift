import SwiftUI

/// One wording for who can read a note, used by capture, the composer, and the share
/// sheet, so the same choice never reads three ways.
nonisolated enum VisibilityCopy {
    static let publicLabel = "Public"
    static let privateLabel = "Only me"
    static let publicNote = "Anyone can read it on your profile and on this music's page."
    static let privateNote = "Only you can read it."

    static func note(isPublic: Bool) -> String {
        isPublic ? publicNote : privateNote
    }
}

/// Both visibility notes stacked in one cell, only the current one shown, so turning
/// the toggle never changes the row's height.
struct VisibilityNote: View {
    let isPublic: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach([true, false], id: \.self) { option in
                Text(VisibilityCopy.note(isPublic: option))
                    .opacity(option == isPublic ? 1 : 0)
                    .accessibilityHidden(option != isPublic)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
