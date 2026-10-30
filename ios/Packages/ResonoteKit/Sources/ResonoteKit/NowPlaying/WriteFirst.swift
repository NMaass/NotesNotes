import Foundation

/// Write first, attach later (docs/IOS_NOW_PLAYING.md): a note saved with no song keeps
/// the moment it was begun, and the listen that turns out to cover that moment (a
/// scrobble arriving minutes later, a Journaling pick, Apple Music history) attaches
/// itself. The person can always change or detach it, and their choice is final.
public enum WriteFirst {
    /// The recent play that should attach to `note` now, or nil to leave it as it is.
    ///
    /// - Only written-first notes with a `writtenAt` qualify, and never one whose song
    ///   the person chose or detached (`Draft.Attachment.person`).
    /// - The play must cover `writtenAt` (`RecentPlayList.play(covering:in:)`: started by
    ///   then, give or take a minute, and still going); of several, the closest preceding
    ///   start wins. Undated plays never attach: nobody can say when they were.
    /// - An automatic attachment is replaced only by a play of a different song that now
    ///   covers the note better; the same song again changes nothing.
    public static func automaticPlay(for note: Draft, in plays: [RecentPlay]) -> RecentPlay? {
        guard note.isWrittenFirst, note.attachment != .person, let writtenAt = note.writtenAt,
              let play = RecentPlayList.play(covering: writtenAt, in: plays) else { return nil }
        if let attached = note.track, play.isSameSong(as: RecentPlay(track: attached)) { return nil }
        return play
    }
}
