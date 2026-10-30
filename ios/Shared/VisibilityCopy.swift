import SwiftUI

/// One wording for who can read a note or a collection, used by capture, the composer,
/// collections, and the share sheet, so the same choice never reads three ways.
/// Everything starts private; publishing is a choice the person makes each time.
nonisolated enum VisibilityCopy {
    /// The action, for a switch or a button: "Publish".
    static let publicLabel = "Publish"
    /// The state, for a picker segment or a marker: "Published".
    static let publishedLabel = "Published"
    static let privateLabel = "Only me"
    static let publicNote = "Anyone can read it on your profile and on this music's page. You can unpublish it any time."
    static let privateNote = "Only you can read it. Nothing is published unless you choose to."

    /// Undoing a publish: "Make private".
    static let unpublishLabel = "Make private"

    static func note(isPublic: Bool) -> String {
        isPublic ? publicNote : privateNote
    }

    /// The same choice for a collection, which lives on the profile rather than a music page.
    static func collectionNote(isPublic: Bool) -> String {
        isPublic ? "Anyone can see it on your profile. You can make it private any time." : "Only you can see it. Nothing is published unless you choose to."
    }

    /// The short marker on a card or a byline.
    static func marker(isPublic: Bool) -> String {
        isPublic ? publishedLabel : privateLabel
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

/// "Only me" with a lock, or "Published" with a globe, at the width of the longer one,
/// so flipping it never moves what sits beside it.
struct VisibilityMarker: View {
    let isPublic: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isPublic ? "globe" : "lock")
                .imageScale(.small)
            ZStack(alignment: .leading) {
                ForEach([true, false], id: \.self) { option in
                    Text(VisibilityCopy.marker(isPublic: option))
                        .opacity(option == isPublic ? 1 : 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VisibilityCopy.marker(isPublic: isPublic))
    }
}
