import Foundation
import Testing
@testable import ResonoteKit

@Suite struct WriteFirstMatchingTests {
    let now = ResonoteDate.parse("2026-10-29T12:00:00.000Z")!

    private func play(_ title: String, minutesAgo: Double?, playing: Bool = false, durationMs: Int? = nil, source: RecentPlay.Source = .lastfm) -> RecentPlay {
        RecentPlay(title: title, artist: "Radiohead", playedAt: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, source: source, isPlaying: playing, durationMs: durationMs)
    }

    private func note(writtenMinutesAgo: Double, track: NowPlayingTrack? = nil, attachment: Draft.Attachment? = nil) -> Draft {
        Draft(entityId: "", entityKind: .song, track: track, document: .plain("Strings swell."), noteId: "n1", writtenAt: now.addingTimeInterval(-writtenMinutesAgo * 60), attachment: attachment)
    }

    @Test func noCandidatesLeavesTheNoteWaiting() {
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 5), in: []) == nil)
        // Only undated history: nobody can say what played when the note was written.
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 5), in: [play("Nude", minutesAgo: nil, source: .appleMusicRecent)]) == nil)
        // Plays from well before and after the note don't cover it.
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 30), in: [play("Nude", minutesAgo: 60), play("Reckoner", minutesAgo: 5)]) == nil)
    }

    @Test func windowEdges() {
        // A 4-minute song (the assumed length) that started 10 minutes ago covers 6.5 minutes
        // ago: its end plus a minute's grace.
        let nude = [play("Nude", minutesAgo: 10)]
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 10), in: nude)?.title == "Nude")
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 5.1), in: nude)?.title == "Nude")
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 4.9), in: nude) == nil)
        // Started up to a minute after the note was begun still counts; later doesn't.
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 10.9), in: nude)?.title == "Nude")
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 11.1), in: nude) == nil)
        // A known duration sets the end instead of the assumed length.
        let long = [play("Bodysnatchers", minutesAgo: 20, durationMs: 15 * 60 * 1000)]
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 7), in: long)?.title == "Bodysnatchers")
    }

    @Test func closestPrecedingPlayWinsAmongSeveral() {
        // Both cover the note (a long track still going, and the next song a minute in).
        let plays = [play("Long", minutesAgo: 12, durationMs: 20 * 60 * 1000), play("Nude", minutesAgo: 6), play("Later", minutesAgo: 1)]
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 5), in: plays)?.title == "Nude")
    }

    @Test func aPlayingRowCoversUntilItsClaimEnds() {
        let playing = [play("Reckoner", minutesAgo: 2, playing: true, source: .musicApp)]
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 1), in: playing)?.title == "Reckoner")
    }

    @Test func thePersonsChoiceIsNeverOverridden() {
        let plays = [play("Nude", minutesAgo: 6)]
        let chosen = NowPlayingTrack(title: "Reckoner", artist: "Radiohead", source: .manual, isPlaying: false)
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 5, track: chosen, attachment: .person), in: plays) == nil)
        // Detached by the person: stays songless.
        #expect(WriteFirst.automaticPlay(for: note(writtenMinutesAgo: 5, attachment: .person), in: plays) == nil)
    }

    @Test func automaticAttachmentsMoveOnlyToADifferentSong() {
        let nude = play("Nude", minutesAgo: 6)
        let same = note(writtenMinutesAgo: 5, track: nude.track(now: now), attachment: .automatic)
        #expect(WriteFirst.automaticPlay(for: same, in: [nude]) == nil)
        let wrong = note(writtenMinutesAgo: 5, track: play("Videotape", minutesAgo: 40).track(now: now), attachment: .automatic)
        #expect(WriteFirst.automaticPlay(for: wrong, in: [nude])?.title == "Nude")
    }

    @Test func onlyWrittenFirstNotesAttach() {
        var ordinary = note(writtenMinutesAgo: 5)
        ordinary.noteId = nil
        #expect(WriteFirst.automaticPlay(for: ordinary, in: [play("Nude", minutesAgo: 6)]) == nil)
    }
}

@Suite struct WriteFirstDraftStoreTests {
    let now = Date()

