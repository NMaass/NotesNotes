import ResonoteKit
import SwiftUI

/// Journal tab root: the signed-in person's own page, or an invitation to sign in.
struct JournalView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("journal.section") private var section: ProfileSection = .journal

    var body: some View {
        if model.isSignedIn {
            OwnJournalScreen(section: $section)
        } else if model.isRestoringSession {
            // The session cached on this device is still being read: no welcome flash.
            RN.Palette.paper
                .ignoresSafeArea()
                .navigationTitle("Journal")
                .toolbarTitleDisplayMode(.inline)
        } else {
            JournalWelcome()
        }
    }
}

/// The owner's profile with everything they can change: profile details,
/// collections, and settings. Shared by the Journal tab and `ProfileView` when the
/// handle is their own.
struct OwnJournalScreen: View {
    @Binding var section: ProfileSection

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if let bundle = model.bundle {
                ScrollView {
                    ProfileContent(
                        bundle: bundle,
                        isOwner: true,
                        section: $section,
                        onEditProfile: { router.present(.editProfile) },
                        onNewCollection: { router.present(.newCollection) }
                    )
                }
                .refreshable { await model.refreshSession() }
            } else {
                JournalWelcomeContent()
            }
        }
        .paperBackground()
        .navigationTitle("Journal")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.present(.editProfile)
                    } label: {
                        Label("Edit profile", systemImage: "pencil")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }
}

/// Signed out: the web onboarding's first screen, with Settings still in reach.
private struct JournalWelcome: View {
    @Environment(Router.self) private var router

    var body: some View {
        JournalWelcomeContent()
            .navigationTitle("Journal")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.push(.settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
    }
}

private struct JournalWelcomeContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RN.Space.m) {
                Eyebrow("No password")
                Text("Make a place for what you hear.")
                    .font(RN.Typography.display)
                    .foregroundStyle(RN.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Use email and a one-time code — no password.")
                    .font(.body)
                    .foregroundStyle(RN.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.requireAuth {}
                } label: {
                    HStack(spacing: RN.Space.s) {
                        Text("Continue with email")
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.solid)
                .padding(.top, RN.Space.l)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RN.Space.gutter)
            .padding(.top, RN.Space.xxl)
        }
        .paperBackground()
    }
}
