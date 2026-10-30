import ResonoteKit
import SwiftUI

/// Everything the composer is editing, plus the rules that keep it safe: references
/// stay whole, the draft autosaves shortly after each change, and nothing outside the
/// composer ever replaces what the person is writing.
///
/// Views read only the properties they show, so a keystroke re-renders the editor and
/// nothing else.
@Observable
final class ComposerSession {
    let context: ComposerContext

    // MARK: Fields the person edits

    var text: AttributedString {
        didSet { if text != oldValue { markEdited() } }
    }
    var selection = AttributedTextSelection()
    var title: String {
        didSet { if title != oldValue { markEdited() } }
    }
    var lenses: [MusicLens] {
        didSet { if lenses != oldValue { markEdited() } }
    }
    var worked: String {
        didSet { if worked != oldValue { markEdited() } }
    }
    var didntWork: String {
        didSet { if didntWork != oldValue { markEdited() } }
    }
    var isPublic: Bool {
        didSet { if isPublic != oldValue { markEdited() } }
    }
    var showsWorked: Bool
    var showsDidntWork: Bool
    var promptIndex = 1

    // MARK: Derived from the text

    /// References in document order. Assigned only when they change.
    private(set) var references: [MusicReference] = []
    /// The `\query` before the caret, while the person is typing a reference.
    private(set) var trigger: RichTextCodec.Trigger?

    // MARK: Status

    /// The source document had headings, lists, or quotes that this editor shows as paragraphs.
    private(set) var flattensStructure: Bool
    /// The composer opened from a saved draft rather than the entry or a blank page.
    private(set) var restoredDraft: Bool
    var publishError: String?
    /// Whether there is writing a request from outside (a widget, the Action button)
    /// mustn't close. Assigned only when it flips, so typing doesn't redraw its readers.
    private(set) var holdsWriting = false

    /// Used to read bold and italic back out of the editor's fonts.
    @ObservationIgnored var fontContext: Font.Context?
    @ObservationIgnored private let existing: JournalEntry?
    @ObservationIgnored private let store: DraftStore
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var savedRevision = 0
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// Set once the entry is saved; the draft is gone and Publish only closes the sheet.
    @ObservationIgnored private(set) var hasPublished = false
    /// A new entry's id, fixed for the session so publishing twice can only update one entry.
    @ObservationIgnored private let newEntryId = Identifiers.make()
    /// When the draft file was last read or written by this session. A newer file means
    /// another process (the share sheet) added words, which are merged in, never overwritten.
    @ObservationIgnored private var draftStamp: Date?

    static let boldFont = RN.Typography.prose.bold()
    static let italicFont = RN.Typography.prose.italic()

    /// - Parameter existing: the published entry when editing, so a missing draft can start from it.
    /// - Parameter store: the signed-in person's drafts (`AppModel.drafts`).
    init(context: ComposerContext, existing: JournalEntry?, store: DraftStore) {
        self.context = context
        self.existing = existing
        self.store = store

        let start = Self.startingPoint(context: context, existing: existing, store: store)
        text = start.text
        title = start.title
        lenses = start.lenses
        worked = start.worked
        didntWork = start.didntWork
        isPublic = start.isPublic
        showsWorked = !start.worked.isEmpty
        showsDidntWork = !start.didntWork.isEmpty
        flattensStructure = start.flattensStructure
        restoredDraft = start.fromDraft
        references = RichTextCodec.references(in: start.text)
        selection = AttributedTextSelection(insertionPoint: start.text.endIndex)
        draftStamp = start.draftUpdatedAt
        // Words carried in from capture are a change worth keeping right away: Cancel or a
        // swipe-down right after "Open full editor" still leaves them in a draft.
        if start.needsSave { markEdited() }
        holdsWriting = !isBlank
    }

    var isEditingPublishedEntry: Bool { context.entryId != nil }

    // MARK: Starting point

