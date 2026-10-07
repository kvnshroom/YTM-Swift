//
//  PrewarmTests.swift
//  YT MusicTests
//
//  The player JS is loaded at launch, so the first track's account response
//  (and with it Premium detection) doesn't wait for it.
//

import Testing
import Foundation
@testable import YT_Music

nonisolated final class PrewarmCountingResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _prewarms = 0
    var prewarms: Int { lock.withLock { _prewarms } }

    func prewarm() async { lock.withLock { _prewarms += 1 } }

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        ResolvedStream(url: URL(string: "https://stream.example.com/\(videoId).m4a")!, duration: 200)
    }
}

@Suite("Prewarm")
@MainActor
struct PrewarmTests {
    @Test("Creating the player prewarms the resolver once")
    func prewarmsOnLaunch() async {
        let resolver = PrewarmCountingResolver()
        _ = PlayerState(audio: FakeAudioOutput(), resolver: resolver)
        await eventually { resolver.prewarms == 1 }
        #expect(resolver.prewarms == 1)
    }
}
