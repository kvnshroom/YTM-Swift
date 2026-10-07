//
//  PlayerTests.swift
//  YT MusicTests
//
//  Tests for the playback layer. PlayerState's resolve→load/error orchestration
//  is driven through injected fakes (no network, no audio hardware); AudioPlayer's
//  no-item transport guards are tested on the real instance.
//

import Testing
import Foundation
@testable import YT_Music

// MARK: - Test doubles

enum StubError: Error { case boom }

/// Thread-safe record of resolver calls — PlayerState drives resolves from
/// fire-and-forget tasks, so the stub (a struct) records through this box.
nonisolated final class ResolverCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(videoId: String, playlistId: String?)] = []

    func record(videoId: String, playlistId: String?) {
        lock.withLock { _calls.append((videoId, playlistId)) }
    }

    var calls: [(videoId: String, playlistId: String?)] { lock.withLock { _calls } }

    private var _failures: [URL] = []
    func recordFailure(_ url: URL) { lock.withLock { _failures.append(url) } }
    var failures: [URL] { lock.withLock { _failures } }
}

nonisolated struct StubResolver: StreamResolving {
    var url = URL(string: "https://stream.example.com/audio.m4a")!
    var duration: Double? = nil
    var historyURL: URL? = nil
    var watchtimeURL: URL? = nil
    var cpn: String? = nil
    var loudnessDb: Double? = nil
    var shouldThrow = false
    let calls = ResolverCalls()

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        calls.record(videoId: videoId, playlistId: playlistId)
        if shouldThrow { throw StubError.boom }
        return ResolvedStream(url: url, duration: duration, historyURL: historyURL,
                              watchtimeURL: watchtimeURL, cpn: cpn, loudnessDb: loudnessDb)
    }

    func streamFailed(_ stream: ResolvedStream, error: Error?) async {
        calls.recordFailure(stream.url)
    }
}

/// Records the history beacons PlayerState fires. A lock-guarded Sendable class
/// (the reporter protocol is nonisolated) so tests can read it synchronously
/// after letting the fire-and-forget Tasks run.
final class FakeHistoryReporter: WatchHistoryReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _playbackStarts: [(url: URL, cpn: String, position: Double)] = []
    private var _watchtimes: [(url: URL, cpn: String, position: Double)] = []

    var playbackStarts: [(url: URL, cpn: String, position: Double)] { lock.withLock { _playbackStarts } }
    var watchtimes: [(url: URL, cpn: String, position: Double)] { lock.withLock { _watchtimes } }

    func reportPlaybackStart(playbackURL: URL, cpn: String, position: Double, length: Double?) async {
        lock.withLock { _playbackStarts.append((playbackURL, cpn, position)) }
    }
    func reportWatchtime(watchtimeURL: URL, cpn: String, position: Double, length: Double?) async {
        lock.withLock { _watchtimes.append((watchtimeURL, cpn, position)) }
    }
}

nonisolated struct StubRadio: RadioProviding {
    var tracks: [Track] = []
    /// Tracks returned by `watchQueue` (a "Play all"); falls back to `tracks`.
    var watchQueueTracks: [Track]? = nil
    /// The continuation token `radio(for:)` hands back, if any.
    var continuationToken: String? = nil
    /// Pages returned by `continueRadio`, keyed by the token, so a test can
    /// chain multiple continuations.
    var continuationPages: [String: RadioPage] = [:]

    func radio(for videoId: String) async throws -> RadioPage {
        RadioPage(tracks: tracks, continuation: continuationToken)
    }
    func continueRadio(_ token: String) async throws -> RadioPage {
        continuationPages[token] ?? RadioPage(tracks: [], continuation: nil)
    }
    func watchQueue(videoId: String, playlistId: String) async throws -> [Track] {
        watchQueueTracks ?? tracks
    }
}

@MainActor
final class InMemoryStore: PlaybackStore {
    var snapshot: PersistedPlayback?
    func load() -> PersistedPlayback? { snapshot }
    func save(_ snapshot: PersistedPlayback?) { self.snapshot = snapshot }
}

@MainActor
final class FakeAudioOutput: AudioOutput {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var bufferedTime: Double = 0
    var volume: Double = 1
    var normalizesVolume = false
    var onTrackFinished: (() -> Void)?
    var onStreamFailed: ((Double, Error?) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onProgress: ((Double, Double) -> Void)?
    private(set) var loadedURL: URL?
    private(set) var loadedMetadata: NowPlayingMetadata?
    private(set) var loadCount = 0
    private(set) var toggleCount = 0
    private(set) var seekedTo: Double?
    private(set) var restartCount = 0
    private(set) var crossfadedURL: URL?
    private(set) var crossfadeDuration: Double?
    private(set) var preloadedURL: URL?
    private(set) var loadedPreloadedURL: URL?
    private(set) var equalizer: EqualizerSettings?

    func load(url: URL, metadata: NowPlayingMetadata) {
        loadedURL = url
        loadedMetadata = metadata
        loadCount += 1
        isPlaying = true
    }
    func preload(url: URL, metadata: NowPlayingMetadata) {
        preloadedURL = url
    }
    func loadPreloaded(url: URL, metadata: NowPlayingMetadata) {
        loadedPreloadedURL = url
        load(url: url, metadata: metadata)
    }
    func togglePlayPause() { toggleCount += 1; isPlaying.toggle() }
    func seek(to seconds: Double) { seekedTo = seconds; currentTime = seconds }
    func restart() { restartCount += 1; currentTime = 0; isPlaying = true }
    func crossfade(to url: URL, metadata: NowPlayingMetadata, duration: Double) {
        crossfadedURL = url
        loadedMetadata = metadata
        crossfadeDuration = duration
        isPlaying = true
    }
    func applyEqualizer(_ settings: EqualizerSettings) { equalizer = settings }
}

/// Records like requests. MainActor (not an actor) because PlayerState calls it
/// from a MainActor-isolated task, so assertions stay synchronous.
@MainActor
final class FakeLikeProvider: LikeProviding {
    private(set) var calls: [(videoId: String, status: LikeStatus)] = []
    var shouldThrow = false
    /// Server-side rating returned by `likeStatus(for:)`, keyed by videoId.
    var statuses: [String: LikeStatus] = [:]
    private(set) var statusQueries: [String] = []

