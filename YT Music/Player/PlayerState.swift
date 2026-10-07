//
//  PlayerState.swift
//  YT Music
//
//  App-wide playback state. Resolves a track's stream URL (via StreamResolver)
//  and drives an AudioPlayer, exposing what the now-playing UI needs.
//

import SwiftUI

/// A single fetched batch of a mix/radio: its tracks, plus a continuation
/// token to fetch the mix's next batch (nil once it's exhausted).
struct RadioPage: Sendable {
    let tracks: [Track]
    let continuation: String?
}

/// Supplies an endless radio queue for a seed video. Abstracted so PlayerState
/// can be driven by a fake in tests (no network).
protocol RadioProviding: Sendable {
    func radio(for videoId: String) async throws -> RadioPage
    /// Continues an already-fetched radio from its last batch, instead of
    /// starting a new, unrelated single-song radio.
    func continueRadio(_ token: String) async throws -> RadioPage
    /// The ordered watch queue for a `next` endpoint (a "Play all" button, or a
    /// playlist/album radio). Defaults to the plain radio for `videoId`.
    func watchQueue(videoId: String, playlistId: String) async throws -> [Track]
}

extension RadioProviding {
    func watchQueue(videoId: String, playlistId: String) async throws -> [Track] {
        try await radio(for: videoId).tracks
    }
}

extension InnerTubeClient: RadioProviding {}

/// Playlist-id builders shared by the playback paths (the queue context the
/// player request reports so listens attribute to their source).
enum MixIds {
    /// A song's auto-generated radio: `RDAMVM<videoId>`.
    static func songRadio(for videoId: String) -> String { "RDAMVM\(videoId)" }
    /// A playlist's or album's radio: `RDAMPL<playlistId>`.
    static func playlistRadio(for playlistId: String) -> String { "RDAMPL\(playlistId)" }
}

@MainActor
@Observable
final class PlayerState {
    struct NowPlaying: Equatable, Codable {
        var title: String
        var subtitle: String
        var album: String
        var thumbnailURL: URL?
        var videoId: String
        /// Navigable artist links (empty when unknown, e.g. a one-off play).
        var artists: [EntityLink] = []
        /// Navigable album link, if known.
        var albumLink: EntityLink?

        init(title: String, subtitle: String, album: String, thumbnailURL: URL?,
             videoId: String, artists: [EntityLink] = [], albumLink: EntityLink? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.album = album
            self.thumbnailURL = thumbnailURL
            self.videoId = videoId
            self.artists = artists
            self.albumLink = albumLink
        }

