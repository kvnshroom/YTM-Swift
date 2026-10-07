//
//  AudioOutput.swift
//  YT Music
//
//  Abstraction over the audio engine so PlayerState can be driven by a fake in
//  tests (no AVPlayer / audio hardware). AudioPlayer is the production conformer.
//

import Foundation

/// Metadata shown in the system Now Playing UI (Control Center, media keys).
struct NowPlayingMetadata: Sendable, Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    /// Authoritative track length (from the player response). Preferred over
    /// AVPlayer's `duration`, which can over-estimate while buffering.
    var knownDuration: Double? = nil
    /// Track loudness in dB relative to YouTube's reference, for volume normalization.
    var loudnessDb: Double? = nil
}

@MainActor
protocol AudioOutput: AnyObject {
    var isPlaying: Bool { get }
    /// Whether audio is genuinely flowing (not paused, not still buffering).
    /// The plugin-facing truth, so presences don't go live mid-load.
    var isActuallyPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }
    /// How far into the track the stream has buffered ahead (seconds). Drives the
    /// "cache progress" fill behind the scrubber.
    var bufferedTime: Double { get }
    /// Output volume, 0...1. Applied as a master gain on top of any crossfade.
    var volume: Double { get set }
    /// Turns down tracks louder than YouTube's reference level (see `NowPlayingMetadata.loudnessDb`).
    var normalizesVolume: Bool { get set }

    /// Called when the current item plays to its end.
    var onTrackFinished: (() -> Void)? { get set }
    /// Called when the current item actually starts producing audio — the
    /// buffering → playing transition, not the moment the stream is loaded.
    var onPlaybackStart: (() -> Void)? { get set }
    /// Called when a media-key / Control Center play-or-pause command fires, so
    /// the owner (PlayerState) can emit playback changes to plugins.
    var onTogglePlayPause: (() -> Void)? { get set }
    /// Called when the system "next track" remote command (media key / Control
    /// Center) fires.
    var onNext: (() -> Void)? { get set }
    /// Called when the system "previous track" remote command fires.
    var onPrevious: (() -> Void)? { get set }
    /// Called on each playback tick with `(currentTime, duration)`. Lets the
    /// owner (PlayerState) decide when to begin a crossfade into the next track.
    var onProgress: ((Double, Double) -> Void)? { get set }

    func load(url: URL, metadata: NowPlayingMetadata)
    /// Attaches a stream to the idle player without starting audible playback.
    func preload(url: URL, metadata: NowPlayingMetadata)
    /// Starts a stream previously attached with `preload`.
    func loadPreloaded(url: URL, metadata: NowPlayingMetadata)
    func togglePlayPause()
    func seek(to seconds: Double)
    /// Restarts the current item from the beginning (used for repeat-one, so the
    /// stream URL isn't re-resolved).
    func restart()
    /// Overlaps the current track with `url` over `duration` seconds, fading the
    /// outgoing track out and the incoming one in. Used for gapless crossfade.
    func crossfade(to url: URL, metadata: NowPlayingMetadata, duration: Double)
    /// Crossfades using a stream previously attached with `preload`.
    func crossfadePreloaded(url: URL, metadata: NowPlayingMetadata, duration: Double)
    /// Applies equalizer settings to current and future playback. Takes effect
    /// immediately on the playing track.
    func applyEqualizer(_ settings: EqualizerSettings)

    /// Live spectrum meter for the visualizer, or nil for outputs that don't
    /// provide one (e.g. the test fake).
    var spectrum: SpectrumAnalyzer? { get }
}

extension AudioOutput {
    func preload(url: URL, metadata: NowPlayingMetadata) {}
    func loadPreloaded(url: URL, metadata: NowPlayingMetadata) { load(url: url, metadata: metadata) }
    func crossfadePreloaded(url: URL, metadata: NowPlayingMetadata, duration: Double) {
        crossfade(to: url, metadata: metadata, duration: duration)
    }
    func applyEqualizer(_ settings: EqualizerSettings) {}
    var spectrum: SpectrumAnalyzer? { nil }
    var normalizesVolume: Bool { get { false } set {} }
    var isActuallyPlaying: Bool { isPlaying }
    var onPlaybackStart: (() -> Void)? { get { nil } set {} }
    var onTogglePlayPause: (() -> Void)? { get { nil } set {} }
}