    func setLikeStatus(videoId: String, status: LikeStatus) async throws {
        if shouldThrow { throw StubError.boom }
        calls.append((videoId, status))
    }

    func likeStatus(for videoId: String) async throws -> LikeStatus {
        statusQueries.append(videoId)
        return statuses[videoId] ?? .indifferent
    }
}

/// Polls until `condition` holds (yielding to let pending tasks run) or a bounded
/// number of iterations elapses — for awaiting fire-and-forget Tasks in tests.
@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
}

// MARK: - PlayerState

@Suite("PlayerState")
@MainActor
struct PlayerStateTests {

    private func track(videoId: String?) -> Track {
        Track(index: 1, title: "Song", subtitle: "Artist", duration: nil,
              thumbnailURL: nil, videoId: videoId)
    }

    @Test("play() records now-playing and enters loading")
    func playSetsState() {
        let player = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver())
        player.play(title: "Song", subtitle: "Artist", thumbnailURL: nil, videoId: "vid")
        #expect(player.nowPlaying?.videoId == "vid")
        #expect(player.isLoading)
    }

    @Test("play(track:) without a video id is a no-op")
    func ignoresTrackWithoutVideoId() {
        let player = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver())
        player.play(track(videoId: nil))
        #expect(player.nowPlaying == nil)
        #expect(!player.isLoading)
    }

    @Test("Successful resolve loads the stream and clears loading")
    func loadsStreamOnSuccess() async {
        let audio = FakeAudioOutput()
        let url = URL(string: "https://stream.example.com/track.m4a")!
        let player = PlayerState(audio: audio, resolver: StubResolver(url: url))

        await player.loadStream(videoId: "vid")

        #expect(audio.loadedURL == url)
        #expect(player.loadError == nil)
        #expect(!player.isLoading)
    }

    @Test("Now-playing metadata carries title, artist, and album")
    func metadataIncludesAlbum() async {
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: StubResolver())
        player.play(title: "Song", subtitle: "Artist", album: "Greatest Hits",
                    thumbnailURL: nil, videoId: "vid")

        await player.loadStream(videoId: "vid")

        #expect(audio.loadedMetadata?.title == "Song")
        #expect(audio.loadedMetadata?.artist == "Artist")
        #expect(audio.loadedMetadata?.album == "Greatest Hits")
    }

    @Test("Uses the authoritative track length from the resolver")
    func usesKnownDuration() async {
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: StubResolver(duration: 200))
        player.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "v")

        await player.loadStream(videoId: "v")

        #expect(audio.loadedMetadata?.knownDuration == 200)
    }

    @Test("Passes the resolver's track loudness to the audio engine")
    func passesLoudness() async {
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: StubResolver(loudnessDb: 4.5))
        player.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "v")

        await player.loadStream(videoId: "v")

        #expect(audio.loadedMetadata?.loudnessDb == 4.5)
    }

    @Test("Volume normalization follows the setting, including live changes")
    func normalizationFollowsSetting() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        suite.set(true, forKey: "settings.volumeNormalization")
        let settings = AppSettings(defaults: suite)
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: StubResolver(), settings: settings)
        #expect(audio.normalizesVolume)

        settings.volumeNormalization = false
        #expect(!audio.normalizesVolume)
        withExtendedLifetime(player) {}
    }

    @Test("Failed resolve surfaces an error and loads nothing")
    func setsErrorOnFailure() async {
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: StubResolver(shouldThrow: true))
        player.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        await player.loadStream(videoId: "vid")

        #expect(audio.loadedURL == nil)
        #expect(player.loadError != nil)
        #expect(!player.isLoading)
    }

    @Test("Playing a track fires playback + watchtime beacons once underway")
    func reportsPlayedTrackToHistory() async {
        let reporter = FakeHistoryReporter()
        let historyURL = URL(string: "https://music.youtube.com/api/stats/playback?docid=vid")!
        let watchtimeURL = URL(string: "https://music.youtube.com/api/stats/watchtime?docid=vid")!
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio,
                                 resolver: StubResolver(duration: 200,
                                                        historyURL: historyURL,
                                                        watchtimeURL: watchtimeURL,
                                                        cpn: "NONCE0123456789"),
                                 historyReporter: reporter)

        await player.loadStream(videoId: "vid")   // arms history; audio is now "playing"
        audio.onProgress?(5, 200)                  // 5s into the track

        await eventually { reporter.playbackStarts.count == 1 && reporter.watchtimes.count == 1 }
        #expect(reporter.playbackStarts.first?.url == historyURL)
        #expect(reporter.playbackStarts.first?.cpn == "NONCE0123456789")
        #expect(reporter.watchtimes.first?.url == watchtimeURL)
        #expect(reporter.watchtimes.first?.position == 5)
    }

    @Test("Nothing fires before the track is actually playing")
    func noHistoryBeforePlayback() async {
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio,
                                 resolver: StubResolver(historyURL: URL(string: "https://m.youtube.com/p")!,
                                                        watchtimeURL: URL(string: "https://m.youtube.com/w")!,
                                                        cpn: "NONCE0123456789"),
                                 historyReporter: reporter)

        await player.loadStream(videoId: "vid")   // armed, but no progress yet
        await eventually { false }                 // give any stray Task a chance to run

        #expect(reporter.playbackStarts.isEmpty)
        #expect(reporter.watchtimes.isEmpty)
    }

    @Test("No history beacons when the resolver supplies no tracking URL")
    func skipsHistoryWithoutTrackingURL() async {
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio,
                                 resolver: StubResolver(historyURL: nil, watchtimeURL: nil, cpn: nil),
                                 historyReporter: reporter)

        await player.loadStream(videoId: "vid")
        audio.onProgress?(5, 200)
        await eventually { false }

        #expect(reporter.playbackStarts.isEmpty)
        #expect(reporter.watchtimes.isEmpty)
    }

    @Test("Transport controls proxy to the audio engine")
    func transportProxies() {
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: StubResolver())

        player.togglePlayPause()
        #expect(audio.toggleCount == 1)

        player.seek(to: 42)
        #expect(audio.seekedTo == 42)
    }
}

