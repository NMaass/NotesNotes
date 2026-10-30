import Foundation
import Testing
@testable import ResonoteKit

@Suite struct PublishedFlagTests {
    private func entry(_ visibility: String) throws -> JournalEntry {
        let json = #"{"id":"e1","profileId":"p1","entityId":"s1","entityKind":"song","plainText":"Hi",\#(visibility)"createdAt":"2026-10-29T12:00:00.000Z"}"#
        return try JSONDecoder().decode(JournalEntry.self, from: Data(json.utf8))
    }

    @Test func entryReadsPublishedThenLegacyPublicThenPrivate() throws {
        #expect(try entry(#""published":true,"#).isPublic)
        #expect(try entry(#""published":false,"public":true,"#).isPublic == false)
        #expect(try entry(#""public":true,"#).isPublic)
        #expect(try entry("").isPublic == false)
    }

    @Test func entryWritesPublishedAndLegacyPublic() throws {
        var entry = try entry("")
        entry.isPublic = true
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncOperation.entry(entry))) as? [String: Any]
        let sent = object?["entry"] as? [String: Any]
        #expect(sent?["published"] as? Bool == true)
        #expect(sent?["public"] as? Bool == true)
        #expect(try JSONDecoder().decode(JournalEntry.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test func newEntriesAndDraftsArePrivate() {
        let entry = JournalEntry(id: "e", profileId: "p", entityId: "s", entityKind: .song, document: .empty, plainText: "", createdAt: "", updatedAt: "")
        #expect(entry.isPublic == false)
        #expect(Draft(entityId: "s", entityKind: .song).isPublic == false)
    }

    @Test func collectionReadsAndWritesPublished() throws {
        let legacy = try JSONDecoder().decode(MusicCollection.self, from: Data(#"{"id":"c","name":"Night","public":true,"items":[]}"#.utf8))
        #expect(legacy.isPublic)
        let missing = try JSONDecoder().decode(MusicCollection.self, from: Data(#"{"id":"c","name":"Night"}"#.utf8))
        #expect(missing.isPublic == false)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        #expect(object?["published"] as? Bool == true)
        #expect(object?["public"] as? Bool == true)
    }

    @Test func publicBundleWithoutLikesOrListensDecodes() throws {
        let json = #"{"profile":{"id":"p","handle":"maya","displayName":"Maya"},"entries":[{"id":"e","entityId":"s","published":true}],"collections":[],"pins":[],"genreAssertions":[],"catalog":{"genres":[]}}"#
        let bundle = try JSONDecoder().decode(ProfileBundle.self, from: Data(json.utf8))
        #expect(bundle.likes.isEmpty)
        #expect(bundle.listens.isEmpty)
        #expect(bundle.entries.first?.isPublic == true)
    }
}

@Suite struct NowPlayingContractTests {
    @Test func decodesRecentList() throws {
        let json = """
        {"ok":true,"track":{"title":"Weird Fishes/Arpeggi","artist":"Radiohead","source":"lastfm","isPlaying":true,"observedAt":"2026-10-29T12:00:00.000Z"},
         "recent":[
           {"title":"Weird Fishes/Arpeggi","artist":"Radiohead","source":"lastfm","isPlaying":true,"observedAt":"2026-10-29T12:00:00.000Z"},
           {"title":"Nude","artist":"Radiohead","album":"In Rainbows","source":"listenbrainz","isPlaying":false,"observedAt":"2026-10-29T11:55:00.000Z","isrc":"GBSTK0700002"},
           {"title":"Broken","source":"lastfm"}
         ],
         "services":[{"service":"lastfm","status":"ok"},{"service":"listenbrainz","status":"not-configured"},{"service":"x","status":"weird"}]}
        """
        let response = try JSONDecoder().decode(RemoteNowPlayingResponse.self, from: Data(json.utf8))
        #expect(response.recent.count == 2)
        #expect(response.services.map(\.status) == [.ok, .notConfigured])
        let plays = response.recentPlays
        #expect(plays.map(\.source) == [.lastfm, .listenbrainz])
        #expect(plays[1].isrc == "GBSTK0700002")
        #expect(plays[1].playedAt == ResonoteDate.parse("2026-10-29T11:55:00.000Z"))
    }

    @Test func olderServerWithoutRecentFallsBackToTrack() throws {
        let json = #"{"ok":true,"track":{"title":"Nude","artist":"Radiohead","source":"listenbrainz","isPlaying":false,"observedAt":"2026-10-29T11:55:00.000Z"}}"#
        let response = try JSONDecoder().decode(RemoteNowPlayingResponse.self, from: Data(json.utf8))
        #expect(response.recent.isEmpty)
        #expect(response.services.isEmpty)
        #expect(response.recentPlays.map(\.title) == ["Nude"])
    }

    @Test func decodesLastfmAccountShapes() throws {
        let linked = try JSONDecoder().decode(LastfmAccountResponse.self, from: Data(#"{"ok":true,"configured":true,"account":{"username":"maya","linkedAt":"2026-10-29T12:00:00.000Z"}}"#.utf8))
        #expect(linked.configured)
        #expect(linked.account?.username == "maya")
        let none = try JSONDecoder().decode(LastfmAccountResponse.self, from: Data(#"{"ok":true,"configured":false,"account":null}"#.utf8))
        #expect(none.account == nil)
        let auth = try JSONDecoder().decode(LastfmAuthURLResponse.self, from: Data(#"{"ok":true,"url":"https://www.last.fm/api/auth/?api_key=k&cb=resonote%3A%2F%2Flastfm-auth"}"#.utf8))
        #expect(auth.callbackScheme == "resonote")
        let link = try JSONDecoder().decode(LastfmLinkResponse.self, from: Data(#"{"ok":true,"account":{"username":"maya","linkedAt":"2026-10-29T12:00:00.000Z"}}"#.utf8))
        #expect(link.account.username == "maya")
    }

    @Test func readsWebAuthCallbackToken() {
        let token = String(repeating: "a1B2", count: 8)
        #expect(LastfmAuth.token(fromCallback: URL(string: "resonote://lastfm-auth?token=\(token)")!) == token)
        #expect(LastfmAuth.token(fromCallback: URL(string: "resonote://lastfm-auth?token=short")!) == nil)
        #expect(LastfmAuth.token(fromCallback: URL(string: "resonote://capture?token=\(token)")!) == nil)
        #expect(DeepLink(url: LastfmAuth.callbackURL) == nil)
    }

    @Test func linkedSourcesDecodeWithoutLastfmLinked() throws {
        let sources = try JSONDecoder().decode(LinkedSources.self, from: Data(#"{"lastfmUser":"maya","appleMusicEnabled":true,"spotifyConnected":false}"#.utf8))
        #expect(sources.lastfmLinked == false)
        #expect(sources.hasRemote)
        #expect(LinkedSources(lastfmLinked: true).hasRemote)
    }

    @Test func linkingLastfmSetsATypedUsernameAsideAndUnlinkingRestoresIt() {
        let typed = LinkedSources(lastfmUser: "bob")
        let linked = typed.withLastfmLink(true, username: "bob_scrobbles")
        #expect(linked.lastfmUser == "bob_scrobbles" && linked.lastfmLinked && linked.lastfmTypedUser == "bob")
        // A repeated link report keeps the typed name aside, not the linked one.
        let relinked = linked.withLastfmLink(true, username: "bob_scrobbles")
        #expect(relinked.lastfmTypedUser == "bob")
        let unlinked = relinked.withLastfmLink(false, username: nil)
        #expect(unlinked == typed)
        // Never linked: an unlink report leaves a typed name alone.
        #expect(typed.withLastfmLink(false, username: nil) == typed)
        #expect(LinkedSources().withLastfmLink(true, username: "alice").withLastfmLink(false, username: nil) == LinkedSources())
    }
}

@Suite struct RecentPlayRankingTests {
    let now = ResonoteDate.parse("2026-10-29T12:00:00.000Z")!

    private func play(_ title: String, minutesAgo: Double?, source: RecentPlay.Source = .lastfm, playing: Bool = false, isrc: String? = nil, album: String? = nil) -> RecentPlay {
        RecentPlay(title: title, artist: "Radiohead", album: album, playedAt: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, source: source, isPlaying: playing, isrc: isrc)
    }

    @Test func playingBeatsRecentAndNewerBeatsOlder() {
        let list = RecentPlayList.rank([play("Nude", minutesAgo: 3), play("Reckoner", minutesAgo: 1, source: .musicApp, playing: true), play("Bodysnatchers", minutesAgo: 9)], now: now)
        #expect(list.plays.map(\.title) == ["Reckoner", "Nude", "Bodysnatchers"])
        #expect(list.preselected?.title == "Reckoner")

        let history = RecentPlayList.rank([play("Bodysnatchers", minutesAgo: 9), play("Nude", minutesAgo: 3)], now: now)
        #expect(history.plays.map(\.title) == ["Nude", "Bodysnatchers"])
        #expect(history.preselected?.title == "Nude")
    }

    @Test func liveSourceOnlyPromotesOneRow() {
        let list = RecentPlayList.rank([
            play("Reckoner", minutesAgo: 2, source: .lastfm, playing: true),
            play("Nude", minutesAgo: 0.5, source: .musicApp, playing: true),
        ], now: now)
        #expect(list.plays.filter(\.isPlaying).map(\.title) == ["Nude"])
        #expect(list.plays.map(\.title) == ["Nude", "Reckoner"])
        #expect(list.preselected?.title == "Nude")
    }

    @Test func lapsedPlayingIsHistory() {
        let list = RecentPlayList.rank([play("Reckoner", minutesAgo: 30, playing: true), play("Nude", minutesAgo: 20)], now: now)
        #expect(list.plays.allSatisfy { !$0.isPlaying })
        #expect(list.plays.map(\.title) == ["Nude", "Reckoner"])
    }

    @Test func samePlayAcrossSourcesMerges() {
        let list = RecentPlayList.rank([
            play("Nude", minutesAgo: 4, source: .lastfm, album: "In Rainbows"),
            play("Nude", minutesAgo: 3, source: .listenbrainz, isrc: "GBSTK0700002"),
            play("Nude", minutesAgo: nil, source: .appleMusicRecent),
            play("Nude", minutesAgo: 90, source: .lastfm),
        ], now: now)
        #expect(list.plays.count == 2)
        #expect(list.plays[0].source == .listenbrainz)
        #expect(list.plays[0].album == "In Rainbows")
        #expect(list.plays[0].isrc == "GBSTK0700002")
        #expect(Set(list.plays.map(\.id)).count == 2)
    }

    @Test func undatedPlaysGoLastAndAreNeverPreselected() {
        let only = RecentPlayList.rank([play("Nude", minutesAgo: nil, source: .appleMusicRecent), play("Reckoner", minutesAgo: nil, source: .appleMusicRecent)], now: now)
        #expect(only.plays.map(\.title) == ["Nude", "Reckoner"])
        #expect(only.preselected == nil)

        let mixed = RecentPlayList.rank([play("Reckoner", minutesAgo: nil, source: .appleMusicRecent), play("Nude", minutesAgo: 30)], now: now)
        #expect(mixed.plays.map(\.title) == ["Nude", "Reckoner"])
        #expect(mixed.preselected?.title == "Nude")
    }

    @Test func stalePlaysAreListedButNotPreselected() {
        let list = RecentPlayList.rank([play("Nude", minutesAgo: 13 * 60)], now: now)
        #expect(list.plays.count == 1)
        #expect(list.preselected == nil)
    }

    @Test func limitsTheList() {
        let plays = (0..<15).map { play("Song \($0)", minutesAgo: Double($0) * 5) }
        #expect(RecentPlayList.rank(plays, now: now, limit: 10).plays.count == 10)
    }

    @Test func findsThePlayCoveringANote() {
        let plays = [play("Nude", minutesAgo: 10), play("Reckoner", minutesAgo: 3), play("Bodysnatchers", minutesAgo: 60)]
        #expect(RecentPlayList.play(covering: now.addingTimeInterval(-8 * 60), in: plays)?.title == "Nude")
        #expect(RecentPlayList.play(covering: now.addingTimeInterval(-60), in: plays)?.title == "Reckoner")
        #expect(RecentPlayList.play(covering: now.addingTimeInterval(-30 * 60), in: plays) == nil)
    }

    @Test func convertsToResolvableTrack() {
        let track = play("Nude", minutesAgo: 3, source: .appleMusicRecent).track(now: now)
        #expect(track.source == .appleMusic)
        #expect(track.claimsPlayback(at: now) == false)
        #expect(RecentPlay(track: track).playedAt == now.addingTimeInterval(-180))
    }
}
