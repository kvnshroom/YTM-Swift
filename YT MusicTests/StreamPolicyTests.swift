//
//  StreamPolicyTests.swift
//  YT MusicTests
//
//  Tests for choosing where a track's stream comes from (StreamSourcePolicy)
//  and the response fields the choice reads.
//

import Testing
import Foundation
@testable import YT_Music

func playerResponse(_ json: String) throws -> PlayerResponse {
    try JSONDecoder().decode(PlayerResponse.self, from: Data(json.utf8))
}

@Suite("Stream policy")
struct StreamPolicyTests {
    @Test("Reads the visitor id and the stats URLs")
    func readsResponseContextAndTracking() throws {
        let response = try playerResponse("""
        { "responseContext": { "visitorData": "Cgt4" },
          "playbackTracking": {
            "videostatsPlaybackUrl": { "baseUrl": "https://s.youtube.com/api/stats/playback?docid=a" },
            "videostatsWatchtimeUrl": { "baseUrl": "https://s.youtube.com/api/stats/watchtime?docid=a" } } }
        """)
        #expect(response.responseContext?.visitorData == "Cgt4")
        #expect(response.playbackTracking?.playbackURL?.query == "docid=a")
        #expect(response.playbackTracking?.watchtimeURL?.path == "/api/stats/watchtime")
    }

    @Test("Without Premium audio, visionOS comes first")
    func automaticOrderWithoutPremium() {
        for quality in AudioQuality.allCases {
            #expect(StreamSourcePolicy.automaticOrder(quality: quality, premiumAudio: false) == [.visionOS, .account])
        }
    }

    @Test("With Premium audio, the account comes first only for the best quality")
    func automaticOrderWithPremium() {
        #expect(StreamSourcePolicy.automaticOrder(quality: .auto, premiumAudio: true) == [.account, .visionOS])
        #expect(StreamSourcePolicy.automaticOrder(quality: .high, premiumAudio: true) == [.account, .visionOS])
        #expect(StreamSourcePolicy.automaticOrder(quality: .medium, premiumAudio: true) == [.visionOS, .account])
        #expect(StreamSourcePolicy.automaticOrder(quality: .low, premiumAudio: true) == [.visionOS, .account])
    }

    @Test("Premium audio means an AVPlayer-compatible itag 141")
    func detectsPremiumAudio() throws {
        let premium = try playerResponse("""
        { "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 130000 },
            { "itag": 141, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 260000 }
        ] } }
        """)
        let free = try playerResponse("""
        { "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 130000 },
            { "itag": 251, "mimeType": "audio/webm; codecs=\\"opus\\"", "bitrate": 160000 }
        ] } }
        """)
        #expect(StreamSourcePolicy.offersPremiumAudio(premium))
        #expect(!StreamSourcePolicy.offersPremiumAudio(free))
        #expect(!StreamSourcePolicy.offersPremiumAudio(try playerResponse("{}")))
    }

    @Test("A LOGIN_REQUIRED visionOS answer with a new visitor id is retried with it")
    func retriesWithFreshVisitorData() throws {
        let response = try playerResponse("""
        { "playabilityStatus": { "status": "LOGIN_REQUIRED" },
          "responseContext": { "visitorData": "fresh" } }
        """)
        #expect(StreamSourcePolicy.retryVisitorData(after: response, sentWith: nil) == "fresh")
        #expect(StreamSourcePolicy.retryVisitorData(after: response, sentWith: "stale") == "fresh")
        #expect(StreamSourcePolicy.retryVisitorData(after: response, sentWith: "fresh") == nil)

        let playable = try playerResponse("""
        { "playabilityStatus": { "status": "OK" }, "responseContext": { "visitorData": "fresh" } }
        """)
        #expect(StreamSourcePolicy.retryVisitorData(after: playable, sentWith: nil) == nil)
    }

    @Test("Uses a plain URL as is but never a ciphered one")
    func directURLOnlyWithoutCipher() throws {
        let response = try playerResponse("""
        { "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4", "url": "https://rr1.googlevideo.com/videoplayback?itag=140" },
            { "itag": 141, "mimeType": "audio/mp4", "signatureCipher": "s=abc&url=https%3A%2F%2Fx" }
        ] } }
        """)
        let formats = try #require(response.streamingData?.adaptiveFormats)
        #expect(StreamSourcePolicy.directURL(of: formats[0])?.host == "rr1.googlevideo.com")
        #expect(StreamSourcePolicy.directURL(of: formats[1]) == nil)
    }