// MARK: - Queue, transport & repeat

@Suite("PlayerState queue")
@MainActor
struct PlayerStateQueueTests {

    private func tracks(_ ids: [String?]) -> [Track] {
        ids.enumerated().map { i, id in
            Track(index: i + 1, title: "T\(i)", subtitle: "A", duration: nil,
                  thumbnailURL: nil, videoId: id)
        }
    }

    private func player() -> PlayerState {
        PlayerState(audio: FakeAudioOutput(), resolver: StubResolver())
    }

    @Test("play(queue:) starts at the requested index and records the queue")
    func playsQueueAtIndex() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 1)
        #expect(p.queue.count == 3)
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    @Test("play(queue:) filters unplayable tracks and remaps the start")
    func filtersUnplayable() {
        let p = player()
        // Request the (unplayable) middle track → first playable at/after it.
        p.play(tracks(["a", nil, "c"]), startAt: 1)
        #expect(p.queue.map(\.videoId) == ["a", "c"])
        #expect(p.nowPlaying?.videoId == "c")
        #expect(p.currentIndex == 1)
    }

    @Test("next advances and stops at the end when repeat is off")
    func nextStopsAtEnd() {
        let p = player()
        p.play(tracks(["a", "b"]), startAt: 0)
        p.next()
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
        p.next() // at end, repeat off → no change
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    @Test("next wraps to the start when repeat is all")
    func nextWrapsWhenRepeatAll() {
        let p = player()
        p.play(tracks(["a", "b"]), startAt: 1)
        p.cycleRepeatMode() // .all
        #expect(p.repeatMode == .all)
        p.next()
        #expect(p.currentIndex == 0)
        #expect(p.nowPlaying?.videoId == "a")
    }

    @Test("previous restarts the current track when more than 3s in")
    func previousRestartsLateInTrack() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver())
        p.play(tracks(["a", "b", "c"]), startAt: 2)
        audio.currentTime = 10
        p.previous()
        #expect(audio.seekedTo == 0)
        #expect(p.currentIndex == 2)
    }

    @Test("previous steps back early in a track")
    func previousStepsBackEarly() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver())
        p.play(tracks(["a", "b", "c"]), startAt: 2)
        audio.currentTime = 1
        p.previous()
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    @Test("cycleRepeatMode cycles off → all → one → off")
    func cyclesRepeatMode() {
        let p = player()
        #expect(p.repeatMode == .off)
        p.cycleRepeatMode(); #expect(p.repeatMode == .all)
        p.cycleRepeatMode(); #expect(p.repeatMode == .one)
        p.cycleRepeatMode(); #expect(p.repeatMode == .off)
    }

    @Test("playQueueItem jumps to and plays the chosen row")
    func playQueueItemJumps() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 0)
        p.playQueueItem(at: 2)
        #expect(p.currentIndex == 2)
        #expect(p.nowPlaying?.videoId == "c")
        p.playQueueItem(at: 99) // out of range → no-op
        #expect(p.currentIndex == 2)
    }

    @Test("removing a track before the current one keeps it playing")
    func removeBeforeCurrent() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 2)
        p.removeFromQueue(at: 0)
        #expect(p.queue.map(\.videoId) == ["b", "c"])
        #expect(p.currentIndex == 1)          // shifted down to follow "c"
        #expect(p.nowPlaying?.videoId == "c")
    }

    @Test("removing the current track advances to what slides into its place")
    func removeCurrentAdvances() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 1)
        p.removeFromQueue(at: 1)
        #expect(p.queue.map(\.videoId) == ["a", "c"])
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "c")  // "c" slid into index 1 and plays
    }

    @Test("moving a track keeps the playing track current")
    func moveKeepsCurrent() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 0) // "a" playing
        p.moveInQueue(fromOffsets: IndexSet(integer: 0), toOffset: 3) // a → end
        #expect(p.queue.map(\.videoId) == ["b", "c", "a"])
        #expect(p.currentIndex == 2)            // still pointing at "a"
        #expect(p.nowPlaying?.videoId == "a")
    }

    @Test("a finished track advances to the next when repeat is off")
    func finishAdvances() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver())
        p.play(tracks(["a", "b"]), startAt: 0)
        audio.onTrackFinished?()
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    @Test("a finished track replays itself when repeat is one")
    func finishReplaysWhenRepeatOne() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver())
        p.play(tracks(["a", "b"]), startAt: 0)
        p.cycleRepeatMode(); p.cycleRepeatMode() // .one
        audio.onTrackFinished?()
        #expect(audio.restartCount == 1)
        #expect(p.currentIndex == 0)
    }

    @Test("canGoNext/canGoPrevious reflect position and repeat mode")
    func navigationAvailability() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 0)
        #expect(p.canGoNext)
        #expect(!p.canGoPrevious)
        p.cycleRepeatMode() // .all → wrapping enables previous
        #expect(p.canGoPrevious)
    }

    @Test("a one-off play clears the queue and disables navigation")
    func singlePlayClearsQueue() {
        let p = player()
        p.play(tracks(["a", "b"]), startAt: 0)
        p.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "x")
        #expect(p.queue.isEmpty)
        #expect(!p.canGoNext)
        #expect(!p.canGoPrevious)
    }

    @Test("playNext inserts after the current track in a queue")
    func playNextInsertsInQueue() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 0)
        p.playNext(title: "X", subtitle: "A", thumbnailURL: nil, videoId: "x")
        #expect(p.queue.map(\.videoId) == ["a", "x", "b", "c"])
        #expect(p.currentIndex == 0)
    }

    @Test("playNext on a one-off play seeds the queue with the current track")
    func playNextSeedsOneOff() {
        let p = player()
        p.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "seed")
        p.playNext(title: "X", subtitle: "A", thumbnailURL: nil, videoId: "x")
        #expect(p.queue.map(\.videoId) == ["seed", "x"])
        #expect(p.currentIndex == 0)
        #expect(p.nowPlaying?.videoId == "seed")
    }

    @Test("playNext with nothing playing just plays the track")
    func playNextWithNothingPlaying() {
        let p = player()
        p.playNext(title: "X", subtitle: "A", thumbnailURL: nil, videoId: "x")
        #expect(p.nowPlaying?.videoId == "x")
        #expect(p.queue.isEmpty)
    }

    @Test("startRadio plays the seed immediately")
    func startRadioPlaysSeed() {
        let radio = StubRadio(tracks: tracks(["seed", "n2"]))
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), radioProvider: radio)
        p.startRadio(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")
        #expect(p.nowPlaying?.videoId == "seed")
    }

    @Test("startRadio on the already-playing seed doesn't restart it")
    func startRadioOnCurrentSeedDoesNotRestart() async {
        let audio = FakeAudioOutput()
        let radio = StubRadio(tracks: tracks(["seed", "n2"]))
        let p = PlayerState(audio: audio, resolver: StubResolver(), radioProvider: radio)

        p.play(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")
        await eventually { audio.loadCount == 1 }
        audio.currentTime = 42

        p.startRadio(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")
        await eventually { p.queue.map(\.videoId) == ["seed", "n2"] }

        #expect(audio.loadCount == 1)
        #expect(audio.currentTime == 42)
        #expect(p.currentIndex == 0)
    }

    @Test("installRadio installs the fetched queue, anchored on the seed")
    func installRadioBuildsQueue() async {
        // Seed first, then more tracks (mirrors the real radio response).
        let radioTracks = [
            Track(index: 1, title: "Seed", subtitle: "A", duration: nil, thumbnailURL: nil, videoId: "seed"),
            Track(index: 2, title: "Next", subtitle: "B", duration: nil, thumbnailURL: nil, videoId: "n2"),
        ]
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: radioTracks))
        p.play(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")

        await p.installRadio(seed: "seed")

        #expect(p.queue.map(\.videoId) == ["seed", "n2"])
        #expect(p.currentIndex == 0)
        #expect(p.canGoNext)
    }

    @Test("installRadio is ignored if the seed is no longer playing")
    func installRadioIgnoredAfterChange() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: tracks(["seed", "n2"])))
        p.play(title: "Other", subtitle: "A", thumbnailURL: nil, videoId: "other")
        await p.installRadio(seed: "seed")   // seed isn't what's playing
        #expect(p.queue.isEmpty)
    }

    @Test("installRadio keeps the seed current even if the radio response omits it")
    func installRadioKeepsSeedWhenOmitted() async {
        // Some radio responses (premieres, live videos) don't echo the seed back.
        let radioTracks = tracks(["n2", "n3"])
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: radioTracks))
        p.play(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")

        await p.installRadio(seed: "seed")

        #expect(p.queue.map(\.videoId) == ["seed", "n2", "n3"])
        #expect(p.currentIndex == 0)
        #expect(p.nowPlaying?.videoId == "seed")
    }

    // MARK: - Play all

    @Test("playAll plays the fetched watch queue with real track metadata")
    func playAllBuildsQueue() async {
        // A "Play all" resolves the real playlist tracks, not the button label.
        let queue = [
            Track(index: 1, title: "First", subtitle: "A", duration: nil, thumbnailURL: nil, videoId: "a"),
            Track(index: 2, title: "Second", subtitle: "B", duration: nil, thumbnailURL: nil, videoId: "b"),
        ]
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: queue))

        await p.loadAndPlayAll(videoId: nil, playlistId: "PL42")

        #expect(p.queue.map(\.videoId) == ["a", "b"])
        #expect(p.currentIndex == 0)
        #expect(p.nowPlaying?.title == "First")
    }

    @Test("playAll starts at the seed video when one is given")
    func playAllStartsAtSeed() async {
        let queue = tracks(["a", "b", "c"])
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: queue))

        await p.loadAndPlayAll(videoId: "b", playlistId: "PL42")

        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    @Test("A shuffled playAll turns shuffle on over the whole fetched queue")
    func playAllShuffled() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: tracks(["a", "b", "c", "d"])))

        await p.loadAndPlayAll(videoId: nil, playlistId: "PL42", shuffled: true)

        #expect(p.isShuffled)
        #expect(p.currentIndex == 0)
        #expect(Set(p.queue.compactMap(\.videoId)) == ["a", "b", "c", "d"])
    }

    @Test("Enqueuing a playlist next inserts it after the current track")
    func enqueueNext() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: tracks(["x", "y"])))
        p.play(tracks(["a", "b"]), startAt: 0)

        await p.loadAndEnqueueAll(playlistId: "PL42", next: true)

        #expect(p.queue.map(\.videoId) == ["a", "x", "y", "b"])
        #expect(p.nowPlaying?.videoId == "a")
    }

    @Test("Adding a playlist to the queue appends it")
    func enqueueAtEnd() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: tracks(["x", "y"])))
        p.play(tracks(["a", "b"]), startAt: 0)

        await p.loadAndEnqueueAll(playlistId: "PL42", next: false)

        #expect(p.queue.map(\.videoId) == ["a", "b", "x", "y"])
    }

    @Test("Enqueuing after a one-off play keeps the current track at the head")
    func enqueueAfterOneOff() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: tracks(["x", "y"])))
        p.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "seed")

        await p.loadAndEnqueueAll(playlistId: "PL42", next: true)

        #expect(p.queue.map(\.videoId) == ["seed", "x", "y"])
        #expect(p.currentIndex == 0)
    }

    @Test("Enqueuing with nothing playing plays the playlist")
    func enqueueWithNothingPlaying() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: tracks(["x", "y"])))

        await p.loadAndEnqueueAll(playlistId: "PL42", next: false)

        #expect(p.queue.map(\.videoId) == ["x", "y"])
        #expect(p.nowPlaying?.videoId == "x")
    }

    @Test("playAll is a no-op when the watch queue is empty")
    func playAllEmptyQueue() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: []))
        await p.loadAndPlayAll(videoId: nil, playlistId: "PL42")
        #expect(p.queue.isEmpty)
        #expect(p.nowPlaying == nil)
    }

    // MARK: - Playlist attribution

    @Test("A one-off play carries no playlist context")
    func oneOffPlayHasNoPlaylistContext() async {
        let resolver = StubResolver()
        let p = PlayerState(audio: FakeAudioOutput(), resolver: resolver)
        p.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "v")

        await eventually { resolver.calls.calls.count == 1 }

        #expect(resolver.calls.calls.first?.playlistId == nil)
    }

    @Test("Radio plays attribute to the seed's mix")
    func radioPlaysAttributeToMix() async {
        let resolver = StubResolver()
        let p = PlayerState(audio: FakeAudioOutput(), resolver: resolver,
                            radioProvider: StubRadio(tracks: tracks(["seed", "n2"])))
        p.startRadio(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")
        await eventually { p.queue.count == 2 }   // radio installed

        p.next()

        await eventually { resolver.calls.calls.count == 2 }
        #expect(resolver.calls.calls.last?.playlistId == MixIds.songRadio(for: "seed"))
    }

    @Test("Play-all plays attribute to their playlist")
    func playAllAttributesToPlaylist() async {
        let resolver = StubResolver()
        let p = PlayerState(audio: FakeAudioOutput(), resolver: resolver,
                            radioProvider: StubRadio(watchQueueTracks: tracks(["a", "b"])))

        await p.loadAndPlayAll(videoId: nil, playlistId: "PL42")

        await eventually { resolver.calls.calls.count == 1 }
        #expect(resolver.calls.calls.first?.playlistId == "PL42")
    }

    @Test("The queue's playlist context survives persistence")
    func playlistContextPersists() async {
        let store = InMemoryStore()
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(watchQueueTracks: tracks(["a"])), store: store)

        await p.loadAndPlayAll(videoId: nil, playlistId: "PL42")

        #expect(store.snapshot?.playlistId == "PL42")
    }

    // MARK: - Crossfade

    /// Fresh AppSettings on an isolated UserDefaults so tests don't share state.
    private func settings(crossfade seconds: Double?) -> AppSettings {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let s = AppSettings(defaults: suite)
        if let seconds {
            s.crossfadeEnabled = true
            s.crossfadeSeconds = seconds
        } else {
            s.crossfadeEnabled = false
        }
        return s
    }

    private func settings(preload seconds: Double) -> AppSettings {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let s = AppSettings(defaults: suite)
        s.nextTrackPreloadSeconds = seconds
        return s
    }

    @Test("Preloads the next track at the configured lead time")
    func preloadsNextTrackNearEnd() async {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), settings: settings(preload: 20))
        p.play(tracks(["a", "b"]), startAt: 0)

        audio.onProgress?(79, 100)
        #expect(audio.preloadedURL == nil)

        audio.onProgress?(81, 100)
        await eventually { audio.preloadedURL != nil }
        #expect(p.currentIndex == 0)
        #expect(audio.preloadedURL != nil)
    }

    @Test("Approaching the end with crossfade on advances to the next track")
    func crossfadeArmsNearEnd() async {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), settings: settings(crossfade: 5))
        p.play(tracks(["a", "b"]), startAt: 0)
        #expect(p.nowPlaying?.videoId == "a")

        // Within 5s of a 100s track → should arm the crossfade.
        audio.onProgress?(96, 100)
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")

        // Let the resolve + crossfade task run.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(audio.crossfadedURL != nil)
        #expect(audio.crossfadeDuration == 5)
    }

    @Test("Crossfade does not arm while far from the end")
    func crossfadeDoesNotArmEarly() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), settings: settings(crossfade: 5))
        p.play(tracks(["a", "b"]), startAt: 0)
        audio.onProgress?(40, 100)
        #expect(p.currentIndex == 0)
        #expect(audio.crossfadedURL == nil)
    }

    @Test("Crossfade off advances only on track end")
    func crossfadeDisabledDoesNotAdvance() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), settings: settings(crossfade: nil))
        p.play(tracks(["a", "b"]), startAt: 0)
        audio.onProgress?(99, 100)
        #expect(p.currentIndex == 0)
        #expect(audio.crossfadedURL == nil)
    }

    @Test("Track finishing advances to the next track in the queue")
    func finishAdvancesQueue() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver())
        p.play(tracks(["a", "b"]), startAt: 0)
        #expect(p.currentIndex == 0)

        audio.onTrackFinished?()

        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    @Test("A trailing end after a crossfade armed doesn't double-advance")
    func crossfadeEndDoesNotDoubleAdvance() {
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(),
                            settings: settings(crossfade: 5))
        p.play(tracks(["a", "b", "c"]), startAt: 0)

        // Crossfade arms and advances to "b" (loadCrossfade task not yet run).
        audio.onProgress?(96, 100)
        #expect(p.currentIndex == 1)

        // The outgoing "a" now reaches its natural end — must NOT jump to "c".
        audio.onTrackFinished?()
        #expect(p.currentIndex == 1)
        #expect(p.nowPlaying?.videoId == "b")
    }

    // MARK: - Autoplay (radio continuation)

    @Test("Autoplay: a one-off play gains a radio continuation")
    func autoplayOneOff() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: tracks(["seed", "r1", "r2"])))
        p.play(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")
        #expect(!p.canGoNext)

        await p.appendRadio(seed: "seed")

        #expect(p.queue.map(\.videoId) == ["seed", "r1", "r2"])
        #expect(p.currentIndex == 0)
        #expect(p.canGoNext)
    }

    @Test("Autoplay: does nothing when tracks already follow")
    func autoplayMidQueue() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: tracks(["r1", "r2"])))
        p.play(tracks(["a", "b", "c"]), startAt: 0)   // b & c still follow
        await p.appendRadio(seed: "a")
        #expect(p.queue.map(\.videoId) == ["a", "b", "c"])
    }

    @Test("Autoplay: the last album track gains radio after it")
    func autoplayLastTrack() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: tracks(["r1", "r2"])))
        p.play(tracks(["a", "b"]), startAt: 1)   // start on the last track
        await p.appendRadio(seed: "b")
        #expect(p.queue.map(\.videoId) == ["a", "b", "r1", "r2"])
        #expect(p.currentIndex == 1)
    }

    @Test("Autoplay: repeat-all needs no radio (queue already loops)")
    func autoplaySkippedWhenRepeating() async {
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: tracks(["r1", "r2"])))
        p.play(tracks(["a", "b"]), startAt: 1)
        p.cycleRepeatMode()   // .off → .all
        await p.appendRadio(seed: "b")
        #expect(p.queue.map(\.videoId) == ["a", "b"])
    }

    @Test("Autoplay: turned off in settings, the queue is left to end")
    func autoplayDisabled() async {
        let s = AppSettings(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        s.autoplay = false
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(),
                            radioProvider: StubRadio(tracks: tracks(["r1", "r2"])), settings: s)
        p.play(tracks(["a", "b"]), startAt: 1)
        await p.appendRadio(seed: "b")
        #expect(p.queue.map(\.videoId) == ["a", "b"])
    }

    @Test("Autoplay: an ongoing radio continues via its cursor, not a fresh single-song radio")
    func autoplayContinuesRadioCursor() async {
        let radio = StubRadio(
            tracks: tracks(["seed", "r1", "r2"]),
            continuationToken: "tok1",
            continuationPages: ["tok1": RadioPage(tracks: tracks(["r3", "r4"]), continuation: nil)]
        )
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), radioProvider: radio)
        p.play(title: "Seed", subtitle: "A", thumbnailURL: nil, videoId: "seed")

        // First backstop installs the radio and captures its continuation token.
        await p.appendRadio(seed: "seed")
        #expect(p.queue.map(\.videoId) == ["seed", "r1", "r2"])

        // Advance to the last queued track, mirroring real playback reaching it.
        p.playQueueItem(at: 2)

        // Running out again continues the SAME radio via the token, not a brand
        // new `radio(for: "r2")` request.
        await p.appendRadio(seed: "r2")
        #expect(p.queue.map(\.videoId) == ["seed", "r1", "r2", "r3", "r4"])
    }
}

