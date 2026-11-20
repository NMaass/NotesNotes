import AuthenticationServices
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
    @State private var confirmSignOut = false
    @State private var unsyncedWrites = 0
    @State private var confirmDeleteAccount = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?
    @State private var confirmUnlinkLastfm = false
    @State private var confirmUnlinkSpotify = false

    var body: some View {
        Form {
            sourcesSection
            if AppFeatures.identify { identifySection }
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
        .task(id: model.hasLiveSession) {
            async let lastfm: Void = nowPlaying.lastfm.load()
            async let spotify: Void = nowPlaying.spotify.load()
            _ = await (lastfm, spotify)
        }
        .confirmationDialog("Disconnect Spotify?", isPresented: $confirmUnlinkSpotify, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await nowPlaying.spotify.unlink() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Resonote stops reading your Spotify listening and can't play songs there. You can sign in again any time.")
        }
        .confirmationDialog("Disconnect Last.fm?", isPresented: $confirmUnlinkLastfm, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await nowPlaying.lastfm.unlink() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Resonote stops reading your scrobbles. You can sign in again any time.")
        }
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

    /// Where you listen: Spotify and Apple Music, each one row that connects in one tap
    /// or shows that it's connected. Last.fm and ListenBrainz appear only for someone
    /// who already linked them, so they can see and undo it.
    private var sourcesSection: some View {
        let spotify = nowPlaying.spotify
        return Section {
            if let account = spotify.account {
                LabeledContent("Spotify") {
                    Text(account.name)
                        .foregroundStyle(RN.Palette.muted)
                }
                .accessibilityLabel("Spotify, connected as \(account.name)")
                Button("Disconnect Spotify", role: .destructive) { confirmUnlinkSpotify = true }
                    .disabled(spotify.isWorking)
            } else if nowPlaying.canOfferSpotify {
                SpotifySignInButton(title: "Sign in with Spotify")
            }
            if nowPlaying.isAppleMusicOn {
                LabeledContent("Apple Music", value: "Connected")
                Button("Disconnect Apple Music", role: .destructive) { nowPlaying.disableAppleMusic() }
            } else {
                AppleMusicConnectButton(title: nowPlaying.appleMusicAccess == .denied ? "Allow Apple Music in Settings" : "Use Apple Music")
            }
            if let account = nowPlaying.lastfm.account {
                LabeledContent("Last.fm", value: account.username)
                Button("Disconnect Last.fm", role: .destructive) { confirmUnlinkLastfm = true }
                    .disabled(nowPlaying.lastfm.isWorking)
            } else if nowPlaying.linkedSources.lastfmUser != nil {
                usernameField("Last.fm", field: .lastfm, text: lastfmBinding)
            }
            if nowPlaying.linkedSources.listenbrainzUser != nil {
                usernameField("ListenBrainz", field: .listenbrainz, text: listenbrainzBinding)
            }
        } header: {
            Text("Where you listen")
        } footer: {
            if let failure = spotify.failure ?? nowPlaying.lastfm.failure {
                Text(failure)
                    .foregroundStyle(RN.Palette.rustText)
            }
        }
        .listRowBackground(RN.Palette.paper2)
    }

    // MARK: Identify

    private var identifySection: some View {
        @Bindable var nowPlaying = nowPlaying
        return Section {
            Toggle(isOn: $nowPlaying.autoIdentify) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify on its own")
                    Text("When you start a note, something is playing, and no source can say what, Resonote listens for a few seconds with Shazam.")
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                }
            }
            .tint(RN.Palette.rust)
        } header: {
            Text("Identify")
        } footer: {
            Text("This opens the microphone, so the orange dot appears while Resonote listens. Nothing is recorded or kept. Off, Identify waits for you to tap it.")
        }
        .listRowBackground(RN.Palette.paper2)
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
            shazamShortcutRow
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

    @ViewBuilder
    private var shazamShortcutRow: some View {
        let detail = "Recognizes the song with Shazam, even in headphones, and opens Resonote's Note a Song with it. Put it on the Action button (Settings → Action Button → Shortcut), or run it from a personal automation in Shortcuts, like when Spotify opens or your AirPods connect."
        if let link = ShazamShortcut.link {
            Link(destination: link) {
                HowToRow(title: "Add the Shazam → Note a Song shortcut", systemImage: "shazam.logo", detail: detail)
            }
        } else {
            HowToRow(
                title: "Shazam → Note a Song shortcut",
                systemImage: "shazam.logo",
                detail: "In Shortcuts, add Recognize Music, then Resonote's Note a Song with the song's title and artist. " + detail
            )
        }
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

/// Where people connect Spotify to the scrobblers Resonote reads.
enum SourceLinks {
    static let lastfmApplications = URL(string: "https://www.last.fm/settings/applications")!
    static let listenbrainzServices = URL(string: "https://listenbrainz.org/settings/music-services/details/")!
}

/// The shared "Shazam → Note a Song" shortcut (docs/IOS_NOW_PLAYING.md). To be filled
/// with the iCloud link (https://www.icloud.com/shortcuts/…) once the shortcut is
/// published from the owner's device; until then Settings explains how to build it.
enum ShazamShortcut {
    static let link: URL? = nil
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