    private let premiumJSON = """
    { "streamingData": { "adaptiveFormats": [
        { "itag": 141, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 260000 }
    ] } }
    """
    private let freeJSON = """
    { "streamingData": { "adaptiveFormats": [
        { "itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 130000 }
    ] } }
    """

    @Test("Premium state follows the latest account response")
    func premiumStateFollowsLatestResponse() throws {
        var session = StreamSession()
        session.reset(for: "sapisid-a")
        #expect(session.premiumAudio == nil)

        session.record(try playerResponse(premiumJSON))
        #expect(session.premiumAudio == true)

        session.record(try playerResponse(freeJSON))   // Premium ended mid-session
        #expect(session.premiumAudio == false)
    }

    @Test("A sign-in change starts the session over")
    func signInChangeResetsSession() throws {
        var session = StreamSession()
        session.reset(for: "sapisid-a")
        session.record(try playerResponse(premiumJSON))

        session.reset(for: "sapisid-a")                  // same account: kept
        #expect(session.premiumAudio == true)

        session.reset(for: "sapisid-b")                  // other account: unknown again
        #expect(session.premiumAudio == nil)
        #expect(session.sapisid == "sapisid-b")
    }

    @Test("The first-track deadline returns a fast result and gives up on a slow one")
    func firstTrackDeadline() async {
        let fast = Task<Int, Error> { 7 }
        #expect(await awaitValue(of: fast, within: 0.5) == 7)

        let slow = Task<Int, Error> {
            try await Task.sleep(for: .seconds(5))
            return 8
        }
        let started = ContinuousClock.now
        #expect(await awaitValue(of: slow, within: 0.05) == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
        slow.cancel()

        let failing = Task<Int, Error> { throw URLError(.notConnectedToInternet) }
        #expect(await awaitValue(of: failing, within: 0.5) == nil)
    }

    private func stream(source: StreamSource, age: TimeInterval, now: Date) -> ResolvedStream {
        var stream = ResolvedStream(url: URL(string: "https://rr1.googlevideo.com/videoplayback")!, duration: 200)
        stream.videoId = "a"
        stream.source = source
        stream.resolvedAt = now.addingTimeInterval(-age)
        return stream
    }

    @Test("A stream older than an hour counts as expired, not as a failing source")
    func oldStreamCountsAsExpired() {
        let now = Date()
        #expect(StreamSourcePolicy.classify(stream(source: .visionOS, age: 3700, now: now), at: now) == .expired)
        #expect(StreamSourcePolicy.classify(stream(source: .visionOS, age: 60, now: now), at: now)
            == .sourceFailed(.visionOS))
        var mintedAccount = stream(source: .account, age: 60, now: now)
        mintedAccount.usedToken = true
        #expect(StreamSourcePolicy.classify(mintedAccount, at: now) == .sourceFailed(.account))

        var unknown = stream(source: .visionOS, age: 60, now: now)
        unknown.source = nil
        #expect(StreamSourcePolicy.classify(unknown, at: now) == nil)
    }

    @Test("Failure memory is per video and expires after 10 minutes")
    func failureMemoryIsPerVideoAndExpires() {
        let now = Date()
        var memory = StreamFailureMemory()
        memory.record(.visionOS, videoId: "a", at: now)

        #expect(memory.excluded(for: "a", at: now.addingTimeInterval(60)) == [.visionOS])
        #expect(memory.excluded(for: "b", at: now.addingTimeInterval(60)).isEmpty)
        #expect(memory.excluded(for: "a", at: now.addingTimeInterval(601)).isEmpty)

        memory.record(.account, videoId: "a", at: now.addingTimeInterval(30))
        #expect(memory.excluded(for: "a", at: now.addingTimeInterval(60)) == [.visionOS, .account])
    }

    @Test("Only Premium accounts try without a token, and only until it was rejected")
    func accountTokenPlan() {
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: false, tokenFreeRejected: false, tokenFreeWorks: nil) == .mint)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: false, tokenFreeWorks: nil) == .probeThenDecide)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: false, tokenFreeWorks: true) == .tokenFree)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: false, tokenFreeWorks: false) == .mint)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: true, tokenFreeWorks: true) == .mint)
    }

    @Test("A token-free account stream that broke off means the account needs a token")
    func tokenFreeFailureIsClassified() {
        let now = Date()
        var tokenFree = stream(source: .account, age: 60, now: now)
        tokenFree.usedToken = false
        #expect(StreamSourcePolicy.classify(tokenFree, at: now) == .tokenFreeRejected)

        var minted = stream(source: .account, age: 60, now: now)
        minted.usedToken = true
        #expect(StreamSourcePolicy.classify(minted, at: now) == .sourceFailed(.account))
    }
}