// MARK: - Shuffle

@Suite("PlayerState shuffle")
@MainActor
struct PlayerStateShuffleTests {

    private func tracks(_ ids: [String]) -> [Track] {
        ids.enumerated().map { i, id in
            Track(index: i + 1, title: "T\(i)", subtitle: "A", duration: nil,
                  thumbnailURL: nil, videoId: id)
        }
    }

    private func player() -> PlayerState {
        PlayerState(audio: FakeAudioOutput(), resolver: StubResolver())
    }

    @Test("toggleShuffle keeps the current track playing and at the head")
    func shufflePinsCurrent() {
        let p = player()
        p.play(tracks(["a", "b", "c", "d", "e"]), startAt: 2)   // on "c"
        p.toggleShuffle()
        #expect(p.isShuffled)
        #expect(p.currentIndex == 0)
        #expect(p.nowPlaying?.videoId == "c")
        #expect(p.queue.first?.videoId == "c")
        // Same set of tracks, no losses or dupes.
        #expect(Set(p.queue.compactMap(\.videoId)) == ["a", "b", "c", "d", "e"])
        #expect(p.queue.count == 5)
    }

    @Test("toggling shuffle off restores the original order")
    func unshuffleRestoresOrder() {
        let p = player()
        p.play(tracks(["a", "b", "c", "d", "e"]), startAt: 0)
        p.toggleShuffle()
        p.toggleShuffle()
        #expect(!p.isShuffled)
        #expect(p.queue.map(\.videoId) == ["a", "b", "c", "d", "e"])
        #expect(p.nowPlaying?.videoId == "a")
        #expect(p.currentIndex == 0)
    }

