//
//  StreamResolver.swift
//  YT Music
//
//  Turns a videoId into a final, playable audio URL: requests the player
//  response (with the correct signatureTimestamp), picks an AVPlayer-compatible
//  audio stream, and deciphers its URL.
//

import Foundation

enum StreamError: LocalizedError {
    case notPlayable(String)
    case noCompatibleAudio

    var errorDescription: String? {
        switch self {
        case .notPlayable(let reason): "Can't play this track: \(reason)"
        case .noCompatibleAudio:       "No AAC audio stream was available for this track."
        }
    }
}

/// A resolved, playable stream plus the track's authoritative length (from the
/// player response), used so the scrubber doesn't trust AVPlayer's estimate.
struct ResolvedStream: Sendable {
    let url: URL
    let duration: Double?
    /// The player response's `videostatsPlaybackUrl`, if present — ping it to
    /// record the play in the user's watch history. nil when YouTube omits it.
    var historyURL: URL? = nil
    /// The player response's `videostatsWatchtimeUrl`, if present — reports
    /// accumulated listen time, which drives YT Music history.
    var watchtimeURL: URL? = nil
    /// The content-playback nonce that tags `url`; reused for the history ping so
    /// YouTube correlates the two. nil when no history URL is being reported.
    var cpn: String? = nil
}

/// Resolves a videoId to a playable stream. Abstracted so PlayerState can be
/// tested with a stub.
protocol StreamResolving: Sendable {
    /// `playlistId` is the playlist the play comes from (attribution context),
    /// when known — sent with the player request so the listen is attributed
    /// to that playlist/radio.
    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream
}

extension StreamResolving {
    /// Convenience for callers (and tests) that don't care about preferences.
    func audioStream(videoId: String) async throws -> ResolvedStream {
        try await audioStream(videoId: videoId, playlistId: nil, preferences: StreamPreferences())
    }

    /// Convenience for callers that resolve without playlist context (downloads).
    func audioStream(videoId: String, preferences: StreamPreferences) async throws -> ResolvedStream {
        try await audioStream(videoId: videoId, playlistId: nil, preferences: preferences)
    }
}

