//
//  StreamFailureTests.swift
//  YT MusicTests
//
//  Tests for reloading a track whose stream dies mid-way (expired or rejected
//  URL) instead of skipping it.
//

import Testing
import Foundation
@testable import YT_Music

@Suite("Stream failure")
@MainActor
struct StreamFailureTests {
    private func tracks(_ ids: [String]) -> [Track] {
        ids.enumerated().map { index, id in
            Track(index: index + 1, title: id, subtitle: "Artist", duration: nil,
                  thumbnailURL: nil, videoId: id)
        }
    }

    @Test("A stream that dies while playing is reported and reloaded at the position reached")
    func reloadsAtPosition() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }

        audio.onStreamFailed?(42, nil)
        await eventually { audio.loadCount == 2 }

        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a"])
        #expect(resolver.calls.failures == [resolver.url])   // reported before the reload resolved
        #expect(audio.seekedTo == 42)
        #expect(player.currentIndex == 0)
    }

    @Test("Dying again without progress skips to the next track")
    func skipsAfterRepeatedFailure() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }

        audio.onStreamFailed?(42, nil)
        await eventually { audio.loadCount == 2 }
        audio.onStreamFailed?(45, nil)
        await eventually { audio.loadCount == 3 }

        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a", "b"])
        #expect(player.currentIndex == 1)
    }

    @Test("A stream that dies while paused reloads only on the next play")
    func waitsForPlayWhenPaused() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }
        player.togglePlayPause()
        #expect(!audio.isPlaying)

        audio.onStreamFailed?(42, nil)
        await eventually { false }
        #expect(audio.loadCount == 1)

        player.seek(to: 50)                       // moves where it will resume
        player.togglePlayPause()
        await eventually { audio.loadCount == 2 }
        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a"])
        #expect(audio.seekedTo == 50)
        #expect(audio.isPlaying)
    }

    @Test("A reload doesn't report the play to history a second time")
    func reloadKeepsHistory() async {
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio,
                                 resolver: StubResolver(duration: 200,
                                                        historyURL: URL(string: "https://m.youtube.com/p")!,
                                                        watchtimeURL: URL(string: "https://m.youtube.com/w")!,
                                                        cpn: "NONCE0123456789"),
                                 historyReporter: reporter)
        player.play(tracks(["a"]), startAt: 0)
        await eventually { audio.loadCount == 1 }
        audio.onProgress?(5, 200)
        await eventually { reporter.playbackStarts.count == 1 }

        audio.onStreamFailed?(42, nil)
        await eventually { audio.loadCount == 2 }
        audio.onProgress?(43, 200)
        await eventually { false }

        #expect(reporter.playbackStarts.count == 1)
    }

    @Test("With repeat-one, a track that keeps failing moves on instead of restarting the dead stream")
    func repeatOneSkipsAFailingTrack() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }
        player.cycleRepeatMode()                  // off → all
        player.cycleRepeatMode()                  // all → one
        #expect(player.repeatMode == .one)

        audio.onStreamFailed?(42, nil)
        await eventually { audio.loadCount == 2 }
        audio.onStreamFailed?(45, nil)
        await eventually { audio.loadCount == 3 }

        #expect(audio.restartCount == 0)
        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a", "b"])
    }

    @Test("A failure arriving while the next track loads is ignored")
    func ignoresFailureOfTheOutgoingTrack() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }

        player.next()                             // b starts loading
        audio.onStreamFailed?(80, nil)            // a's dying item reports late
        await eventually { audio.loadCount == 2 }
        await eventually { false }

        #expect(resolver.calls.calls.map(\.videoId) == ["a", "b"])
        #expect(audio.seekedTo == nil)
        #expect(player.currentIndex == 1)
    }
}