    @Test("tracks queued while shuffled survive un-shuffling")
    func unshuffleKeepsAddedTracks() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 0)
        p.toggleShuffle()
        p.playNext(title: "X", subtitle: "A", thumbnailURL: nil, videoId: "x")
        p.toggleShuffle()
        #expect(Set(p.queue.compactMap(\.videoId)) == ["a", "b", "c", "x"])
        // Original three keep their order; the added track trails.
        #expect(p.queue.map(\.videoId) == ["a", "b", "c", "x"])
    }

    @Test("shuffle is a no-op for a one-off play (empty queue)")
    func shuffleNoOpForOneOff() {
        let p = player()
        p.play(title: "S", subtitle: "A", thumbnailURL: nil, videoId: "x")
        p.toggleShuffle()
        #expect(!p.isShuffled)
        #expect(p.queue.isEmpty)
    }

    @Test("starting a new queue resets shuffle")
    func newQueueResetsShuffle() {
        let p = player()
        p.play(tracks(["a", "b", "c"]), startAt: 0)
        p.toggleShuffle()
        #expect(p.isShuffled)
        p.play(tracks(["x", "y", "z"]), startAt: 0)
        #expect(!p.isShuffled)
        #expect(p.queue.map(\.videoId) == ["x", "y", "z"])
    }

    @Test("shuffle state persists and restores")
    func shufflePersists() {
        let store = InMemoryStore()
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        p.play(tracks(["a", "b", "c"]), startAt: 0)
        p.toggleShuffle()
        #expect(store.snapshot?.isShuffled == true)

        let restored = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        #expect(restored.isShuffled)
    }
}

