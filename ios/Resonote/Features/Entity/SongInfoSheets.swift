import ResonoteKit
import SwiftUI

/// Recording-specific collaborators, kept out of the main reading flow.
struct EntityCreditsSheet: View {
    let songName: String
    let credits: [SongCredit]

    @Environment(\.openURL) private var openURL

    var body: some View {
        EntitySheetScaffold {
            EntitySheetHeading(
                title: "Credits for “\(songName)”",
                message: "Recording-specific collaborators, kept out of the main reading flow until you ask for them."
            )
            if credits.isEmpty {
                Text("No structured credits have been cached for this recording yet.")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(credits) { credit in
                        if credit.id != credits.first?.id {
                            Divider().overlay(RN.Palette.line)
                        }
                        row(credit)
                    }
                }
                .padding(.horizontal, RN.Space.m)
                .cardSurface()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ credit: SongCredit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RN.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credit.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                Text(credit.role)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            }
            Spacer(minLength: RN.Space.s)
            if let link = credit.sourceUrl.flatMap(URL.init(string:)) {
                Button {
                    openURL(link)
                } label: {
                    HStack(spacing: 4) {
                        Text(credit.sourceLabel)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption)
                    .foregroundStyle(RN.Palette.rustText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(credit.sourceLabel)")
            } else {
                Text(credit.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
            }
        }
        .padding(.vertical, RN.Space.s)
    }
}

/// Catalog facts, estimates, and community annotations, each labeled with how sure it is.
struct EntityFactsSheet: View {
    let songName: String
    let facts: [SongFact]

    var body: some View {
        EntitySheetScaffold {
            EntitySheetHeading(
                title: "Inside “\(songName)”",
                message: "Catalog facts, estimates, and community annotations are labeled separately rather than presented as equally certain."
            )
            if facts.isEmpty {
                Text("No structural facts have been cached for this recording yet.")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: RN.Space.s), GridItem(.flexible(), spacing: RN.Space.s)], spacing: RN.Space.s) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.label)
                                .font(.caption)
                                .foregroundStyle(RN.Palette.muted)
                            Text(fact.value)
                                .font(RN.Typography.headline)
                                .foregroundStyle(RN.Palette.ink)
                            Text("\(fact.confidence.rawValue) · \(fact.sourceLabel)")
                                .font(.caption2)
                                .foregroundStyle(RN.Palette.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .padding(RN.Space.m)
                        .cardSurface()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
