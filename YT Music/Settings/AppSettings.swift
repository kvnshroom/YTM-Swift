//
//  AppSettings.swift
//  YT Music
//
//  App-wide user preferences, backed by UserDefaults. Lives for the whole
//  process (env-injected like PlayerState/AuthStore). Each stored property
//  reads its initial value from UserDefaults and writes back on change, so the
//  settings survive relaunches without an explicit save step.
//

import SwiftUI

/// Preferred audio fidelity. The resolver maps this onto the available adaptive
/// streams (which are ranked by bitrate) rather than fixed kbps values, since
/// YouTube's ladder varies per track.
nonisolated enum AudioQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high
    case auto   // always the best available

    var id: Self { self }

    var label: String {
        switch self {
        case .low:    "Low"
        case .medium: "Medium"
        case .high:   "High"
        case .auto:   "Auto (best)"
        }
    }
}

/// How the resolver picks where a track's stream comes from (see `StreamSource`).
nonisolated enum StreamSourceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// visionOS first, the account first when it offers Premium audio.
    case automatic
    /// The user's own order of `StreamSourceEntry`s.
    case custom

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .custom:    "Custom"
        }
    }
}

/// One row of the custom stream source order.
nonisolated struct StreamSourceEntry: Codable, Hashable, Sendable, Identifiable {
    var source: StreamSource
    var isEnabled = true

    var id: StreamSource { source }

    static let defaults = StreamSource.allCases.map { StreamSourceEntry(source: $0) }

    /// Repairs a stored order: drops duplicates, appends sources added since
    /// (enabled), and keeps at least one source enabled.
    static func normalized(_ entries: [StreamSourceEntry]) -> [StreamSourceEntry] {
        var seen = Set<StreamSource>()
        var result = entries.filter { seen.insert($0.source).inserted }
        result += StreamSource.allCases.filter { !seen.contains($0) }.map { StreamSourceEntry(source: $0) }
        if !result.contains(where: \.isEnabled) { result[0].isEnabled = true }
        return result
    }
}

extension StreamSource {
    var title: String {
        switch self {
        case .visionOS: "visionOS"
        case .account:  "YouTube Music account"
        }
    }

    var summary: String {
        switch self {
        case .visionOS: "No sign-in · up to 128 kbps · no web view"
        case .account:  "Signed in · up to 256 kbps with Premium · plays uploads"
        }
    }
}

/// The subset of settings the (nonisolated) stream resolver needs. A plain
/// Sendable value so it can be passed across the actor boundary on each resolve.
nonisolated struct StreamPreferences: Sendable, Equatable {
    var audioQuality: AudioQuality = .auto
    /// When true, music videos are played as audio-only adaptive streams and a
    /// muxed (video+audio) stream is used only as a last resort.
    var preferAudioOverVideo: Bool = true
    var sourceMode: StreamSourceMode = .automatic
    var customSources: [StreamSourceEntry] = StreamSourceEntry.defaults
}

@MainActor
@Observable
final class AppSettings {
    // MARK: Audio

    var audioQuality: AudioQuality {
        didSet { store(audioQuality.rawValue, for: .audioQuality) }
    }

    var preferAudioOverVideo: Bool {
        didSet { store(preferAudioOverVideo, for: .preferAudioOverVideo) }
    }

    var streamSourceMode: StreamSourceMode {
        didSet { store(streamSourceMode.rawValue, for: .streamSourceMode) }
    }

    /// The order and on/off state of the sources in custom mode.
    var customStreamSources: [StreamSourceEntry] {
        didSet {
            let normalized = StreamSourceEntry.normalized(customStreamSources)
            if normalized != customStreamSources { customStreamSources = normalized; return }
            store(try? JSONEncoder().encode(customStreamSources), for: .customStreamSources)
        }
    }

    /// Turns down tracks louder than YouTube's reference level.
    var volumeNormalization: Bool {
        didSet {
            store(volumeNormalization, for: .volumeNormalization)
            onVolumeNormalizationChange?(volumeNormalization)
        }
    }