    private struct StartingPoint {
        var text = AttributedString()
        var title = ""
        var lenses: [MusicLens] = []
        var worked = ""
        var didntWork = ""
        /// Private first: a new entry is only the writer's until they choose to publish.
        var isPublic = false
        var flattensStructure = false
        var fromDraft = false
        var needsSave = false
        var draftUpdatedAt: Date?
    }

    /// The saved draft wins; otherwise the entry being edited; otherwise the capture seed.
    private static func startingPoint(context: ComposerContext, existing: JournalEntry?, store: DraftStore) -> StartingPoint {
        var start = StartingPoint()
        if let draft = store.load(key: context.id) {
            start.text = RichTextCodec.editableText(from: draft.document, bold: boldFont, italic: italicFont)
            start.title = draft.title
            start.lenses = draft.lenses
            start.worked = draft.worked
            start.didntWork = draft.didntWork
            start.isPublic = draft.isPublic
            start.flattensStructure = draft.document.hasBlocksBeyondParagraphs
            start.fromDraft = true
            start.draftUpdatedAt = draft.updatedAt
            // A capture handed over new words: add them after the draft rather than drop either.
            if let seed = context.seed {
                // A seed never widens who can read it.
                if !seed.isPublic, start.isPublic {
                    start.isPublic = false
                    start.needsSave = true
                }
                let seedText = seed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let draftText = String(start.text.characters)
                if !seedText.isEmpty, !draftText.contains(seedText) {
                    if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        start.text.append(AttributedString("\n"))
                    }
                    start.text.append(AttributedString(seedText))
                    start.needsSave = true
                }
                for lens in seed.lenses where !start.lenses.contains(lens) {
                    start.lenses.append(lens)
                    start.needsSave = true
                }
            }
        } else if let existing {
            start.text = RichTextCodec.editableText(from: existing.document, bold: boldFont, italic: italicFont)
            start.title = existing.title ?? ""
            start.lenses = existing.lenses
            start.worked = existing.worked ?? ""
            start.didntWork = existing.didntWork ?? ""
            start.isPublic = existing.isPublic
            start.flattensStructure = existing.document.hasBlocksBeyondParagraphs
        } else if let seed = context.seed {
            let words = seed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            start.text = AttributedString(words)
            start.lenses = seed.lenses
            start.isPublic = seed.isPublic
            start.needsSave = !words.isEmpty || !seed.lenses.isEmpty
        }
        return start
    }

    // MARK: Editing

    /// Call after the editor changes the text: keeps references whole and refreshes what depends on them.
    func textDidChange() {
        var updated = text
        var caret = selection
        if RichTextCodec.enforceAtomicReferences(in: &updated, selection: &caret) {
            text = updated
            selection = caret
        }
        let found = RichTextCodec.references(in: text)
        if found != references { references = found }
        refreshTrigger()
    }

    func selectionDidChange() {
        refreshTrigger()
    }

    private func refreshTrigger() {
        let current = RichTextCodec.activeTrigger(in: text, selection: selection)
        if current != trigger { trigger = current }
    }

    /// Starts a reference at the caret, as if the person typed `\`. A short selection
    /// on one line becomes the search, so "select a name, tap Link music" works too.
    func beginReference() {
        var updated = text
        var caret = selection
        if case .ranges(let ranges) = caret.indices(in: updated),
           ranges.ranges.count == 1,
           let range = ranges.ranges.first {
            let selected = String(updated.characters[range])
            let hasReference = updated[range].runs[\.musicRef].contains { $0.0 != nil }
            if !selected.isEmpty, selected.count <= 60, !selected.contains(where: \.isNewline), !hasReference {
                var start = AttributedTextSelection(insertionPoint: range.lowerBound)
                updated.replaceSelection(&start, withCharacters: "\\")
                if case .insertionPoint(let afterSlash) = start.indices(in: updated) {
                    let end = updated.characters.index(afterSlash, offsetBy: selected.count, limitedBy: updated.endIndex) ?? updated.endIndex
                    caret = AttributedTextSelection(insertionPoint: end)
                } else {
                    caret = start
                }
                text = updated
                selection = caret
                textDidChange()
                return
            }
            caret = AttributedTextSelection(insertionPoint: range.upperBound)
        }
        updated.replaceSelection(&caret, withCharacters: "\\")
        text = updated
        selection = caret
        textDidChange()
    }

    /// Replaces the active `\query` with a reference to `entity`.
    @discardableResult
    func insertReference(to entity: CatalogEntity) -> Bool {
        guard let active = RichTextCodec.activeTrigger(in: text, selection: selection) else { return false }
        var updated = text
        var caret = selection
        let value = MusicRefValue(entityId: entity.id, label: entity.name, entityKind: entity.kind)
        RichTextCodec.insert(value, replacing: active.range, in: &updated, selection: &caret)
        Self.dropDoubledSpace(in: &updated, caret: &caret)
        text = updated
        selection = caret
        textDidChange()
        return true
    }

    /// The codec always follows a new reference with a space. When whitespace already
    /// comes next (a reference made from a selected word), keep just one.
    private static func dropDoubledSpace(in text: inout AttributedString, caret: inout AttributedTextSelection) {
        guard case .insertionPoint(let index) = caret.indices(in: text),
              index > text.startIndex, index < text.endIndex,
              text.characters[index].isWhitespace else { return }
        let space = text.characters.index(before: index)
        guard text.characters[space] == " ", text[space..<index].musicRef == nil else { return }
        text.transform(updating: &caret) { text in
            text.removeSubrange(space..<index)
        }
    }

    func reference(id: String) -> MusicReference? {
        references.first { $0.id == id }
    }

    func setRelation(_ relation: RelationKind, for referenceId: String) {
        updateReference(referenceId, relation: relation, lenses: nil)
    }

    func toggleLens(_ lens: MusicLens, for referenceId: String) {
        guard let current = reference(id: referenceId) else { return }
        let next = current.lenses.contains(lens) ? current.lenses.filter { $0 != lens } : current.lenses + [lens]
        updateReference(referenceId, relation: nil, lenses: next)
    }

    private func updateReference(_ referenceId: String, relation: RelationKind?, lenses: [MusicLens]?) {
        var updated = text
        var caret = selection
        updated.transform(updating: &caret) { text in
            RichTextCodec.updateReference(referenceId, relation: relation, lenses: lenses, in: &text)
        }
        text = updated
        selection = caret
        textDidChange()
    }

    func toggleEntryLens(_ lens: MusicLens) {
        if lenses.contains(lens) {
            lenses.removeAll { $0 == lens }
        } else {
            lenses.append(lens)
        }
    }

    func nextPrompt() {
        promptIndex = (promptIndex + 1) % Vocabulary.prompts.count
    }

    // MARK: Drafts

    private func markEdited() {
        guard !hasPublished else { return }
        let writing = !isBlank
        if writing != holdsWriting { holdsWriting = writing }
        revision &+= 1
        if publishError != nil { publishError = nil }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    /// Writes the draft if anything changed since the last save, first taking in words
    /// another process added to it. Safe to call often.
    func saveDraftNow() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard !hasPublished else { return }
        absorbExternalDraftChanges()
        guard revision != savedRevision else { return }
        if !isEditingPublishedEntry, isBlank {
            store.delete(key: context.id)
            draftStamp = nil
        } else {
            let draft = makeDraft()
            store.save(draft)
            draftStamp = draft.updatedAt
        }
        savedRevision = revision
    }

    /// Merges words the share sheet (or a match of an unmatched note) added to this draft
    /// since the session last read or wrote it. Added paragraphs go after the person's
    /// text; nothing they wrote is replaced, and the visibility they chose stays.
    func absorbExternalDraftChanges() {
        guard !hasPublished, let onDisk = store.load(key: context.id),
              onDisk.updatedAt > (draftStamp ?? .distantPast) else { return }
        draftStamp = onDisk.updatedAt
        let current = String(text.characters)
        let additions = onDisk.document.content.filter { node in
            let words = RichDocument(content: [node]).plainText
            return !words.isEmpty && !current.contains(words)
        }
        let newLenses = onDisk.lenses.filter { !lenses.contains($0) }
        guard !additions.isEmpty || !newLenses.isEmpty else { return }
        if !additions.isEmpty {
            let added = RichTextCodec.editableText(from: RichDocument(content: additions), bold: Self.boldFont, italic: Self.italicFont)
            var updated = text
            var caret = selection
            updated.transform(updating: &caret) { text in
                if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text.append(AttributedString("\n"))
                }
                text.append(added)
            }
            text = updated
            selection = caret
            textDidChange()
        }
        if !newLenses.isEmpty { lenses += newLenses }
    }

    /// Throws away the saved draft and starts again from the entry, the seed, or a blank page.
    func discardDraft() {
        autosaveTask?.cancel()
        autosaveTask = nil
        store.delete(key: context.id)
        let start = Self.startingPoint(context: context, existing: existing, store: store)
        text = start.text
        selection = AttributedTextSelection(insertionPoint: start.text.endIndex)
        title = start.title
        lenses = start.lenses
        worked = start.worked
        didntWork = start.didntWork
        isPublic = start.isPublic
        showsWorked = !start.worked.isEmpty
        showsDidntWork = !start.didntWork.isEmpty
        flattensStructure = start.flattensStructure
        restoredDraft = false
        publishError = nil
        textDidChange()
        // Resetting is not an edit: nothing to save until the person writes again.
        autosaveTask?.cancel()
        autosaveTask = nil
        savedRevision = revision
    }

    private var isBlank: Bool {
        String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && worked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && didntWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && lenses.isEmpty
    }

    private func makeDraft() -> Draft {
        Draft(
            entityId: context.entityId,
            entityKind: context.entityKind,
            entryId: context.entryId,
            title: title,
            document: RichTextCodec.document(from: text, fontContext: fontContext),
            lenses: lenses,
            worked: worked,
            didntWork: didntWork,
            isPublic: isPublic,
            updatedAt: Date()
        )
    }

    // MARK: Publishing

    static let emptyMessage = "Write at least one thought first."

    /// Whether there is writing to publish; sets `publishError` when there is not.
    func validateForPublish() -> Bool {
        let hasWriting = !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        publishError = hasWriting ? nil : Self.emptyMessage
        return hasWriting
    }

    /// The entry to save, or nil when there is nothing to publish.
    func makeEntry(profileId: String, published: JournalEntry?) -> JournalEntry? {
        let document = RichTextCodec.document(from: text, fontContext: fontContext)
        let plainText = document.plainText
        guard !plainText.isEmpty else {
            publishError = Self.emptyMessage
            return nil
        }
        let now = ResonoteDate.now()
        return JournalEntry(
            id: context.entryId ?? newEntryId,
            profileId: profileId,
            entityId: context.entityId,
            entityKind: context.entityKind,
            title: Self.trimmedOrNil(title),
            document: document,
            plainText: plainText,
            worked: Self.trimmedOrNil(worked),
            didntWork: Self.trimmedOrNil(didntWork),
            lenses: lenses,
            references: document.references,
            isPublic: isPublic,
            createdAt: published?.createdAt ?? existing?.createdAt ?? now,
            updatedAt: now
        )
    }

    /// The entry is saved locally: stop autosaving. The draft stays until the write is
    /// safely in the sync queue (`releaseDraftAfterPublishing`), so a kill in between can't lose the words.
    func finishPublishing() {
        hasPublished = true
        holdsWriting = false
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// The published entry is in the durable sync queue: the draft has done its job.
    func releaseDraftAfterPublishing() {
        guard hasPublished else { return }
        store.delete(key: context.id)
    }

    private static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
