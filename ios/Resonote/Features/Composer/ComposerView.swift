import ResonoteKit
import SwiftUI
import UIKit

/// The full journal composer, presented as a sheet. Port of the web's
/// src/components/journal/journal-editor.tsx: a prompt, an optional title, free
/// writing with `\` music references, lenses, reflections, and visibility.
///
/// Drafts are kept on this device the whole time: Cancel, swiping the sheet away, or
/// leaving the app never loses writing. Publishing is the only thing that clears a draft.
struct ComposerView: View {
    let context: ComposerContext

    @Environment(AppModel.self) private var model
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var session: ComposerSession?

    var body: some View {
        NavigationStack {
            if let session {
                ComposerForm(session: session)
            } else {
                RN.Palette.paper.ignoresSafeArea()
            }
        }
        .onAppear(perform: start)
    }

    /// Builds the session once. Later changes to the person's data never replace it.
    private func start() {
        guard session == nil else { return }
        let published = context.entryId.flatMap { model.entry(id: $0) }
        let created = ComposerSession(context: context, existing: published, store: model.drafts)
        created.fontContext = fontContext
        session = created
    }
}

/// The composer's content, toolbar, and keyboard accessories.
private struct ComposerForm: View {
    let session: ComposerSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: ComposerField?
    @State private var describing: ReferenceEditTarget?
    @State private var subjectLoadFailed = false
    @State private var subjectAttempt = 0

    private static let editorAnchor = "composer-editor"

    private var context: ComposerContext { session.context }

    private var subjectName: String? {
        model.catalog.entity(kind: context.entityKind, id: context.entityId)?.name
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: RN.Space.xl) {
                    ComposerHeader(kind: context.entityKind, name: subjectName, loadFailed: subjectLoadFailed) {
                        subjectLoadFailed = false
                        subjectAttempt += 1
                    }
                    ComposerDraftNotice(session: session)
                    ComposerPromptPanel(session: session)
                    ComposerTitleField(session: session, focus: $focus)
                    ComposerEditorSurface(session: session, subjectName: subjectName ?? "this \(context.entityKind.rawValue)", focus: $focus)
                        .id(Self.editorAnchor)
                    ComposerLinkedMusic(session: session) { describing = ReferenceEditTarget(id: $0) }
                    ComposerLensSection(session: session)
                    ComposerReflections(session: session, focus: $focus)
                    ComposerVisibility(session: session)
                    Text("Drafts stay on this device until you publish.")
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, RN.Space.gutter)
                .padding(.top, RN.Space.s)
                .padding(.bottom, RN.Space.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerSuggestionHost(session: session, isWriting: focus == .body)
            }
            .navigationTitle(session.isEditingPublishedEntry ? "Edit entry" : "New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(proxy: proxy) }
        }
        .sheet(item: $describing) { target in
            ReferenceConnectionSheet(session: session, referenceId: target.id)
        }
        .task(id: subjectAttempt) { await loadSubject() }
        .task { focusIfBlank() }
        // A widget or the Action button waits for the composer to close instead of replacing it.
        .holdsUnsavedInput(session.holdsWriting)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The share sheet may have added words to this draft while the app was away.
                session.absorbExternalDraftChanges()
            } else {
                session.saveDraftNow()
            }
        }
        .onDisappear { session.saveDraftNow() }
    }

    @ToolbarContentBuilder
    private func toolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                session.saveDraftNow()
                dismiss()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Publish") { publish(proxy: proxy) }
                .buttonStyle(.glassProminent)
        }
        ToolbarItemGroup(placement: .keyboard) {
            if focus == .body {
                Button {
                    session.beginReference()
                } label: {
                    Label("Link music", systemImage: "music.note")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityHint("Starts a link to a song, album, artist, or genre at the cursor.")
            }
            Spacer()
            Button("Done") { focus = nil }
        }
    }

    // MARK: Actions

    private func publish(proxy: ScrollViewProxy) {
        if session.hasPublished {
            dismiss()
            return
        }
        guard session.validateForPublish() else {
            showPublishError(proxy: proxy)
            return
        }
        model.requireAuth { commitPublish() }
    }

    /// Runs now when signed in, or once the sign-in sheet has gone, so the person never re-taps Publish.
    private func commitPublish() {
        guard !session.hasPublished, let profile = model.profile else { return }
        let published = context.entryId.flatMap { model.entry(id: $0) }
        guard let entry = session.makeEntry(profileId: profile.id, published: published) else {
            AccessibilityNotification.Announcement(ComposerSession.emptyMessage).post()
            return
        }
        model.save(entry)
        session.finishPublishing()
        // The draft goes only once the entry is safely in the durable sync queue.
        let model = model
        let session = session
        Task {
            await model.writesAreQueued()
            session.releaseDraftAfterPublishing()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AccessibilityNotification.Announcement("Journal entry saved").post()
        dismiss()
    }

    private func showPublishError(proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : RN.Motion.settle) {
            proxy.scrollTo(Self.editorAnchor, anchor: .top)
        }
        focus = .body
        AccessibilityNotification.Announcement(ComposerSession.emptyMessage).post()
    }

    private func focusIfBlank() {
        guard !session.isEditingPublishedEntry, session.text.characters.isEmpty else { return }
        focus = .body
    }

    private func loadSubject() async {
        guard model.catalog.entity(kind: context.entityKind, id: context.entityId) == nil else { return }
        // Shares the entity page cache, so opening the composer from a page costs nothing.
        let found = await model.ensureEntity(kind: context.entityKind, id: context.entityId)
        guard !Task.isCancelled else { return }
        subjectLoadFailed = found == nil
    }
}

/// Shows the suggestion strip only while a `\` reference is being typed in the editor.
/// Kept separate so typing a query re-renders this strip and not the whole form.
private struct ComposerSuggestionHost: View {
    let session: ComposerSession
    let isWriting: Bool

    var body: some View {
        if isWriting, let trigger = session.trigger {
            ReferenceSuggestionBar(session: session, query: trigger.query)
        }
    }
}