    /// Set by PlayerState so toggling normalization applies to the playing track.
    @ObservationIgnored var onVolumeNormalizationChange: ((Bool) -> Void)?

    /// When the queue runs out, continue with a radio based on the last track.
    var autoplay: Bool {
        didSet { store(autoplay, for: .autoplay) }
    }

    /// Optional HTTP(S) proxy used by YouTube requests and stream downloads.
    /// Leave blank to use the system network configuration.
    var proxyURL: String {
        didSet { store(proxyURL.isEmpty ? nil : proxyURL, for: .proxyURL) }
    }

    // MARK: Lyrics

    /// Where the lyrics panel fetches from.
    var lyricsProvider: LyricsProvider {
        didSet { store(lyricsProvider.rawValue, for: .lyricsProvider) }
    }

    /// Output volume, 0...1. Persisted so the level survives relaunches.
    var volume: Double {
        didSet { store(volume, for: .volume) }
    }

    // MARK: Crossfade

    var crossfadeEnabled: Bool {
        didSet { store(crossfadeEnabled, for: .crossfadeEnabled) }
    }

    /// Overlap duration, in seconds, between consecutive tracks.
    var crossfadeSeconds: Double {
        didSet { store(crossfadeSeconds, for: .crossfadeSeconds) }
    }

    /// How early to resolve and buffer the next queued track. Zero disables it.
    var nextTrackPreloadSeconds: Double {
        didSet { store(nextTrackPreloadSeconds, for: .nextTrackPreloadSeconds) }
    }

    // MARK: Shuffle

    /// Keep shuffle on when a new album/playlist/radio replaces the queue,
    /// instead of starting the new queue in its natural order.
    var keepShuffle: Bool {
        didSet { store(keepShuffle, for: .keepShuffle) }
    }

    // MARK: Equalizer

    var equalizerEnabled: Bool {
        didSet {
            store(equalizerEnabled, for: .equalizerEnabled)
            notifyEqualizerChanged()
        }
    }

    /// Per-band gain in dB (one entry per `EqualizerBands` frequency).
    var equalizerGains: [Double] {
        didSet {
            store(try? JSONEncoder().encode(equalizerGains), for: .equalizerGains)
            notifyEqualizerChanged()
        }
    }

    /// Called whenever the equalizer configuration changes so the audio engine
    /// can re-equalize the playing track. Set by PlayerState at startup.
    @ObservationIgnored var onEqualizerChange: ((EqualizerSettings) -> Void)?

    /// Snapshot consumed by the audio engine's equalizer taps.
    var equalizerSettings: EqualizerSettings {
        EqualizerSettings(isEnabled: equalizerEnabled, gains: equalizerGains)
    }