// MARK: - Persistence / restore

@Suite("PlayerState persistence")
@MainActor
struct PlayerStatePersistenceTests {

    private func snapshot(
        videoId: String,
        tracks: [PersistedPlayback.StoredTrack] = [],
        index: Int = 0,
        repeatMode: PlayerState.RepeatMode = .off
    ) -> PersistedPlayback {
        PersistedPlayback(
            nowPlaying: .init(title: "T", subtitle: "S", album: "A", thumbnailURL: nil, videoId: videoId),
            tracks: tracks, currentIndex: index, repeatMode: repeatMode, album: "A"
        )
    }

    @Test("restores the last track on launch without auto-playing")
    func restoresWithoutPlaying() {
        let store = InMemoryStore()
        store.snapshot = snapshot(videoId: "v")
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        #expect(p.nowPlaying?.videoId == "v")
        #expect(!p.isPlaying)
        #expect(!p.isLoading)
    }

    @Test("playing persists a snapshot")
    func playPersists() {
        let store = InMemoryStore()
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        p.play(title: "Song", subtitle: "Artist", thumbnailURL: nil, videoId: "v")
        #expect(store.snapshot?.nowPlaying.videoId == "v")
    }

    @Test("resuming a restored track starts loading it")
    func resumeStartsLoad() {
        let store = InMemoryStore()
        store.snapshot = snapshot(videoId: "v")
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        #expect(!p.isLoading)
        p.togglePlayPause()   // first play resolves the restored track
        #expect(p.isLoading)
    }

