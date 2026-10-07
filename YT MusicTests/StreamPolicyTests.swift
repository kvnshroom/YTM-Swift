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
}
