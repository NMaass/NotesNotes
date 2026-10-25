import ResonoteKit
import SwiftUI

extension AppModel {
    /// Tells Resonote that an entry or a profile breaks the rules, and says so quietly.
    func report(_ targetType: ReportRequest.TargetType, id: String, reason: ReportReason) {
        let api = api
        Task {
            do {
                try await api.report(ReportRequest(targetType: targetType, targetId: id, reason: reason))
                syncNotice = "Reported. Thank you for telling us."
            } catch {
                syncNotice = "The report didn't send. Try again in a moment."
            }
        }
    }
}

extension View {
    /// Report and Block for someone else's writing: in the context menu, as VoiceOver
    /// actions, and with a confirmation before blocking. Does nothing for the person's
    /// own writing, or while signed out.
    func moderationActions(entry: JournalEntry, author: Profile?) -> some View {
        modifier(EntryModeration(entry: entry, author: author))
    }
}

private struct EntryModeration: ViewModifier {
    let entry: JournalEntry
    let author: Profile?

    @Environment(AppModel.self) private var model
    @State private var confirmsBlock = false
    @State private var choosesReason = false

    private var canModerate: Bool {
        guard let mine = model.profile?.id else { return false }
        return entry.profileId != mine && !entry.profileId.isEmpty
    }

    func body(content: Content) -> some View {
        if canModerate {
            content
                .contextMenu {
                    ReportMenu { reason in model.report(.entry, id: entry.id, reason: reason) }
                    if let author {
                        Button("Block @\(author.handle)", systemImage: "hand.raised", role: .destructive) {
                            confirmsBlock = true
                        }
                    }
                }
                .accessibilityAction(named: "Report") { choosesReason = true }
                .accessibilityAction(named: author.map { "Block @\($0.handle)" } ?? "Block") {
                    if author != nil { confirmsBlock = true }
                }
                .reportReasonDialog(isPresented: $choosesReason) { reason in
                    model.report(.entry, id: entry.id, reason: reason)
                }
                .blockConfirmation(isPresented: $confirmsBlock, profile: author)
        } else {
            content
        }
    }
}

/// "Report" with the reasons a person can choose from.
struct ReportMenu: View {
    let onReport: (ReportReason) -> Void

    var body: some View {
        Menu {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label) { onReport(reason) }
            }
        } label: {
            Label("Report", systemImage: "flag")
        }
    }
}

extension View {
    /// "Why are you reporting this?" with the reasons, for VoiceOver and toolbar menus.
    func reportReasonDialog(isPresented: Binding<Bool>, onReport: @escaping (ReportReason) -> Void) -> some View {
        confirmationDialog("Why are you reporting this?", isPresented: isPresented, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label) { onReport(reason) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reports go to the people who run Resonote.")
        }
    }

    /// Asks before blocking: what it does, and that it can be undone in Settings.
    func blockConfirmation(isPresented: Binding<Bool>, profile: Profile?) -> some View {
        modifier(BlockConfirmation(isPresented: isPresented, profile: profile))
    }
}

private struct BlockConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let profile: Profile?

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            profile.map { "Block @\($0.handle)?" } ?? "Block this person?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                if let profile { model.block(profile) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their writing anywhere in Resonote. You can unblock them in Settings.")
        }
    }
}

/// In place of someone's writing or page after the person blocked them.
struct BlockedNotice: View {
    let profile: Profile

    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(
            title: "You blocked @\(profile.handle)",
            message: "Their writing is hidden from you everywhere in Resonote.",
            actionTitle: "Unblock",
            action: { model.unblock(profile.id) }
        )
    }
}
