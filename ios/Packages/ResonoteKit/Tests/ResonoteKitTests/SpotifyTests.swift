import Foundation
import Testing
@testable import ResonoteKit

@Suite struct SpotifyAuthTests {
    /// RFC 7636 Appendix B.
    @Test func challengeMatchesRFC7636Vector() {
        let octets: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(SpotifyAuth.base64URL(Data(octets)) == verifier)
        #expect(SpotifyAuth.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierAndStateHaveTheServersShape() {
        let verifier = SpotifyAuth.makeVerifier()
        let state = SpotifyAuth.makeState()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect((43...128).contains(verifier.count))
        #expect((16...128).contains(state.count))
        #expect(verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(state.unicodeScalars.allSatisfy(allowed.contains))
        let challenge = SpotifyAuth.challenge(for: verifier)
        #expect(challenge.count == 43)
        #expect(challenge.unicodeScalars.allSatisfy(allowed.contains))
        #expect(SpotifyAuth.makeVerifier() != verifier)
        #expect(SpotifyAuth.makeState() != state)
    }

    @Test func readsTheCodeWhenTheStateMatches() throws {
        let url = try #require(URL(string: "resonote://spotify-auth?code=AQBabc_123&state=s7ate-OK"))
        #expect(SpotifyAuth.code(fromCallback: url, expectedState: "s7ate-OK") == "AQBabc_123")
    }

    @Test func refusesAStateMismatch() throws {
        let url = try #require(URL(string: "resonote://spotify-auth?code=AQBabc&state=other"))
        #expect(SpotifyAuth.code(fromCallback: url, expectedState: "expected") == nil)
        let noState = try #require(URL(string: "resonote://spotify-auth?code=AQBabc"))
        #expect(SpotifyAuth.code(fromCallback: noState, expectedState: "expected") == nil)
        #expect(SpotifyAuth.code(fromCallback: url, expectedState: "") == nil)
    }

    @Test func refusesAnErrorCallback() throws {
        let url = try #require(URL(string: "resonote://spotify-auth?error=access_denied&state=s"))
        #expect(SpotifyAuth.code(fromCallback: url, expectedState: "s") == nil)
        #expect(SpotifyAuth.error(fromCallback: url) == "access_denied")
        let both = try #require(URL(string: "resonote://spotify-auth?code=AQB&error=access_denied&state=s"))
        #expect(SpotifyAuth.code(fromCallback: both, expectedState: "s") == nil)
    }

    @Test func refusesAMissingCodeOrAnotherURL() throws {
        let noCode = try #require(URL(string: "resonote://spotify-auth?state=s"))
        #expect(SpotifyAuth.code(fromCallback: noCode, expectedState: "s") == nil)
        let emptyCode = try #require(URL(string: "resonote://spotify-auth?code=&state=s"))
        #expect(SpotifyAuth.code(fromCallback: emptyCode, expectedState: "s") == nil)
        let lastfm = try #require(URL(string: "resonote://lastfm-auth?code=AQB&state=s"))
        #expect(SpotifyAuth.code(fromCallback: lastfm, expectedState: "s") == nil)
        let web = try #require(URL(string: "https://spotify-auth?code=AQB&state=s"))
        #expect(SpotifyAuth.code(fromCallback: web, expectedState: "s") == nil)
    }

    @Test func callbackIsNotADeepLink() throws {
        let url = try #require(URL(string: "resonote://spotify-auth?code=AQB&state=s"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func trackLinks() {
        #expect(SpotifyAuth.appURL(trackId: "4uLU6hMCjMI75M1A2tKUQC")?.absoluteString == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyAuth.webURL(trackId: "4uLU6hMCjMI75M1A2tKUQC")?.absoluteString == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyAuth.appURL(trackId: "short") == nil)
        #expect(SpotifyAuth.webURL(trackId: "4uLU6hMCjMI75M1A2tKU/C") == nil)
    }
}