    @Test("a restored track shows its saved position and duration before loading")
    func restoredShowsProgress() {
        let store = InMemoryStore()
        var saved = snapshot(videoId: "v")
        saved.position = 42
        saved.duration = 200
        store.snapshot = saved
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        #expect(p.currentTime == 42)
        #expect(p.duration == 200)
    }

    @Test("seeking a restored track moves its saved position without loading")
    func seekRestored() {
        let store = InMemoryStore()
        var saved = snapshot(videoId: "v")
        saved.duration = 200
        store.snapshot = saved
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), store: store)
        p.seek(to: 90)
        #expect(p.currentTime == 90)
        #expect(audio.seekedTo == nil)
        #expect(!p.isLoading)
        #expect(store.snapshot?.position == 90)
    }

    @Test("resuming a restored track starts from its saved position")
    func resumeSeeksToSavedPosition() async {
        let store = InMemoryStore()
        var saved = snapshot(videoId: "v")
        saved.position = 42
        saved.duration = 200
        store.snapshot = saved
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), store: store)
        p.togglePlayPause()
        for _ in 0..<100 where audio.loadCount == 0 { await Task.yield() }
        #expect(audio.loadCount == 1)
        #expect(audio.seekedTo == 42)
    }

    @Test("the snapshot records the playing position once loaded")
    func persistsPosition() async {
        let store = InMemoryStore()
        let audio = FakeAudioOutput()
        let p = PlayerState(audio: audio, resolver: StubResolver(), store: store)
        p.play(title: "Song", subtitle: "Artist", thumbnailURL: nil, videoId: "v")
        #expect(store.snapshot?.position == 0)
        await p.loadStream(videoId: "v")
        audio.currentTime = 30
        audio.duration = 180
        p.togglePlayPause()
        #expect(store.snapshot?.position == 30)
        #expect(store.snapshot?.duration == 180)
    }

    @Test("restores the queue and repeat mode")
    func restoresQueueAndRepeat() {
        let store = InMemoryStore()
        store.snapshot = snapshot(
            videoId: "a",
            tracks: [
                .init(index: 1, title: "A", subtitle: "x", duration: nil, thumbnailURL: nil, videoId: "a"),
                .init(index: 2, title: "B", subtitle: "y", duration: nil, thumbnailURL: nil, videoId: "b"),
            ],
            index: 0, repeatMode: .all
        )
        let p = PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), store: store)
        #expect(p.queue.map(\.videoId) == ["a", "b"])
        #expect(p.repeatMode == .all)
        #expect(p.canGoNext)
    }
}

// MARK: - Like

@Suite("PlayerState like")
@MainActor
struct PlayerStateLikeTests {

    private func player(_ like: FakeLikeProvider) -> PlayerState {
        PlayerState(audio: FakeAudioOutput(), resolver: StubResolver(), likeProvider: like)
    }