        // Custom decode so snapshots persisted before links existed still load
        // (the new keys default to empty rather than failing the whole restore).
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decode(String.self, forKey: .subtitle)
            album = try c.decode(String.self, forKey: .album)
            thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
            videoId = try c.decode(String.self, forKey: .videoId)
            artists = try c.decodeIfPresent([EntityLink].self, forKey: .artists) ?? []
            albumLink = try c.decodeIfPresent(EntityLink.self, forKey: .albumLink)
        }
    }

    /// How playback continues at the end of a track.
    enum RepeatMode: String, Codable {
        case off   // stop at the end of the queue
        case all   // loop the whole queue
        case one   // loop the current track
    }

    private(set) var nowPlaying: NowPlaying?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var repeatMode: RepeatMode = .off
    /// Whether the queue is currently playing in shuffled order.
    private(set) var isShuffled = false
    /// The queue's order captured when shuffle was turned on, so turning it off
    /// restores the original sequence. Empty when not shuffled.
    private var orderBeforeShuffle: [Track] = []

    /// The current track's like rating. When a track starts it's seeded to
    /// `.indifferent` and then refreshed from the server (`fetchLikeStatus`);
    /// `toggleLike` updates it optimistically.
    private(set) var likeStatus: LikeStatus = .indifferent
    /// True while a like request is in flight (disables the button).
    private(set) var isUpdatingLike = false
    /// Set once the user toggles the like for the current track, so a slower
    /// background status fetch doesn't clobber their action. Reset per track.
    private var likeInteracted = false
    /// Like ratings learned for tracks other than the one playing, so a row's
    /// context menu can offer "Remove from Likes" without a fresh fetch. Keyed
    /// by videoId; the current track's live `likeStatus` takes precedence.
    private var likeStatusCache: [String: LikeStatus] = [:]

    /// The playable tracks (those with a videoId) for the current context, and
    /// the index within it that is currently playing. Empty for one-off plays.
    private(set) var queue: [Track] = []
    private(set) var currentIndex = 0
    private var albumContext = ""
    /// The playlist the current queue was started from (a "Play all" playlist
    /// or a radio's mix id), when known — sent with the player request so the
    /// listen is attributed to it. nil for one-off plays and track listings
    /// with no known playlist id.
    private var playlistContext: String?
    /// The continuation token to fetch the next batch of the radio currently
    /// backing the queue, if any. Cleared whenever the queue is rebuilt from
    /// something other than that radio.
    private var radioContinuation: String?

    private let audio: AudioOutput
    private let resolver: StreamResolving
    private let radioProvider: RadioProviding
    private let likeProvider: LikeProviding
    private let historyReporter: WatchHistoryReporting
    private let store: PlaybackStore?
    private let settings: AppSettings?
    private var loadTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?
    private var likeFetchTask: Task<Void, Never>?
    /// True after restoring a snapshot until the user actually starts playback:
    /// the track is shown but no stream is loaded yet, so the first play resolves
    /// and starts it rather than toggling an empty engine.
    private var awaitingResume = false
    /// The restored track's saved position and duration, shown until it's resumed.
    private var restoredPosition: Double = 0
    private var restoredDuration: Double = 0
    /// The stream the engine is playing, so a mid-track failure can be
    /// reported to the resolver.
    private var currentStream: ResolvedStream?
    /// Where the current track's stream last died, so a reload that fails
    /// again without progress skips the track instead of looping.
    private var lastStreamFailure: (videoId: String, position: Double)?
    /// Set when the current track's stream died while paused: the next play
    /// reloads it from here.
    private var reloadOnResume: Double?
    /// How much further (seconds) a reloaded stream must get before another
    /// failure is reloaded again rather than skipped.
    private static let streamFailureProgress: Double = 10
    /// Position at the last progress-driven snapshot, to throttle saves.
    private var lastPersistedPosition: Double = 0
    /// Set once per track when a crossfade into the next track has been kicked
    /// off, so the approaching-end window only triggers it once. Re-armed when a
    /// new track starts playing from the top.
    private var crossfadeArmed = false
    /// True between arming a crossfade and the incoming track actually taking
    /// over, so the outgoing track's natural end doesn't double-advance.
    private var crossfadeLoading = false
    private var preparedVideoId: String?
    private var preparedStream: ResolvedStream?
    private var preloadTask: Task<Void, Never>?

    /// The current track's resolved stream, kept so its history beacons can be
    /// fired from real playback progress (not at load). nil until resolved.
    private var pendingHistory: ResolvedStream?
    /// Set once the `playback` beacon has fired for the current track.
    private var playbackPinged = false
    /// Position (seconds) of the last `watchtime` heartbeat; -1 before the first.
    private var lastWatchtimeAt: Double = -1

    /// Notified whenever the now-playing track or play/pause state changes, so
    /// plugins (Discord Rich Presence, etc.) can mirror it. Carries nil when
    /// playback stops.
    var onPlaybackChange: ((PlaybackSnapshot?) -> Void)?

    /// Live audio spectrum for the immersive visualizer (nil under a test fake).
    var spectrum: SpectrumAnalyzer? { audio.spectrum }

    init(audio: AudioOutput? = nil, resolver: StreamResolving? = nil,
         radioProvider: RadioProviding? = nil, store: PlaybackStore? = nil,
         settings: AppSettings? = nil, historyReporter: WatchHistoryReporting? = nil,
         likeProvider: LikeProviding? = nil) {
        self.audio = audio ?? AudioPlayer()
        self.resolver = resolver ?? StreamResolver.shared
        self.radioProvider = radioProvider ?? InnerTubeClient.shared
        self.likeProvider = likeProvider ?? InnerTubeClient.shared
        self.historyReporter = historyReporter ?? InnerTubeClient.shared
        self.store = store
        self.settings = settings

        self.audio.onTrackFinished = { [weak self] in self?.handleTrackFinished() }
        self.audio.onStreamFailed = { [weak self] position, error in self?.handleStreamFailure(at: position, error: error) }
        self.audio.onNext = { [weak self] in self?.next() }
        self.audio.onPrevious = { [weak self] in self?.previous() }
        self.audio.onTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        self.audio.onPlaybackStart = { [weak self] in self?.emitPlaybackChange() }
        self.audio.onProgress = { [weak self] current, duration in
            self?.handleProgress(current: current, duration: duration)
        }

        // Drive the audio engine's equalizer from settings: apply the persisted
        // configuration now, and re-apply whenever the user changes it.
        if let settings {
            self.audio.applyEqualizer(settings.equalizerSettings)
            settings.onEqualizerChange = { [weak self] eq in self?.audio.applyEqualizer(eq) }
            self.audio.volume = settings.volume
            self.audio.normalizesVolume = settings.volumeNormalization
            settings.onVolumeNormalizationChange = { [weak self] in self?.audio.normalizesVolume = $0 }
        }

        restore()
    }

    // MARK: - Playback intent

    /// Plays a single track with no surrounding queue (next/previous become no-ops).
    /// Not part of any album, so a stale album context from a previous play is
    /// dropped along with the old queue.
    func play(title: String, subtitle: String, album: String = "", thumbnailURL: URL?, videoId: String,
              artists: [EntityLink] = [], albumLink: EntityLink? = nil) {
        queue = []
        currentIndex = 0
        albumContext = ""
        playlistContext = nil
        radioContinuation = nil
        resetShuffle()
        startTrack(title: title, subtitle: subtitle, album: album,
                   thumbnailURL: thumbnailURL, videoId: videoId,
                   artists: artists, albumLink: albumLink)
    }

    func play(_ track: Track, album: String = "") {
        guard let videoId = track.videoId else { return }
        play(
            title: track.title,
            subtitle: track.subtitle,
            album: album,
            thumbnailURL: track.thumbnailURL,
            videoId: videoId,
            artists: track.artists,
            albumLink: track.albumLink
        )
    }

    /// Plays `tracks` as a queue, starting at the track at `startAt` (an index
    /// into `tracks`). Unplayable tracks (no videoId) are filtered out; if the
    /// requested track isn't playable, the next playable one is used.
    /// `playlistId` is the playlist the listing belongs to, when the caller
    /// knows it — plays are then attributed to that playlist.
    func play(_ tracks: [Track], startAt: Int, album: String = "", playlistId: String? = nil) {
        let playable = tracks.filter { $0.videoId != nil }
        guard !playable.isEmpty else { return }

        // Map the requested position to the filtered queue: the requested track,
        // else the first playable track at or after it, else the first overall.
        let startTrack = (startAt..<tracks.count).lazy
            .map { tracks[$0] }
            .first { $0.videoId != nil }
        let index = startTrack
            .flatMap { target in playable.firstIndex { $0.id == target.id } } ?? 0

        queue = playable
        albumContext = album
        playlistContext = playlistId
        currentIndex = index
        radioContinuation = nil
        resetShuffle()
        startCurrent()
    }

    /// Inserts a track to play right after the current one. With nothing
    /// playing it just plays the track. For a one-off play (empty queue) it
    /// seeds the queue with the current track so the inserted track follows it
    /// (and `previous` still returns to it).
    func playNext(title: String, subtitle: String, thumbnailURL: URL?, videoId: String,
                  artists: [EntityLink] = [], albumLink: EntityLink? = nil) {
        guard let nowPlaying else {
            play(title: title, subtitle: subtitle, thumbnailURL: thumbnailURL, videoId: videoId,
                 artists: artists, albumLink: albumLink)
            return
        }

        let track = Track(index: 0, title: title, subtitle: subtitle, duration: nil,
                          thumbnailURL: thumbnailURL, videoId: videoId,
                          artists: artists, albumLink: albumLink)

        if queue.isEmpty {
            let seedTrack = Track(index: 1, title: nowPlaying.title, subtitle: nowPlaying.subtitle,
                                  duration: nil, thumbnailURL: nowPlaying.thumbnailURL,
                                  videoId: nowPlaying.videoId, artists: nowPlaying.artists,
                                  albumLink: nowPlaying.albumLink)
            queue = [seedTrack, track]
            currentIndex = 0
        } else {
            queue.insert(track, at: currentIndex + 1)
        }
        persist()
    }

    /// "Start radio": plays the seed track immediately, then fetches an endless
    /// radio queue from it and installs that as the queue (so next/previous walk
    /// the radio) without interrupting the already-playing seed. If the seed is
    /// already the track playing, playback is left untouched (no restart from
    /// 0:00) — only the queue is rebuilt into a radio around it.
    func startRadio(title: String, subtitle: String, thumbnailURL: URL?, videoId: String,
                    artists: [EntityLink] = [], albumLink: EntityLink? = nil) {
        if nowPlaying?.videoId != videoId {
            play(title: title, subtitle: subtitle, thumbnailURL: thumbnailURL, videoId: videoId,
                 artists: artists, albumLink: albumLink)
        }
        radioTask?.cancel()
        radioTask = Task { await installRadio(seed: videoId) }
    }

    /// Fetches the radio queue for `videoId` and installs it (keeping the seed
    /// playing). Split out from `startRadio` so tests can await it directly.
    func installRadio(seed videoId: String) async {
        guard let page = try? await radioProvider.radio(for: videoId) else { return }
        let playable = page.tracks.filter { $0.videoId != nil }
        // Only install if the user is still on the seed track.
        guard !playable.isEmpty, let nowPlaying, nowPlaying.videoId == videoId else { return }
        radioContinuation = page.continuation
        // The queue is now the seed's radio — attribute plays to the mix.
        playlistContext = MixIds.songRadio(for: videoId)
        if let index = playable.firstIndex(where: { $0.videoId == videoId }) {
            queue = playable
            currentIndex = index
        } else {
            // Some radio responses (premieres, live videos) omit the seed itself —
            // keep it as the queue's head so the row marked "current" still
            // matches what's actually playing, instead of defaulting to whatever
            // track happens to come first.
            let seedTrack = Track(index: 1, title: nowPlaying.title, subtitle: nowPlaying.subtitle,
                                  duration: nil, thumbnailURL: nowPlaying.thumbnailURL, videoId: videoId,
                                  artists: nowPlaying.artists, albumLink: nowPlaying.albumLink)
            queue = [seedTrack] + playable
            currentIndex = 0
        }
        albumContext = ""
        resetShuffle()
        persist()
    }

    /// "Play all" for a shelf header button: fetches the button's watch queue (a
    /// real playlist/album) and plays it as the queue. Unlike a single-seed play
    /// this yields real per-track metadata (title/artist/artwork) instead of the
    /// button's own label.
    func playAll(videoId: String?, playlistId: String, shuffled: Bool = false) {
        loadTask?.cancel()
        radioTask?.cancel()
        radioTask = Task { await loadAndPlayAll(videoId: videoId, playlistId: playlistId, shuffled: shuffled) }
    }

    /// Fetches then plays a "Play all" queue, starting at the seed track when it's
    /// present in the returned queue. Split out so tests can await it directly.
    func loadAndPlayAll(videoId: String?, playlistId: String, shuffled: Bool = false) async {
        guard let tracks = try? await radioProvider.watchQueue(videoId: videoId ?? "", playlistId: playlistId),
              !tracks.isEmpty else { return }
        let start = shuffled
            ? Int.random(in: tracks.indices)
            : videoId.flatMap { id in tracks.firstIndex { $0.videoId == id } } ?? 0
        play(tracks, startAt: start, playlistId: playlistId)
        if shuffled { toggleShuffle() }
    }

    /// Queues a playlist/album right after the current track (`next`) or at the
    /// end of the queue. With nothing playing it just plays it.
    func enqueueAll(playlistId: String, next: Bool) {
        Task { await loadAndEnqueueAll(playlistId: playlistId, next: next) }
    }

    /// Fetches then queues a playlist/album. Split out so tests can await it.
    func loadAndEnqueueAll(playlistId: String, next: Bool) async {
        guard let tracks = try? await radioProvider.watchQueue(videoId: "", playlistId: playlistId) else { return }
        let playable = tracks.filter { $0.videoId != nil }
        guard !playable.isEmpty else { return }
        guard let nowPlaying else {
            play(playable, startAt: 0, playlistId: playlistId)
            return
        }
        if queue.isEmpty {
            let seedTrack = Track(index: 1, title: nowPlaying.title, subtitle: nowPlaying.subtitle,
                                  duration: nil, thumbnailURL: nowPlaying.thumbnailURL,
                                  videoId: nowPlaying.videoId, artists: nowPlaying.artists,
                                  albumLink: nowPlaying.albumLink)
            queue = [seedTrack]
            currentIndex = 0
        }
        queue.insert(contentsOf: playable, at: next ? currentIndex + 1 : queue.count)
        persist()
    }

    /// Autoplay: when the current track has nothing after it (a one-off play, or
    /// the last track of an album/playlist) and repeat is off, fetch a radio
    /// based on it and append it so playback keeps going. No-op when more tracks
    /// already follow or the user explicitly started a radio.
    private func maybeContinueWithRadio() {
        guard autoplayEnabled, repeatMode == .off, currentIndex >= queue.count - 1,
              let seed = nowPlaying?.videoId else { return }
        radioTask?.cancel()
        radioTask = Task { await appendRadio(seed: seed) }
    }

    private var autoplayEnabled: Bool { settings?.autoplay ?? true }

    /// Fetches a radio for `videoId` and appends its (new) tracks to the queue.
    /// Continues the radio already backing the queue via its token (the real
    /// "keep this mix going" path) when one is held; otherwise falls back to a
    /// fresh single-song radio (e.g. autoplay off the end of an album, which
    /// never held a radio continuation to begin with).
    /// Split out so tests can await it directly. Re-checks state after the fetch
    /// in case the user moved on meanwhile.
    func appendRadio(seed videoId: String) async {
        let page: RadioPage?
        // A fresh radio (autoplay off a one-off/album) re-attributes the queue
        // to the new mix; continuing an existing one keeps its attribution.
        let isFreshRadio = radioContinuation == nil
        if let token = radioContinuation {
            page = try? await radioProvider.continueRadio(token)
        } else {
            page = try? await radioProvider.radio(for: videoId)
        }
        guard let page else { return }
        // Still on the seed, still nothing queued after it, still not repeating.
        guard autoplayEnabled, nowPlaying?.videoId == videoId, repeatMode == .off,
              currentIndex >= queue.count - 1 else { return }

        let existing = Set(queue.compactMap(\.videoId))
        let continuation = page.tracks.filter { track in
            guard let id = track.videoId else { return false }
            return id != videoId && !existing.contains(id)
        }
        guard !continuation.isEmpty else { return }

        radioContinuation = page.continuation
        // The appended tracks are radio, not part of any album.
        albumContext = ""
        if isFreshRadio { playlistContext = MixIds.songRadio(for: videoId) }
        if queue.isEmpty {
            // One-off play: the seed becomes the head of a fresh queue, radio
            // follows it (so `previous` still returns to the seed).
            guard let nowPlaying else { return }
            let seedTrack = Track(index: 1, title: nowPlaying.title, subtitle: nowPlaying.subtitle,
                                  duration: nil, thumbnailURL: nowPlaying.thumbnailURL, videoId: videoId,
                                  artists: nowPlaying.artists, albumLink: nowPlaying.albumLink)
            queue = [seedTrack] + continuation
            currentIndex = 0
        } else {
            queue.append(contentsOf: continuation)
        }
        persist()
    }

    // MARK: - Transport

    var isPlaying: Bool { audio.isPlaying }
    var currentTime: Double { awaitingResume ? restoredPosition : audio.currentTime }
    var duration: Double { awaitingResume ? restoredDuration : audio.duration }
    var bufferedTime: Double { audio.bufferedTime }

    /// Output volume, 0...1. Forwards to the engine and persists via settings.
    var volume: Double {
        get { audio.volume }
        set {
            audio.volume = newValue
            settings?.volume = newValue
        }
    }

    var canGoNext: Bool { !queue.isEmpty && (currentIndex + 1 < queue.count || repeatMode == .all) }
    var canGoPrevious: Bool { !queue.isEmpty && (currentIndex > 0 || repeatMode == .all) }

    func togglePlayPause() {
        // A track restored from a previous session isn't loaded yet — the first
        // play resolves and starts it.
        if awaitingResume {
            resumeRestored()
            return
        }
        // The paused track's stream died meanwhile; play reloads it.
        if let position = reloadOnResume {
            reloadOnResume = nil
            reloadCurrentStream(at: position)
            return
        }
        audio.togglePlayPause()
        persist()
        emitPlaybackChange()
    }
    func seek(to seconds: Double) {
        if reloadOnResume != nil { reloadOnResume = max(0, seconds) }
        // Moves where the not-yet-loaded restored track will resume.
        if awaitingResume {
            restoredPosition = restoredDuration > 0 ? min(max(0, seconds), restoredDuration) : max(0, seconds)
            persist()
            return
        }
        audio.seek(to: seconds)
        emitPlaybackChange()   // keep plugin-presence timestamps in sync
    }

    func next() {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            return
        }
        startCurrent()
    }

    func previous() {
        // Match the common player behaviour: restart the current track if we're
        // more than a few seconds in, otherwise step back.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        startCurrent()
    }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        persist()
    }

    /// Toggles shuffle. Turning it on shuffles everything after the current track
    /// (which stays playing as the new queue head); turning it off restores the
    /// pre-shuffle order, keeping the current track current. Tracks queued while
    /// shuffled (radio/play-next) are preserved at the end on restore. No-op with
    /// an empty queue (one-off plays can't shuffle).
    func toggleShuffle() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let current = queue[currentIndex]
        if isShuffled {
            var restored = orderBeforeShuffle
            let known = Set(orderBeforeShuffle.map(\.id))
            restored += queue.filter { !known.contains($0.id) }
            queue = restored
            orderBeforeShuffle = []
            isShuffled = false
        } else {
            orderBeforeShuffle = queue
            var rest = queue
            rest.remove(at: currentIndex)
            queue = [current] + rest.shuffled()
            isShuffled = true
        }
        currentIndex = queue.firstIndex { $0.id == current.id } ?? 0
        persist()
    }

    /// Clears shuffle state when a brand-new queue replaces the current one, so a
    /// fresh album/playlist plays in its natural order.
    private func resetShuffle() {
        isShuffled = false
        orderBeforeShuffle = []
    }

    // MARK: - Queue editing

    /// Jumps to and plays the track at `index` (tapping a row in the queue
    /// panel). No-op for an out-of-range index.
    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        startCurrent()
    }

    /// Removes the track at `index`. Removing the current track advances to
    /// whatever slides into its place (or stops if it was the last); removing an
    /// earlier track keeps the current one playing.
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let removed = queue.remove(at: index)
        orderBeforeShuffle.removeAll { $0.id == removed.id }

        if index == currentIndex {
            if queue.isEmpty {
                currentIndex = 0
            } else {
                if currentIndex >= queue.count { currentIndex = queue.count - 1 }
                startCurrent()
                return
            }
        } else if index < currentIndex {
            currentIndex -= 1
        }
        persist()
    }

    /// Reorders the queue (drag-to-reorder in the queue panel), keeping the
    /// currently-playing track current wherever it lands.
    func moveInQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        let current = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        queue.move(fromOffsets: source, toOffset: destination)
        if let current, let index = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = index
        }
        persist()
    }

    /// Likes the current track, or removes the like if it's already liked.
    /// Updates the UI optimistically and reverts if the request fails (e.g.
    /// signed out). No-op while a previous like request is still in flight.
    func toggleLike() {
        guard let videoId = nowPlaying?.videoId, !isUpdatingLike else { return }
        likeInteracted = true
        let previous = likeStatus
        let target: LikeStatus = likeStatus == .liked ? .indifferent : .liked
        likeStatus = target
        likeStatusCache[videoId] = target
        isUpdatingLike = true
        Task {
            defer { isUpdatingLike = false }
            do {
                try await likeProvider.setLikeStatus(videoId: videoId, status: target)
            } catch {
                // Revert only if we're still on the same track.
                likeStatusCache[videoId] = previous
                if nowPlaying?.videoId == videoId { likeStatus = previous }
            }
        }
    }

    /// Refreshes `likeStatus` from the server for `videoId`. Applied only if the
    /// user is still on that track and hasn't toggled it meanwhile (their action
    /// wins over a slower fetch). No-op result when signed out.
    private func fetchLikeStatus(for videoId: String) {
        likeFetchTask?.cancel()
        likeFetchTask = Task {
            guard let status = try? await likeProvider.likeStatus(for: videoId) else { return }
            guard !Task.isCancelled else { return }
            likeStatusCache[videoId] = status
            guard nowPlaying?.videoId == videoId, !likeInteracted else { return }
            likeStatus = status
        }
    }

    /// The known like rating for a row's context menu, without a network call:
    /// the live status for the current track (so in-session toggles show), else
    /// an in-session cached toggle, else `fallback` — the rating the row's
    /// response already carried.
    func knownLikeStatus(for videoId: String, default fallback: LikeStatus = .indifferent) -> LikeStatus {
        if videoId == nowPlaying?.videoId { return likeStatus }
        return likeStatusCache[videoId] ?? fallback
    }

    /// The rating for `videoId` only when we actually know it — the current
    /// track's live rating, or one learned this session — else nil. Unlike
    /// `knownLikeStatus` it invents no `.indifferent` fallback, so callers can
    /// tell "not liked" apart from "unknown".
    func likeStatusIfKnown(for videoId: String) -> LikeStatus? {
        if videoId == nowPlaying?.videoId { return likeStatus }
        return likeStatusCache[videoId]
    }

    /// Sets a specific track's like rating (from a row's context menu, which may
    /// target a track other than the one playing). Mirrors the change onto the
    /// now-playing UI, and reverts it, when it's the current track.
    func setLikeStatus(for videoId: String, to status: LikeStatus) {
        let isCurrent = videoId == nowPlaying?.videoId
        let previous = knownLikeStatus(for: videoId)
        if isCurrent {
            likeInteracted = true
            likeStatus = status
        }
        likeStatusCache[videoId] = status
        Task {
            do {
                try await likeProvider.setLikeStatus(videoId: videoId, status: status)
            } catch {
                likeStatusCache[videoId] = previous
                if isCurrent, nowPlaying?.videoId == videoId { likeStatus = previous }
            }
        }
    }

    /// Reloads a track whose stream died mid-way (typically a URL that expired
    /// during a long pause) at the position reached, after telling the resolver
    /// which stream failed. If it dies again without getting further, it is
    /// skipped as before.
    private func handleStreamFailure(at position: Double, error: Error?) {
        // Only the stream of the track on screen counts: while another track
        // loads, the engine may still hold the outgoing one, dying late.
        guard !crossfadeLoading, !isLoading, let failed = currentStream,
              let videoId = nowPlaying?.videoId, failed.videoId == nil || failed.videoId == videoId else { return }
        currentStream = nil
        if let last = lastStreamFailure, last.videoId == videoId,
           position < last.position + Self.streamFailureProgress {
            Task { await resolver.streamFailed(failed, error: error) }
            // Give up on this track. Not via handleTrackFinished: repeat-one
            // would restart the dead item, and it wasn't listened to the end.
            next()
            return
        }
        lastStreamFailure = (videoId, position)
        // Loading starts playback, so a track that died while paused waits
        // for the next play instead of starting on its own.
        if audio.isPlaying {
            reloadCurrentStream(at: position, after: (failed, error))
        } else {
            Task { await resolver.streamFailed(failed, error: error) }
            reloadOnResume = position
        }
    }

    /// Reloads the current track at `position`. A failed stream is reported
    /// first, so the resolver can avoid its cause on this very resolve.
    private func reloadCurrentStream(at position: Double, after failed: (stream: ResolvedStream, error: Error?)? = nil) {
        guard let videoId = nowPlaying?.videoId else { return }
        if preparedVideoId == videoId {
            preparedVideoId = nil
            preparedStream = nil
        }
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            if let failed { await resolver.streamFailed(failed.stream, error: failed.error) }
            await loadStream(videoId: videoId, startAt: position, keepingHistory: true)
        }
    }

    private func handleTrackFinished() {
        // A crossfade has already advanced the queue and is loading the next
        // track; the just-ended track is the one we faded out of, so ignore its
        // end rather than advancing a second time.
        if crossfadeLoading { return }
        reportFinalWatchtime()
        switch repeatMode {
        case .one:        audio.restart()
        case .off, .all:  next()   // next() only wraps when .all; otherwise stops
        }
    }

    // MARK: - Persistence

    /// Loads the last session's snapshot into a paused, ready-to-resume state.
    private func restore() {
        guard let snapshot = store?.load() else { return }
        nowPlaying = snapshot.nowPlaying
        queue = snapshot.tracks.map(\.track)
        currentIndex = queue.isEmpty ? 0 : min(max(0, snapshot.currentIndex), queue.count - 1)
        repeatMode = snapshot.repeatMode
        albumContext = snapshot.album
        playlistContext = snapshot.playlistId
        isShuffled = snapshot.isShuffled
        restoredPosition = snapshot.position
        restoredDuration = snapshot.duration
        awaitingResume = true
    }

    private func persist() {
        guard let store else { return }
        guard let nowPlaying else { store.save(nil); return }
        store.save(PersistedPlayback(
            nowPlaying: nowPlaying,
            tracks: queue.map(PersistedPlayback.StoredTrack.init),
            currentIndex: currentIndex,
            repeatMode: repeatMode,
            album: albumContext,
            isShuffled: isShuffled,
            playlistId: playlistContext,
            // Mid-load, the engine still reports the previous track's times.
            position: isLoading ? 0 : currentTime,
            duration: isLoading ? 0 : duration
        ))
    }

    /// Starts the restored track (resolving its stream for the first time),
    /// from its saved position.
    private func resumeRestored() {
        let position = restoredPosition > 0 ? restoredPosition : nil
        if !queue.isEmpty {
            startCurrent(at: position)
        } else if let nowPlaying {
            startTrack(title: nowPlaying.title, subtitle: nowPlaying.subtitle,
                       album: nowPlaying.album, thumbnailURL: nowPlaying.thumbnailURL,
                       videoId: nowPlaying.videoId,
                       artists: nowPlaying.artists, albumLink: nowPlaying.albumLink,
                       startAt: position)
        }
    }

    // MARK: - Loading

    private func startCurrent(at position: Double? = nil) {
        guard queue.indices.contains(currentIndex),
              let videoId = queue[currentIndex].videoId else { return }
        let track = queue[currentIndex]
        startTrack(title: track.title, subtitle: track.subtitle, album: albumContext,
                   thumbnailURL: track.thumbnailURL, videoId: videoId,
                   artists: track.artists, albumLink: track.albumLink, startAt: position)
    }

    private func startTrack(title: String, subtitle: String, album: String,
                            thumbnailURL: URL?, videoId: String,
                            artists: [EntityLink] = [], albumLink: EntityLink? = nil,
                            startAt position: Double? = nil) {
        awaitingResume = false
        lastStreamFailure = nil
        reloadOnResume = nil
        currentStream = nil
        lastPersistedPosition = 0
        crossfadeArmed = false
        crossfadeLoading = false
        pendingHistory = nil
        playbackPinged = false
        lastWatchtimeAt = -1
        likeStatus = .indifferent
        likeInteracted = false
        nowPlaying = NowPlaying(
            title: title,
            subtitle: subtitle,
            album: album,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            artists: artists,
            albumLink: albumLink
        )
        loadError = nil
        isLoading = true
        if preparedVideoId != videoId {
            preloadTask?.cancel()
            preloadTask = nil
            preparedVideoId = nil
            preparedStream = nil
        }
        persist()
        emitPlaybackChange()
        fetchLikeStatus(for: videoId)

        loadTask?.cancel()
        loadTask = Task { await loadStream(videoId: videoId, startAt: position) }

        maybeContinueWithRadio()
    }

    /// Resolves the stream and hands it to the audio engine. Split out from
    /// `startTrack` so tests can await it directly (no Task race).
    /// `keepingHistory` reloads the playing track without reporting it to
    /// history a second time.
    func loadStream(videoId: String, startAt position: Double? = nil, keepingHistory: Bool = false) async {
        do {
            let preferences = settings?.streamPreferences ?? StreamPreferences()
            let resolved: ResolvedStream
            let usedPreloadedStream = preparedVideoId == videoId
            if usedPreloadedStream, let preparedStream {
                resolved = preparedStream
                self.preparedVideoId = nil
                self.preparedStream = nil
            } else {
                resolved = try await resolver.audioStream(videoId: videoId, playlistId: playlistContext,
                                                          preferences: preferences)
            }
            if Task.isCancelled { return }
            let metadata = NowPlayingMetadata(
                title: nowPlaying?.title ?? "",
                artist: Self.cleanedArtist(nowPlaying),
                album: nowPlaying?.album ?? "",
                artworkURL: nowPlaying?.thumbnailURL,
                knownDuration: resolved.duration,
                loudnessDb: resolved.loudnessDb
            )
            if usedPreloadedStream {
                audio.loadPreloaded(url: resolved.url, metadata: metadata)
            } else {
                audio.load(url: resolved.url, metadata: metadata)
            }
            if let position { audio.seek(to: position) }
            isLoading = false
            emitPlaybackChange()
            // Don't ping history yet — the real client reports a live position once
            // the listener is actually into the track. Arm it; handleProgress fires.
            currentStream = resolved
            if !keepingHistory { armHistory(resolved) }
        } catch {
            if !Task.isCancelled {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Arms history reporting for a freshly loaded stream. The beacons fire from
    /// real playback progress (see `reportHistoryProgress`), mirroring the web
    /// client, rather than at load time. No-op (logs) if the player response
    /// carried no stats URL.
    private func armHistory(_ resolved: ResolvedStream) {
        // Stats URLs still on their way: arm once they arrive, unless another
        // track is playing by then.
        if let late = resolved.lateTracking {
            let videoId = nowPlaying?.videoId
            Task { [weak self] in
                let tracking = await late.value
                guard let self, self.nowPlaying?.videoId == videoId else { return }
                var stream = resolved
                stream.lateTracking = nil
                stream.historyURL = tracking?.playbackURL
                stream.watchtimeURL = tracking?.watchtimeURL
                self.armHistory(stream)
            }
            return
        }
        guard resolved.historyURL != nil || resolved.watchtimeURL != nil, resolved.cpn != nil else {
            return
        }
        pendingHistory = resolved
        playbackPinged = false
        lastWatchtimeAt = -1
    }

    /// Fires the history beacons as the current track plays: the `playback` beacon
    /// once, then `watchtime` heartbeats with the live position every ~20s — the
    /// shape the real YT Music client uses, and what makes a play land in history.
    private func reportHistoryProgress(current: Double, duration: Double) {
        guard let pending = pendingHistory, let cpn = pending.cpn else { return }
        guard audio.isPlaying, current >= 1 else { return }
        let length = pending.duration ?? (duration > 0 ? duration : nil)

        if !playbackPinged, let playbackURL = pending.historyURL {
            playbackPinged = true
            Task { await historyReporter.reportPlaybackStart(
                playbackURL: playbackURL, cpn: cpn, position: current, length: length) }
        }
        if let watchtimeURL = pending.watchtimeURL, lastWatchtimeAt < 0 || current - lastWatchtimeAt >= 20 {
            lastWatchtimeAt = current
            Task { await historyReporter.reportWatchtime(
                watchtimeURL: watchtimeURL, cpn: cpn, position: current, length: length) }
        }
    }

    /// Sends a closing `watchtime` heartbeat at the track's end, so the listen is
    /// recorded as completed. Only when the track actually started reporting.
    private func reportFinalWatchtime() {
        guard playbackPinged, let pending = pendingHistory, let cpn = pending.cpn,
              let watchtimeURL = pending.watchtimeURL else { return }
        let length = pending.duration
        let position = length ?? audio.duration
        Task { await historyReporter.reportWatchtime(
            watchtimeURL: watchtimeURL, cpn: cpn, position: position, length: length) }
    }

    // MARK: - Crossfade

    /// Called each playback tick. Drives history reporting, and — when crossfade
    /// is enabled and the current track is within the crossfade window of its end
    /// — kicks off an overlap into the next track.
    private func handleProgress(current: Double, duration: Double) {
        // History beacons fire from real progress regardless of crossfade settings.
        reportHistoryProgress(current: current, duration: duration)

        if abs(current - lastPersistedPosition) >= 5 {
            lastPersistedPosition = current
            persist()
        }

        if let seconds = settings?.nextTrackPreloadSeconds,
           seconds > 0, duration > 0, duration - current <= seconds {
            beginPreloadingNext()
        }

        guard let settings, settings.crossfadeEnabled else { return }
        let seconds = settings.crossfadeSeconds
        guard seconds > 0, duration > 0 else { return }

        // Re-arm once the freshly-started track is underway again.
        if current < 1.0 { crossfadeArmed = false }

        // Repeat-one loops the same track, so never crossfade out of it.
        guard !crossfadeArmed, repeatMode != .one, canGoNext else { return }
        if duration - current <= seconds {
            crossfadeArmed = true
            beginCrossfade(over: seconds)
        }
    }

    private func beginCrossfade(over seconds: Double) {
        guard !queue.isEmpty else { return }
        let nextIndex: Int
        if currentIndex + 1 < queue.count {
            nextIndex = currentIndex + 1
        } else if repeatMode == .all {
            nextIndex = 0
        } else {
            return
        }
        guard let videoId = queue[nextIndex].videoId else { return }

        let track = queue[nextIndex]
        currentIndex = nextIndex
        crossfadeLoading = true
        pendingHistory = nil
        playbackPinged = false
        lastWatchtimeAt = -1
        likeStatus = .indifferent
        likeInteracted = false
        nowPlaying = NowPlaying(
            title: track.title,
            subtitle: track.subtitle,
            album: albumContext,
            thumbnailURL: track.thumbnailURL,
            videoId: videoId,
            artists: track.artists,
            albumLink: track.albumLink
        )
        loadError = nil
        persist()
        emitPlaybackChange()
        fetchLikeStatus(for: videoId)

        loadTask?.cancel()
        loadTask = Task { await loadCrossfade(videoId: videoId, seconds: seconds) }

        maybeContinueWithRadio()
    }

    private func loadCrossfade(videoId: String, seconds: Double) async {
        do {
            let preferences = settings?.streamPreferences ?? StreamPreferences()
            let resolved: ResolvedStream
            let usedPreloadedStream = preparedVideoId == videoId
            if usedPreloadedStream, let preparedStream {
                resolved = preparedStream
                self.preparedVideoId = nil
                self.preparedStream = nil
            } else {
                resolved = try await resolver.audioStream(videoId: videoId, playlistId: playlistContext,
                                                           preferences: preferences)
            }
            if Task.isCancelled { return }
            let metadata = NowPlayingMetadata(
                title: nowPlaying?.title ?? "",
                artist: Self.cleanedArtist(nowPlaying),
                album: nowPlaying?.album ?? "",
                artworkURL: nowPlaying?.thumbnailURL,
                knownDuration: resolved.duration,
                loudnessDb: resolved.loudnessDb
            )
            if usedPreloadedStream {
                audio.crossfadePreloaded(url: resolved.url, metadata: metadata, duration: seconds)
            } else {
                audio.crossfade(to: resolved.url, metadata: metadata, duration: seconds)
            }
            crossfadeLoading = false
            emitPlaybackChange()
            currentStream = resolved
            armHistory(resolved)
        } catch {
            // Couldn't resolve the next track in time — fall back to a plain
            // load of the now-current track once the old one ends.
            crossfadeLoading = false
            if !Task.isCancelled { startCurrent() }
        }
    }

    private func beginPreloadingNext() {
        guard preparedVideoId == nil, preloadTask == nil,
              repeatMode != .one, let nextTrack = nextQueuedTrack(),
              let videoId = nextTrack.videoId else { return }

        let track = nextTrack
        let playlistId = playlistContext
        let preferences = settings?.streamPreferences ?? StreamPreferences()
        preloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.preloadTask = nil }
            do {
                let resolved = try await self.resolver.audioStream(videoId: videoId, playlistId: playlistId,
                                                                    preferences: preferences)
                guard !Task.isCancelled,
                      self.nowPlaying?.videoId != videoId,
                      self.nextQueuedTrack()?.videoId == videoId else { return }
                let metadata = NowPlayingMetadata(
                    title: track.title,
                    artist: Self.cleanedArtist(NowPlaying(
                        title: track.title, subtitle: track.subtitle, album: self.albumContext,
                        thumbnailURL: track.thumbnailURL, videoId: videoId,
                        artists: track.artists, albumLink: track.albumLink)),
                    album: self.albumContext,
                    artworkURL: track.thumbnailURL,
                    knownDuration: resolved.duration,
                    loudnessDb: resolved.loudnessDb
                )
                self.preparedVideoId = videoId
                self.preparedStream = resolved
                self.audio.preload(url: resolved.url, metadata: metadata)
            } catch {}
        }
    }

    private func nextQueuedTrack() -> Track? {
        if currentIndex + 1 < queue.count { return queue[currentIndex + 1] }
        guard repeatMode == .all, !queue.isEmpty else { return nil }
        return queue[0]
    }

    // MARK: - Plugin hook

    /// A point-in-time view of playback for plugins. nil means nothing is playing.
    var currentSnapshot: PlaybackSnapshot? {
        guard let nowPlaying else { return nil }
        return PlaybackSnapshot(
            title: nowPlaying.title,
            artist: Self.cleanedArtist(nowPlaying),
            album: nowPlaying.album,
            videoId: nowPlaying.videoId,
            artists: nowPlaying.artists,
            albumLink: nowPlaying.albumLink,
            thumbnailURL: nowPlaying.thumbnailURL,
            isPlaying: audio.isActuallyPlaying,
            currentTime: currentTime,
            duration: duration
        )
    }

    private func emitPlaybackChange() {
        onPlaybackChange?(currentSnapshot)
    }

    /// The display artist for the current track (structured links if known, else
    /// parsed from the subtitle). Empty when nothing is playing. Cheap to read
    /// from a view without observing per-tick playback state.
    var nowPlayingArtist: String { Self.cleanedArtist(nowPlaying) }

    /// The artist name for Now Playing / plugins. Prefers the structured artist
    /// links; otherwise parses it out of the subtitle.
    private static func cleanedArtist(_ nowPlaying: NowPlaying?) -> String {
        guard let nowPlaying else { return "" }
        let names = nowPlaying.artists.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty { return names.joined(separator: ", ") }
        // No links: take just the first component ("Artist") of the subtitle.
        return withoutTypeLabel(nowPlaying.subtitle).components(separatedBy: " • ").first ?? ""
    }

    /// YT Music subtitles often lead with a content-type label
    /// ("Song • Artist • Album • Year"); videos additionally stuff a view count
    /// and length into the byline ("femtanyl • 3.5M views • 2:46"). Drop the
    /// type label, any view-count, and any bare duration component so the line
    /// reads as a clean "Artist • Album" byline everywhere it's shown.
    static func withoutTypeLabel(_ subtitle: String) -> String {
        var components = subtitle.components(separatedBy: " • ")
        let labels: Set<String> = ["Song", "Video", "Episode", "Podcast"]
        if components.count > 1, let first = components.first, labels.contains(first) {
            components.removeFirst()
        }
        components.removeAll { isViewCount($0) || isDuration($0) }
        return components.joined(separator: " • ")
    }

    /// A view-count component like "3.5M views" / "1,234 views" — a leading
    /// number token followed by "view"/"views".
    private static func isViewCount(_ component: String) -> Bool {
        let text = component.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasSuffix(" views") || text.hasSuffix(" view") else { return false }
        return text.first?.isNumber ?? false
    }

    /// A bare duration component like "2:46" or "1:02:30" — colon-separated
    /// groups of digits and nothing else.
    private static func isDuration(_ component: String) -> Bool {
        let parts = component.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