actor StreamResolver: StreamResolving {
    static let shared = StreamResolver()

    private let client = InnerTubeClient.shared
    private let decipher = SignatureDecipher.shared

    /// The page config deciding PO token bindings, keyed by the SAPISID it was
    /// read with (nil = signed out) so a sign-in change re-reads it.
    private var pageConfig: (sapisid: String?, config: PlayerPageConfig)?

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        PlaybackLog.note("resolving videoId=\(videoId) playlist=\(playlistId ?? "—")")
        let signatureTimestamp = try await decipher.signatureTimestamp()
        // Mint the stream's PO token alongside the player request when its
        // binding is known up front (video id / account), so it adds no latency.
        let config = await currentPageConfig()
        let earlyBinding = config.bindsToVideoId ? videoId : config.dataSyncId
        async let earlyToken = streamingPoToken(binding: earlyBinding)
        let response = try await playerResponse(
            videoId: videoId,
            signatureTimestamp: signatureTimestamp,
            playlistId: playlistId
        )

        let status = response.playabilityStatus?.status ?? "nil"
        let adaptiveCount = response.streamingData?.adaptiveFormats?.count ?? 0
        PlaybackLog.note(
            "playabilityStatus=\(status) · adaptiveFormats=\(adaptiveCount) "
                + "· lengthSeconds=\(response.videoDetails?.lengthSeconds ?? "nil")"
        )

        try checkPlayability(response)

        let format = try selectAudioFormat(response, preferences: preferences)
        PlaybackLog.note("selected itag=\(format.itag ?? -1) mime=\(format.mimeType ?? "?") quality=\(preferences.audioQuality.rawValue)")

        // One content-playback nonce tags the media we fetch and the history
        // ping, so YouTube correlates them and the play counts toward history.
        let cpn = WatchHistory.generateCPN()
        let deciphered = try await decipher.streamURL(for: format)
        var poToken = await earlyToken
        if earlyBinding == nil {
            poToken = await streamingPoToken(binding: response.responseContext?.visitorData)
            if poToken == nil { PlaybackLog.problem("potoken: no visitorData to bind to") }
        }
        let url = Self.appendingPoToken(
            poToken, to: WatchHistory.appendingCPN(to: deciphered, cpn: cpn)
        )
        PlaybackLog.note("resolved stream host=\(url.host ?? "?")")

        let historyURL = response.playbackTracking?.videostatsPlaybackUrl?.baseUrl
            .flatMap { URL(string: $0) }
        let watchtimeURL = response.playbackTracking?.videostatsWatchtimeUrl?.baseUrl
            .flatMap { URL(string: $0) }
        return ResolvedStream(url: url, duration: response.videoDetails?.duration,
                              historyURL: historyURL, watchtimeURL: watchtimeURL, cpn: cpn)
    }

    /// The GVS PO token for `binding`, or nil when there is no binding or it
    /// can't be minted. Playback then still starts, but googlevideo may cut it
    /// off after the first megabyte.
    private func streamingPoToken(binding: String?) async -> String? {
        guard let binding else { return nil }
        do {
            return try await PoTokenProvider.shared.token(for: binding)
        } catch {
            PlaybackLog.problem("potoken: \(error.localizedDescription)")
            return nil
        }
    }

    /// The YT Music page config, read once per sign-in state. A failed read
    /// falls back to binding by video id, the binding YouTube currently uses.
    private func currentPageConfig() async -> PlayerPageConfig {
        let sapisid = await CredentialStore.shared.credentials?.sapisid
        if let pageConfig, pageConfig.sapisid == sapisid { return pageConfig.config }

        let config: PlayerPageConfig
        do {
            config = try await client.playerPageConfig()
            PlaybackLog.note("potoken: bind to \(config.bindsToVideoId ? "video id" : config.dataSyncId != nil ? "account" : "visitor")")
            pageConfig = (sapisid, config)
        } catch {
            PlaybackLog.problem("potoken: page config unavailable (\(error.localizedDescription))")
            config = PlayerPageConfig(dataSyncId: nil, bindsToVideoId: true)
        }
        return config
    }

    /// Adds `pot` to a stream URL (no-op for a nil token). `nonisolated` so it
    /// can be unit-tested without the actor hop.
    nonisolated static func appendingPoToken(_ token: String?, to url: URL) -> URL {
        guard let token, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = (components.queryItems ?? []).filter { $0.name != "pot" }
        items.append(URLQueryItem(name: "pot", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    /// Player requests are safe to repeat. A short retry covers transient
    /// connection resets and server errors without retrying auth or playability
    /// failures that will not change on their own.
    private func playerResponse(videoId: String, signatureTimestamp: String?, playlistId: String?) async throws -> PlayerResponse {
        let delays: [UInt64] = [0, 300_000_000, 1_000_000_000]
        var lastError: Error?

        for (attempt, delay) in delays.enumerated() {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            do {
                return try await client.player(
                    videoId: videoId,
                    signatureTimestamp: signatureTimestamp,
                    playlistId: playlistId
                )
            } catch {
                lastError = error
                guard attempt < delays.count - 1, Self.isTransient(error) else { throw error }
                PlaybackLog.note("transient player request failure; retrying attempt \(attempt + 2)")
            }
        }

        throw lastError ?? InnerTubeError.emptyResponse
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        switch error {
        case InnerTubeError.emptyResponse:
            return true
        case InnerTubeError.badStatus(let code):
            return (500...599).contains(code)
        default:
            return false
        }
    }

    /// Throws when the player response reports the video can't be played
    /// (e.g. `LOGIN_REQUIRED`, `UNPLAYABLE`, `ERROR`). A missing status, or
    /// `"OK"`, is treated as playable. `nonisolated` so it can be unit-tested
    /// without the actor hop.
    nonisolated func checkPlayability(_ response: PlayerResponse) throws {
        guard let status = response.playabilityStatus?.status, status != "OK" else { return }
        let reason = response.playabilityStatus?.reason ?? status
        PlaybackLog.problem("not playable: \(reason)")
        throw StreamError.notPlayable(reason)
    }

    /// Picks a playable stream honouring the user's preferences:
    /// - "prefer audio over video" keeps us on adaptive audio-only streams and
    ///   only falls back to a muxed (video+audio) MP4 when no audio stream is
    ///   compatible. With it off, a muxed stream is allowed to win on quality.
    /// - audio quality selects a rung on the bitrate-sorted ladder (auto/high =
    ///   best, medium = middle, low = lowest).
    /// `nonisolated` so it can be unit-tested without the actor hop.
    nonisolated func selectAudioFormat(
        _ response: PlayerResponse,
        preferences: StreamPreferences = StreamPreferences()
    ) throws -> PlayerResponse.Format {
        let adaptiveAudio = (response.streamingData?.adaptiveFormats ?? [])
            .filter { $0.isAudio && $0.isAVPlayerCompatible }
        let muxed = (response.streamingData?.formats ?? [])
            .filter { $0.isAVPlayerCompatible }

        if preferences.preferAudioOverVideo {
            // Stay on audio-only streams; use a muxed (video+audio) stream only
            // when no compatible audio-only stream exists.
            if let chosen = pick(from: adaptiveAudio, quality: preferences.audioQuality) {
                return chosen
            }
            if let chosen = pick(from: muxed, quality: preferences.audioQuality) {
                return chosen
            }
        } else {
            // Let audio-only and muxed compete together on the quality ladder.
            if let chosen = pick(from: adaptiveAudio + muxed, quality: preferences.audioQuality) {
                return chosen
            }
        }
        throw StreamError.noCompatibleAudio
    }

    /// Ranks `formats` by bitrate (ascending) and returns the rung matching the
    /// requested quality. Returns nil for an empty pool.
    private nonisolated func pick(
        from formats: [PlayerResponse.Format],
        quality: AudioQuality
    ) -> PlayerResponse.Format? {
        let ranked = formats.sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard !ranked.isEmpty else { return nil }
        switch quality {
        case .low:           return ranked.first
        case .medium:        return ranked[ranked.count / 2]
        case .high, .auto:   return ranked.last
        }
    }
}