    @Test("toggleLike likes the current track and records the request")
    func likesCurrentTrack() async {
        let like = FakeLikeProvider()
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")
        #expect(p.likeStatus == .indifferent)

        p.toggleLike()
        #expect(p.likeStatus == .liked)   // optimistic, before the request resolves

        await eventually { like.calls.count == 1 }
        #expect(like.calls.first?.videoId == "vid")
        #expect(like.calls.first?.status == .liked)
    }

    @Test("toggleLike again removes the like")
    func togglesOff() async {
        let like = FakeLikeProvider()
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        p.toggleLike()
        await eventually { like.calls.count == 1 }
        p.toggleLike()
        await eventually { like.calls.count == 2 }

        #expect(p.likeStatus == .indifferent)
        #expect(like.calls.last?.status == .indifferent)
    }

    @Test("toggleLike reverts the optimistic change when the request fails")
    func revertsOnFailure() async {
        let like = FakeLikeProvider()
        like.shouldThrow = true
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        p.toggleLike()
        #expect(p.likeStatus == .liked)   // optimistic

        await eventually { !p.isUpdatingLike }
        #expect(p.likeStatus == .indifferent)   // reverted
    }

    @Test("starting a new track resets the like status")
    func resetsOnNewTrack() async {
        let like = FakeLikeProvider()
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")
        p.toggleLike()
        await eventually { like.calls.count == 1 }
        #expect(p.likeStatus == .liked)

        p.play(title: "T2", subtitle: "A", thumbnailURL: nil, videoId: "vid2")
        #expect(p.likeStatus == .indifferent)
    }

    @Test("a track's like status is seeded from the server when it starts")
    func seedsFromServer() async {
        let like = FakeLikeProvider()
        like.statuses["vid"] = .liked
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        await eventually { p.likeStatus == .liked }
        #expect(p.likeStatus == .liked)
        #expect(like.statusQueries.contains("vid"))
    }

    @Test("a user toggle is not clobbered by a slower status fetch")
    func userToggleWinsOverFetch() async {
        let like = FakeLikeProvider()
        like.statuses["vid"] = .indifferent   // server says not liked
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        // User likes the track before the background fetch can apply.
        p.toggleLike()
        #expect(p.likeStatus == .liked)   // optimistic

        // Let the fetch settle; it returns .indifferent but must not override
        // the user's like.
        await eventually { !like.statusQueries.isEmpty && !p.isUpdatingLike }
        #expect(p.likeStatus == .liked)
    }

    @Test("knownLikeStatus falls back to the rating parsed from the row")
    func knownLikeStatusUsesParsedDefault() async {
        let like = FakeLikeProvider()
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        // A non-current row with no cached toggle reports the response's rating.
        #expect(p.knownLikeStatus(for: "other", default: .liked) == .liked)
        #expect(p.knownLikeStatus(for: "other") == .indifferent)   // no default given
        // The current track's live status wins over any passed default.
        #expect(p.knownLikeStatus(for: "vid", default: .liked) == .indifferent)
    }

    @Test("likeStatusIfKnown returns nil when the rating isn't known")
    func likeStatusIfKnownNilWhenUnknown() async {
        let like = FakeLikeProvider()
        let p = player(like)
        // Nothing playing, nothing cached → unknown (so the Like entry is hidden).
        #expect(p.likeStatusIfKnown(for: "vid") == nil)

        // A rating learned this session becomes known.
        p.setLikeStatus(for: "vid", to: .liked)
        #expect(p.likeStatusIfKnown(for: "vid") == .liked)
    }

    @Test("setLikeStatus updates a non-current track without touching the current one")
    func setLikeStatusForOtherTrack() async {
        let like = FakeLikeProvider()
        let p = player(like)
        p.play(title: "T", subtitle: "A", thumbnailURL: nil, videoId: "vid")

        p.setLikeStatus(for: "other", to: .liked)
        #expect(p.knownLikeStatus(for: "other") == .liked)   // cached optimistically
        #expect(p.likeStatus == .indifferent)                // current track untouched

        await eventually { like.calls.contains { $0.videoId == "other" && $0.status == .liked } }
    }
}

// MARK: - AudioPlayer (real instance, no playback required)

@Suite("AudioPlayer")
@MainActor
struct AudioPlayerTests {

    @Test("seek updates currentTime even with no loaded item")
    func seekUpdatesTime() {
        let player = AudioPlayer()
        player.seek(to: 30)
        #expect(player.currentTime == 30)
    }

    @Test("togglePlayPause is a no-op with nothing loaded")
    func toggleNoOpWhenEmpty() {
        let player = AudioPlayer()
        player.togglePlayPause()
        #expect(player.isPlaying == false)
    }
}

// MARK: - Subtitle cleaning (byline shown in the now-playing bar / queue)

@Suite("PlayerState subtitle")
@MainActor
struct PlayerStateSubtitleTests {

    @Test("drops view count and duration from a video byline")
    func stripsVideoByline() {
        #expect(PlayerState.withoutTypeLabel("femtanyl • 3.5M views • 2:46") == "femtanyl")
    }

    @Test("still strips a leading type label")
    func stripsTypeLabel() {
        #expect(PlayerState.withoutTypeLabel("Song • Artist • Album") == "Artist • Album")
    }

    @Test("keeps a plain artist • album byline intact")
    func keepsArtistAlbum() {
        #expect(PlayerState.withoutTypeLabel("Artist • Album • 2023") == "Artist • Album • 2023")
    }

    @Test("handles longer durations and comma-grouped view counts")
    func stripsVariants() {
        #expect(PlayerState.withoutTypeLabel("Artist • 1,234 views • 1:02:30") == "Artist")
    }

    @Test("does not treat a year as a duration")
    func keepsYear() {
        #expect(PlayerState.withoutTypeLabel("Artist • 2023") == "Artist • 2023")
    }
}
