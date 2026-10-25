import ResonoteKit
import SwiftUI

/// Someone's profile. The signed-in person's own handle shows their full,
/// editable journal; anyone else's shows their public page, read-only.
struct ProfileView: View {
    let handle: String

    @Environment(AppModel.self) private var model
    @State private var ownSection: ProfileSection = .journal

    var body: some View {
        if model.isOwnHandle(handle) {
            OwnJournalScreen(section: $ownSection)
        } else {
            PublicProfileScreen(handle: ProfileHandle.normalize(handle))
        }
    }
}

private struct PublicProfileScreen: View {
    let handle: String

    @Environment(AppModel.self) private var model

    private enum LoadState: Equatable {
        case idle, loading, missing
        case failed(String)
    }

    @State private var bundle: ProfileBundle?
    @State private var loadState: LoadState = .idle
    @State private var section: ProfileSection = .journal
    @State private var choosesReportReason = false
    @State private var confirmsBlock = false

    init(handle: String) {
        self.handle = handle
        _bundle = State(initialValue: PublicProfileCache.bundle(handle: handle))
    }

    var body: some View {
        ScrollView {
            if let bundle, model.isBlocked(bundle.profile.id) {
                BlockedNotice(profile: bundle.profile)
                    .padding(.horizontal, RN.Space.gutter)
                    .padding(.vertical, RN.Space.l)
            } else if let bundle {
                ProfileContent(bundle: bundle, isOwner: false, section: $section)
            } else {
                Group {
                    switch loadState {
                    case .idle, .loading:
                        ProfilePlaceholder()
                    case .missing:
                        EmptyStateView(title: "Profile not found", message: "This profile may not exist or may not be available.")
                    case .failed(let message):
                        EmptyStateView(title: "Couldn't load this profile", message: message, actionTitle: "Try again") {
                            Task { await load(force: true) }
                        }
                    }
                }
                .padding(.horizontal, RN.Space.gutter)
                .padding(.vertical, RN.Space.l)
            }
        }
        .refreshable { await load(force: true) }
        .paperBackground()
        .navigationTitle("@\(bundle?.profile.handle ?? handle)")
        .toolbarTitleDisplayMode(.inline)
        // The header shows the name and handle; the title stays for history and VoiceOver.
        .toolbar(removing: .title)
        .toolbar {
            if let profile = bundle?.profile, model.isSignedIn, profile.id != model.profile?.id {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            choosesReportReason = true
                        } label: {
                            Label("Report profile", systemImage: "flag")
                        }
                        if model.isBlocked(profile.id) {
                            Button {
                                model.unblock(profile.id)
                            } label: {
                                Label("Unblock @\(profile.handle)", systemImage: "hand.raised.slash")
                            }
                        } else {
                            Button(role: .destructive) {
                                confirmsBlock = true
                            } label: {
                                Label("Block @\(profile.handle)", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Label("Profile options", systemImage: "ellipsis")
                    }
                }
            }
        }
        .reportReasonDialog(isPresented: $choosesReportReason) { reason in
            if let profile = bundle?.profile { model.report(.profile, id: profile.id, reason: reason) }
        }
        .blockConfirmation(isPresented: $confirmsBlock, profile: bundle?.profile)
        // Coming back to the page reuses a copy loaded in the last minute or so.
        .task(id: handle) { await load(force: false) }
    }

    /// Loads (or refreshes) the page. What is on screen stays until the new copy replaces it.
    private func load(force: Bool) async {
        if bundle == nil { loadState = .loading }
        do {
            bundle = try await model.loadPublicBundle(handle: handle, force: force)
            loadState = .idle
        } catch is CancellationError {
            return
        } catch APIError.server(status: 404, _) {
            if bundle == nil { loadState = .missing }
        } catch {
            guard bundle == nil else { return }
            loadState = .failed((error as? APIError)?.errorDescription ?? "Resonote can't be reached right now.")
        }
    }
}

/// A profile's header, section picker, and two cards at their final size while
/// the page loads, so nothing jumps when it arrives.
private struct ProfilePlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.xl) {
            HStack(spacing: RN.Space.l) {
                Circle()
                    .fill(RN.Palette.paper3)
                    .frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: RN.Space.xs) {
                    Text("Display name")
                        .font(RN.Typography.display)
                    Text("@handle")
                        .font(.subheadline)
                }
                .redacted(reason: .placeholder)
            }
            Text("A few words about what this person listens for, a line or two long.")
                .font(.body)
                .redacted(reason: .placeholder)
            RoundedRectangle(cornerRadius: RN.Radius.button + 4)
                .fill(RN.Palette.fill)
                .frame(height: 56)
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: RN.Radius.card)
                    .fill(RN.Palette.paper2)
                    .overlay(RoundedRectangle(cornerRadius: RN.Radius.card).strokeBorder(RN.Palette.line))
                    .frame(height: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading profile")
    }
}