    private func store() -> DraftStore {
        DraftStore(directory: FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)", directoryHint: .isDirectory), owner: "p1")
    }

    private func play(_ title: String, minutesAgo: Double) -> RecentPlay {
        RecentPlay(title: title, artist: "Radiohead", playedAt: now.addingTimeInterval(-minutesAgo * 60), source: .lastfm)
    }

    @Test func savedNoteWaitsThenAttachesTheCoveringListen() throws {
        let drafts = store()
        let saved = try #require(drafts.saveNote(" Strings swell. ", lenses: [.feeling], isPublic: false, writtenAt: now.addingTimeInterval(-5 * 60)))
        #expect(saved.isWaitingForSong)
        #expect(saved.key.hasPrefix("note-"))
        #expect(drafts.saveNote("   ", lenses: [], isPublic: false, writtenAt: now) == nil)

        // Nothing covers it yet.
        #expect(drafts.attachCoveringPlays([play("Videotape", minutesAgo: 40)]).isEmpty)
        #expect(try #require(drafts.load(key: saved.key)).isWaitingForSong)

        let changed = drafts.attachCoveringPlays([play("Nude", minutesAgo: 6), play("Videotape", minutesAgo: 40)])
        #expect(changed.map(\.track?.title) == ["Nude"])
        let attached = try #require(drafts.load(key: saved.key))
        #expect(attached.attachment == .automatic)
        #expect(attached.writtenAt == saved.writtenAt)
        #expect(attached.document.plainText == "Strings swell.")
        #expect(attached.isUnmatched == false)
        // Same evidence again: nothing to change.
        #expect(drafts.attachCoveringPlays([play("Nude", minutesAgo: 6)]).isEmpty)
    }

    @Test func personChangesAndDetachesAndAutomaticNeverReturns() throws {
        let drafts = store()
        let saved = try #require(drafts.saveNote("Strings swell.", lenses: [], isPublic: false, writtenAt: now.addingTimeInterval(-5 * 60)))
        drafts.attachCoveringPlays([play("Nude", minutesAgo: 6)])

        let chosen = NowPlayingTrack(title: "Reckoner", artist: "Radiohead", source: .manual, isPlaying: false)
        #expect(drafts.setNoteTrack(chosen, forKey: saved.key)?.attachment == .person)
        drafts.attachCoveringPlays([play("Nude", minutesAgo: 6)])
        #expect(try #require(drafts.load(key: saved.key)).track?.title == "Reckoner")

        drafts.setNoteTrack(nil, forKey: saved.key)
        drafts.attachCoveringPlays([play("Nude", minutesAgo: 6)])
        let detached = try #require(drafts.load(key: saved.key))
        #expect(detached.track == nil)
        #expect(detached.attachment == .person)
    }

    @Test func matchingTheAttachedTrackKeepsTheNoteItsOwn() throws {
        let drafts = store()
        let saved = try #require(drafts.saveNote("Strings swell.", lenses: [], isPublic: false, writtenAt: now.addingTimeInterval(-5 * 60)))
        let note = try #require(drafts.attachCoveringPlays([play("Nude", minutesAgo: 6)]).first)
        let track = try #require(note.track)
        #expect(drafts.attachUnmatched(track, toSong: "s1"))
        let matched = try #require(drafts.load(key: saved.key))
        #expect(matched.entityId == "s1")
        #expect(matched.key == saved.key)
        #expect(drafts.load(key: Draft.key(kind: .song, entityId: "s1", entryId: nil)) == nil)
    }

    @Test func olderDraftFilesDecodeWithoutTheNewFields() throws {
        let json = #"{"entityId":"s1","entityKind":"song","title":"","document":{"type":"doc","content":[]},"lenses":[],"worked":"","didntWork":"","isPublic":false,"updatedAt":0}"#
        let draft = try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
        #expect(draft.noteId == nil)
        #expect(draft.writtenAt == nil)
        #expect(draft.attachment == nil)
        #expect(draft.isWrittenFirst == false)
        #expect(draft.key == Draft.key(kind: .song, entityId: "s1", entryId: nil))
    }
}