    /// Replaces every band gain at once (e.g. when picking a preset).
    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        equalizerGains = preset.gains
    }

    private func notifyEqualizerChanged() {
        onEqualizerChange?(equalizerSettings)
    }

    // MARK: Startup

    /// Mirrors the system login item, which the user can also change in System Settings.
    var openAtLogin: Bool {
        didSet { LoginItem.setEnabled(openAtLogin) }
    }

    // MARK: Downloader

    /// Where the downloader writes files. nil → the user's Downloads folder.
    /// Persisted as a security-scoped bookmark so write access (granted via the
    /// open panel) survives relaunches under the App Sandbox. Set it through
    /// `setDownloadDirectory(_:)`, which mints the bookmark.
    private(set) var downloadDirectory: URL?

    /// Snapshot consumed by the resolver on each track load.
    var streamPreferences: StreamPreferences {
        StreamPreferences(audioQuality: audioQuality,
                          preferAudioOverVideo: preferAudioOverVideo,
                          sourceMode: streamSourceMode,
                          customSources: customStreamSources)
    }

    /// Effective download destination, falling back to ~/Downloads.
    var effectiveDownloadDirectory: URL {
        downloadDirectory ?? FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read persisted values, falling back to sensible defaults.
        self.audioQuality = (defaults.string(forKey: Key.audioQuality.rawValue)
            .flatMap(AudioQuality.init)) ?? .auto
        self.preferAudioOverVideo = defaults.object(forKey: Key.preferAudioOverVideo.rawValue) as? Bool ?? true
        self.streamSourceMode = (defaults.string(forKey: Key.streamSourceMode.rawValue)
            .flatMap(StreamSourceMode.init)) ?? .automatic
        self.customStreamSources = StreamSourceEntry.normalized(
            defaults.data(forKey: Key.customStreamSources.rawValue)
                .flatMap { try? JSONDecoder().decode([StreamSourceEntry].self, from: $0) } ?? []
        )
        self.volumeNormalization = defaults.bool(forKey: Key.volumeNormalization.rawValue)
        self.autoplay = defaults.object(forKey: Key.autoplay.rawValue) as? Bool ?? true
        self.proxyURL = defaults.string(forKey: Key.proxyURL.rawValue) ?? ""
        self.lyricsProvider = (defaults.string(forKey: Key.lyricsProvider.rawValue)
            .flatMap(LyricsProvider.init)) ?? .youtubeMusic
        self.volume = defaults.object(forKey: Key.volume.rawValue) as? Double ?? 1
        self.crossfadeEnabled = defaults.bool(forKey: Key.crossfadeEnabled.rawValue)
        self.crossfadeSeconds = defaults.object(forKey: Key.crossfadeSeconds.rawValue) as? Double ?? 6
        self.nextTrackPreloadSeconds = defaults.object(forKey: Key.nextTrackPreloadSeconds.rawValue) as? Double ?? 0
        self.keepShuffle = defaults.bool(forKey: Key.keepShuffle.rawValue)
        self.equalizerEnabled = defaults.bool(forKey: Key.equalizerEnabled.rawValue)
        self.equalizerGains = Self.decodeGains(defaults.data(forKey: Key.equalizerGains.rawValue))
        self.downloadDirectory = Self.resolveBookmark(defaults.data(forKey: Key.downloadDirectory.rawValue))
        self.openAtLogin = LoginItem.isEnabled
    }

    /// Decodes persisted band gains, falling back to a flat curve if absent or
    /// malformed. Always returns exactly `EqualizerBands.count` entries.
    private static func decodeGains(_ data: Data?) -> [Double] {
        guard let data,
              let gains = try? JSONDecoder().decode([Double].self, from: data) else {
            return EqualizerSettings.flat.gains
        }
        return EqualizerSettings(isEnabled: false, gains: gains).normalizedGains
    }

    /// Records a user-chosen download folder, minting a security-scoped bookmark
    /// so the grant persists. Pass nil to revert to the Downloads folder.
    func setDownloadDirectory(_ url: URL?) {
        guard let url else {
            downloadDirectory = nil
            store(nil, for: .downloadDirectory)
            return
        }
        downloadDirectory = url
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        store(bookmark, for: .downloadDirectory)
    }

    /// Resolves a stored security-scoped bookmark and begins accessing it (held
    /// for the app's lifetime — there's only ever one download folder).
    private static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: - Persistence

    private enum Key: String {
        case audioQuality        = "settings.audioQuality"
        case preferAudioOverVideo = "settings.preferAudioOverVideo"
        case streamSourceMode    = "settings.streamSourceMode"
        case customStreamSources = "settings.customStreamSources"
        case volumeNormalization = "settings.volumeNormalization"
        case autoplay            = "settings.autoplay"
        case proxyURL            = "settings.proxyURL"
        case lyricsProvider      = "settings.lyricsProvider"
        case volume              = "settings.volume"
        case crossfadeEnabled    = "settings.crossfadeEnabled"
        case crossfadeSeconds    = "settings.crossfadeSeconds"
        case nextTrackPreloadSeconds = "settings.nextTrackPreloadSeconds"
        case keepShuffle         = "settings.keepShuffle"
        case equalizerEnabled    = "settings.equalizerEnabled"
        case equalizerGains      = "settings.equalizerGains"
        case downloadDirectory   = "settings.downloadDirectory"
    }

    private func store(_ value: Any?, for key: Key) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