@Suite struct SpotifyContractTests {
    @Test func decodesAccountResponses() throws {
        let linked = try JSONDecoder().decode(SpotifyAccountResponse.self, from: Data(#"{"ok":true,"configured":true,"account":{"id":"maya","displayName":"Maya","product":"premium","canPlay":true,"linkedAt":"2026-11-03T12:00:00.000Z"}}"#.utf8))
        #expect(linked.configured)
        #expect(linked.account?.name == "Maya")
        #expect(linked.account?.canPlay == true)
        let free = try JSONDecoder().decode(SpotifyAccountResponse.self, from: Data(#"{"ok":true,"configured":true,"account":{"id":"rob","displayName":null,"product":"free","canPlay":false,"linkedAt":"2026-11-03T12:00:00.000Z"}}"#.utf8))
        #expect(free.account?.canPlay == false)
        #expect(free.account?.name == "rob")
        let none = try JSONDecoder().decode(SpotifyAccountResponse.self, from: Data(#"{"ok":true,"configured":false,"account":null}"#.utf8))
        #expect(!none.configured)
        #expect(none.account == nil)
        // Without canPlay, Premium still plays.
        let older = try JSONDecoder().decode(SpotifyAccount.self, from: Data(#"{"id":"maya","product":"premium","linkedAt":"x"}"#.utf8))
        #expect(older.canPlay)
    }

    @Test func decodesAuthURLAndLink() throws {
        let auth = try JSONDecoder().decode(SpotifyAuthURLResponse.self, from: Data(#"{"ok":true,"url":"https://accounts.spotify.com/authorize?response_type=code&client_id=c&code_challenge_method=S256&code_challenge=x&state=s","callbackScheme":"resonote","redirectUri":"resonote://spotify-auth"}"#.utf8))
        #expect(auth.callbackScheme == "resonote")
        #expect(auth.redirectUri == "resonote://spotify-auth")
        #expect(auth.url.host() == "accounts.spotify.com")
        let bare = try JSONDecoder().decode(SpotifyAuthURLResponse.self, from: Data(#"{"ok":true,"url":"https://accounts.spotify.com/authorize"}"#.utf8))
        #expect(bare.callbackScheme == "resonote")
        #expect(bare.redirectUri == "resonote://spotify-auth")
        let link = try JSONDecoder().decode(SpotifyLinkResponse.self, from: Data(#"{"ok":true,"account":{"id":"maya","displayName":"Maya","product":"premium","canPlay":true,"linkedAt":"2026-11-03T12:00:00.000Z"}}"#.utf8))
        #expect(link.account.id == "maya")
    }

    @Test func decodesDevicesLeniently() throws {
        let json = #"{"ok":true,"devices":[{"id":"d1","name":"Maya's iPhone","type":"Smartphone","isActive":false,"volumePercent":60},{"id":"d2","name":"Kitchen","type":"Speaker","isActive":true,"volumePercent":null},{"name":"No id"}]}"#
        let response = try JSONDecoder().decode(SpotifyDevicesResponse.self, from: Data(json.utf8))
        #expect(response.devices.map(\.id) == ["d1", "d2"])
        #expect(response.devices[0].volumePercent == 60)
        #expect(response.devices[1].volumePercent == nil)
        #expect(response.devices[0].isSmartphone)
    }

    @Test func retryTargetsOnlyAPhoneOrTheActiveDevice() {
        let idlePhone = SpotifyDevice(id: "p1", name: "iPhone", type: "Smartphone")
        let activePhone = SpotifyDevice(id: "p2", name: "iPhone", type: "Smartphone", isActive: true)
        let idleComputer = SpotifyDevice(id: "c", name: "Home Mac", type: "Computer")
        let activeSpeaker = SpotifyDevice(id: "s", name: "Kitchen", type: "Speaker", isActive: true)
        // The active smartphone beats everything.
        #expect(SpotifyDevice.target(in: [idleComputer, activeSpeaker, idlePhone, activePhone]) == activePhone)
        // The only smartphone, even idle.
        #expect(SpotifyDevice.target(in: [idleComputer, idlePhone]) == idlePhone)
        // Two idle phones: can't tell which is this one; the active device, if any.
        let otherPhone = SpotifyDevice(id: "p3", name: "iPhone", type: "Smartphone")
        #expect(SpotifyDevice.target(in: [idlePhone, otherPhone, activeSpeaker]) == activeSpeaker)
        #expect(SpotifyDevice.target(in: [idlePhone, otherPhone]) == nil)
        // Never an arbitrary idle device.
        #expect(SpotifyDevice.target(in: [idleComputer]) == nil)
        #expect(SpotifyDevice.target(in: []) == nil)
    }

    @Test func encodesPlaybackRequest() throws {
        let data = try JSONEncoder().encode(SpotifyPlaybackRequest(action: .play, spotifyId: "4uLU6hMCjMI75M1A2tKUQC"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["action"] as? String == "play")
        #expect(object?["spotifyId"] as? String == "4uLU6hMCjMI75M1A2tKUQC")
        #expect(object?["deviceId"] == nil)
    }

    @Test func mapsPlaybackErrorCodes() {
        #expect(SpotifyPlaybackError(code: "no-device") == .noDevice)
        #expect(SpotifyPlaybackError(code: "premium-required") == .premiumRequired)
        #expect(SpotifyPlaybackError(code: "not-linked") == .notLinked)
        #expect(SpotifyPlaybackError(code: "Something else") == nil)
        #expect(SpotifyPlaybackError.noDevice.errorDescription == "Open Spotify on a device first.")
    }

    @Test func decodesSpotifyAndUnknownServiceStatuses() throws {
        let json = """
        {"ok":true,"recent":[
           {"title":"Nude","artist":"Radiohead","album":"In Rainbows","source":"spotify","isPlaying":false,"observedAt":"2026-11-03T11:55:00.000Z","spotifyId":"4uLU6hMCjMI75M1A2tKUQC","isrc":"GBSTK0700002","url":"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"}
         ],
         "services":[{"service":"lastfm","status":"ok"},{"service":"spotify","status":"unavailable"},{"service":"tidal","status":"ok"},{"service":"x","status":"weird"}]}
        """
        let response = try JSONDecoder().decode(RemoteNowPlayingResponse.self, from: Data(json.utf8))
        #expect(response.services.map(\.service) == [.lastfm, .spotify, .other("tidal")])
        #expect(response.services.map(\.status) == [.ok, .unavailable, .ok])
        #expect(response.services[2].service.rawValue == "tidal")
        #expect(!response.answeredSources.contains(.spotify))
        let ok = RemoteNowPlayingResponse(services: [.init(service: .spotify, status: .ok)])
        #expect(ok.answeredSources == [.lastfm, .listenbrainz, .spotify])

        let play = try #require(response.recentPlays.first)
        #expect(play.source == .spotify)
        #expect(play.source.label == "Spotify")
        #expect(play.source.trackSource == .spotify)
        #expect(play.spotifyId == "4uLU6hMCjMI75M1A2tKUQC")
        #expect(play.track().source == .spotify)
    }

    @Test func spotifyPlayMergesWithItsScrobble() throws {
        let at = try #require(ResonoteDate.parse("2026-11-03T11:55:00.000Z"))
        let spotify = RecentPlay(title: "Nude", artist: "Radiohead", playedAt: at, source: .spotify, spotifyId: "4uLU6hMCjMI75M1A2tKUQC")
        let scrobble = RecentPlay(title: "Nude", artist: "Radiohead", playedAt: at.addingTimeInterval(20), source: .lastfm, mbid: "m")
        let list = RecentPlayList.rank([spotify, scrobble], now: at.addingTimeInterval(60))
        #expect(list.plays.count == 1)
        #expect(list.plays.first?.spotifyId == "4uLU6hMCjMI75M1A2tKUQC")
        #expect(list.plays.first?.mbid == "m")
    }
}

@Suite struct LinkedSourcesSpotifyTests {
    @Test func decodesWithoutSpotifyLinked() throws {
        let older = try JSONDecoder().decode(LinkedSources.self, from: Data(#"{"lastfmUser":"maya","appleMusicEnabled":true}"#.utf8))
        #expect(!older.spotifyLinked)
        #expect(older.hasRemote)
        let odd = try JSONDecoder().decode(LinkedSources.self, from: Data(#"{"spotifyLinked":"yes"}"#.utf8))
        #expect(!odd.spotifyLinked)
        #expect(!odd.hasRemote)
    }

    @Test func spotifyAloneIsARemoteSource() throws {
        let sources = LinkedSources(spotifyLinked: true)
        #expect(sources.hasRemote)
        let round = try JSONDecoder().decode(LinkedSources.self, from: JSONEncoder().encode(sources))
        #expect(round.spotifyLinked)
        #expect(round == sources)
    }
}
