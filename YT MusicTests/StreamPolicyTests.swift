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
}
