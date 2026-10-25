import ResonoteKit
import SwiftUI
import UIKit

/// Listening sources, widgets and the Action button, blocked people, account, and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.openURL) private var openURL

    private enum SourceField: Hashable { case lastfm, listenbrainz }

    @FocusState private var focusedField: SourceField?
    /// What the person is typing; nil shows the saved value.
    @State private var lastfmDraft: String?
    @State private var listenbrainzDraft: String?
    @State private var isRequestingAppleMusic = false
    @State private var confirmSignOut = false
    @State private var unsyncedWrites = 0
    @State private var confirmDeleteAccount = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?

    var body: some View {
        Form {
            sourcesSection
            widgetsSection
            if !model.blockedProfiles.isEmpty {
                blockedSection
            }
            accountSection
            aboutSection
        }
        .journalFormStyle()
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: focusedField) { previous, _ in
            if previous != nil { saveUsernames() }
        }
        .onDisappear { saveUsernames() }
        .confirmationDialog("Sign out of Resonote?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOut() }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
        .confirmationDialog("Delete your Resonote account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text("This permanently deletes your profile, journal entries, listens, likes, collections, pins, and genre tags, and signs you out everywhere. Drafts on this iPhone are deleted too. It can't be undone.")
        }
    }

    // MARK: Listening sources

    private var sourcesSection: some View {
        Section {
            appleMusicRow
            if nowPlaying.appleMusicAccess == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityHint("Opens Resonote in the Settings app to allow Apple Music")
            }
            usernameField("Last.fm", field: .lastfm, text: lastfmBinding)
            usernameField("ListenBrainz", field: .listenbrainz, text: listenbrainzBinding)
        } header: {
            Text("Listening sources")
        } footer: {
            VStack(alignment: .leading, spacing: RN.Space.s) {
                if !model.isSignedIn, nowPlaying.linkedSources.hasRemote {
                    Text("Sign in to read Last.fm and ListenBrainz.")
                }
                Text("Spotify doesn't let apps read playback anymore. Connect Spotify to Last.fm (last.fm → Settings → Applications) or ListenBrainz (listenbrainz.org → Settings → Music services) and add that username here.")
                Text("YouTube Music: Share a song from YouTube Music to Resonote, or tap Identify — Shazam can hear what's playing, even in AirPods.")
            }
        }
        .listRowBackground(RN.Palette.paper2)
    }

    private var appleMusicRow: some View {
        Toggle(isOn: appleMusicBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Music")
                Text(appleMusicStatus)
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.muted)
            }
        }
        .disabled(nowPlaying.appleMusicAccess == .denied || isRequestingAppleMusic)
    }

    private var appleMusicBinding: Binding<Bool> {
        Binding(
            get: {
                isRequestingAppleMusic || (nowPlaying.linkedSources.appleMusicEnabled && nowPlaying.appleMusicAccess == .granted)
            },
            set: { isOn in
                if isOn {
                    isRequestingAppleMusic = true
                    Task {
                        await nowPlaying.requestAppleMusicAccess()
                        isRequestingAppleMusic = false
                    }
                } else {
                    nowPlaying.disableAppleMusic()
                }
            }
        )
    }

    private var appleMusicStatus: String {
        if isRequestingAppleMusic { return "Waiting for permission" }
        switch nowPlaying.appleMusicAccess {
        case .denied:
            return "Not allowed. Turn on Media & Apple Music for Resonote in Settings."
        case .granted where nowPlaying.linkedSources.appleMusicEnabled:
            return "Sees what the Music app is playing, as it plays."
        default:
            return "Off"
        }
    }

    private func usernameField(_ title: String, field: SourceField, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("Username", text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .submitLabel(.done)
                .focused($focusedField, equals: field)
                .onSubmit { saveUsernames() }
                .accessibilityLabel("\(title) username")
        }
    }

    private var lastfmBinding: Binding<String> {
        Binding(
            get: { lastfmDraft ?? nowPlaying.linkedSources.lastfmUser ?? "" },
            set: { lastfmDraft = $0 }
        )
    }

    private var listenbrainzBinding: Binding<String> {
        Binding(
            get: { listenbrainzDraft ?? nowPlaying.linkedSources.listenbrainzUser ?? "" },
            set: { listenbrainzDraft = $0 }
        )
    }

    /// Trims and stores both usernames, then samples sources again if anything changed.
    private func saveUsernames() {
        var sources = nowPlaying.linkedSources
        if let lastfmDraft { sources.lastfmUser = Self.username(lastfmDraft) }
        if let listenbrainzDraft { sources.listenbrainzUser = Self.username(listenbrainzDraft) }
        lastfmDraft = nil
        listenbrainzDraft = nil
        guard sources != nowPlaying.linkedSources else { return }
        nowPlaying.linkedSources = sources
        nowPlaying.scheduleRefresh()
    }

    private static func username(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Widgets & Action button

    private var widgetsSection: some View {
        Section {
            HowToRow(
                title: "Home Screen widget",
                systemImage: "square.grid.2x2",
                detail: "Touch and hold the Home Screen, tap Edit, then Add Widget, and choose Resonote. It shows what's playing and asks if you want to make a note."
            )
            HowToRow(
                title: "Action button",
                systemImage: "button.programmable",
                detail: "Settings → Action Button → Controls → Resonote → Note Song."
            )
            HowToRow(
                title: "Control Center",
                systemImage: "switch.2",
                detail: "Open Control Center, tap +, then Add a Control, and choose Resonote."
            )
        } header: {
            Text("Widgets & Action button")
        }
        .listRowBackground(RN.Palette.paper2)
    }

    // MARK: Blocked people

    private var blockedSection: some View {
        Section {
            ForEach(model.blockedProfiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                        Text("@\(profile.handle)")
                            .font(.footnote)
                            .foregroundStyle(RN.Palette.muted)
                    }
                    Spacer(minLength: RN.Space.s)
                    Button("Unblock") { model.unblock(profile.id) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RN.Palette.rustText)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Unblock @\(profile.handle)")
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text("Blocked")
        } footer: {
            Text("Their writing is hidden from you everywhere in Resonote.")
        }
        .listRowBackground(RN.Palette.paper2)
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if let profile = model.profile {
                LabeledContent("Signed in as") {
                    Text("@\(profile.handle)")
                        .foregroundStyle(RN.Palette.muted)
                }
                Button("Sign out", role: .destructive) {
                    Task {
                        unsyncedWrites = await model.outbox.pendingCount
                        confirmSignOut = true
                    }
                }
                .disabled(isDeletingAccount)
                Button(role: .destructive) {
                    if model.hasLiveSession {
                        deleteError = nil
                        confirmDeleteAccount = true
                    } else {
                        model.renewSession()
                    }
                } label: {
                    StableLabel(isDeletingAccount ? "Deleting your account…" : "Delete account", among: ["Delete account", "Deleting your account…"])
                }
                .disabled(isDeletingAccount)
                .accessibilityHint("Permanently deletes your account and everything you made on Resonote")
            } else {
                Button("Sign in") { model.requireAuth {} }
            }
        } header: {
            Text("Account")
        } footer: {
            if let deleteError {
                Text(deleteError)
                    .foregroundStyle(RN.Palette.rustText)
            } else if model.sessionExpired {
                Text("Sign in again to delete your account.")
            }
        }
        .listRowBackground(RN.Palette.paper2)
    }

    private func deleteAccount() {
        isDeletingAccount = true
        deleteError = nil
        Task {
            do {
                try await model.deleteAccount()
                AccessibilityNotification.Announcement("Your account was deleted").post()
            } catch {
                deleteError = "Your account wasn't deleted. Check your connection and try again."
            }
            isDeletingAccount = false
        }
    }

    private var signOutMessage: String {
        guard unsyncedWrites > 0 else {
            return "Your journal stays on Resonote. Your drafts stay on this iPhone for when you sign in again."
        }
        let changes = JournalCopy.count(unsyncedWrites, "change")
        return "\(changes) haven't reached Resonote yet and will be removed from this iPhone. Unpublished words go to your drafts here, for when you sign in again."
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            Link(destination: ResonoteLinks.privacy) {
                AboutLinkRow(title: "Privacy policy")
            }
            Link(destination: ResonoteLinks.terms) {
                AboutLinkRow(title: "Terms of use")
            }
            Link(destination: AppGroup.apiBaseURL) {
                LabeledContent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RN.Palette.muted)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resonote on the web")
                            .foregroundStyle(RN.Palette.ink)
                        Text(AppGroup.apiBaseURL.host() ?? AppGroup.apiBaseURL.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(RN.Palette.muted)
                    }
                }
            }
        }
        .listRowBackground(RN.Palette.paper2)
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }()
}

private struct AboutLinkRow: View {
    let title: String

    var body: some View {
        LabeledContent {
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RN.Palette.muted)
                .accessibilityHidden(true)
        } label: {
            Text(title)
                .foregroundStyle(RN.Palette.ink)
        }
    }
}

/// Pages on the Resonote website the app links to.
enum ResonoteLinks {
    static var privacy: URL { AppGroup.apiBaseURL.appending(path: "privacy") }
    static var terms: URL { AppGroup.apiBaseURL.appending(path: "terms") }
}

private struct HowToRow: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(RN.Palette.rustText)
        }
        .accessibilityElement(children: .combine)
    }
}
