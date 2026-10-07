//
//  LateHistoryTests.swift
//  YT MusicTests
//
//  Tests for history stats URLs that arrive after the stream has started
//  (visionOS answers before the account's player response).
//

import Testing
import Foundation
@testable import YT_Music

/// Resolves at once and hands the stats URLs over only when `deliver` is called.
nonisolated final class LateTrackingResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<PlayerResponse.PlaybackTracking?, Never>] = []

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        var stream = ResolvedStream(url: URL(string: "https://stream.example.com/\(videoId).m4a")!,
                                    duration: 200, cpn: "NONCE0123456789")
        stream.lateTracking = Task {
            await withCheckedContinuation { continuation in
                self.lock.withLock { self.continuations.append(continuation) }
            }
        }
        return stream
    }

    var waiting: Int { lock.withLock { continuations.count } }

    /// Delivers stats URLs to the oldest stream still waiting for them.
    func deliver(videoId: String) {
        let tracking = PlayerResponse.PlaybackTracking(
            videostatsPlaybackUrl: .init(baseUrl: "https://music.youtube.com/api/stats/playback?docid=\(videoId)"),
            videostatsWatchtimeUrl: .init(baseUrl: "https://music.youtube.com/api/stats/watchtime?docid=\(videoId)")
        )
        let continuation = lock.withLock { continuations.removeFirst() }
        continuation.resume(returning: tracking)
    }
}

@Suite("Late history")
@MainActor
struct LateHistoryTests {
    private func tracks(_ ids: [String]) -> [Track] {
        ids.enumerated().map { index, id in
            Track(index: index + 1, title: id, subtitle: "Artist", duration: nil,
                  thumbnailURL: nil, videoId: id)
        }
    }

    @Test("The stream starts at once and history follows when its URLs arrive")
    func armsWhenTrackingArrives() async {
        let resolver = LateTrackingResolver()
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: resolver, historyReporter: reporter)
        player.play(tracks(["a"]), startAt: 0)
        await eventually { audio.loadCount == 1 && resolver.waiting == 1 }
        #expect(audio.loadCount == 1)

        audio.onProgress?(2, 200)
        await eventually { false }
        #expect(reporter.playbackStarts.isEmpty)

        resolver.deliver(videoId: "a")
        await eventually { false }
        audio.onProgress?(3, 200)
        await eventually { reporter.playbackStarts.count == 1 }
        #expect(reporter.playbackStarts.first?.url.query == "docid=a")
    }

    @Test("URLs arriving after the track changed are dropped")
    func dropsTrackingOfAnEarlierTrack() async {
        let resolver = LateTrackingResolver()
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: resolver, historyReporter: reporter)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 && resolver.waiting == 1 }

        player.next()
        await eventually { audio.loadCount == 2 && resolver.waiting == 2 }
        resolver.deliver(videoId: "a")
        await eventually { false }
        audio.onProgress?(3, 200)
        await eventually { false }

        #expect(reporter.playbackStarts.isEmpty)
    }
}
