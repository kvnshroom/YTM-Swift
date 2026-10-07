//
//  StreamResolver.swift
//  YT Music
//
//  Turns a videoId into a final, playable audio URL. Tries the stream sources
//  in the order StreamSourcePolicy gives (visionOS for free accounts, the
//  signed-in account for Premium), picks an AVPlayer-compatible audio stream,
//  and deciphers its URL when needed.
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
    /// Track loudness relative to YouTube's reference level, in dB (positive is louder).
    var loudnessDb: Double? = nil
    /// The track this stream plays, and where and when it was resolved, so a
    /// stream that dies mid-track can be reported back (see `StreamResolving`).
    var videoId: String? = nil
    var source: StreamSource? = nil
    /// Whether the URL carries a PO token minted in a web view.
    var usedToken = false
    var resolvedAt = Date()
    /// Stats URLs that arrive after the stream: the account's player response
    /// when visionOS answered first. Resolves to nil when there are none.
    var lateTracking: Task<PlayerResponse.PlaybackTracking?, Never>? = nil
}

/// Resolves a videoId to a playable stream. Abstracted so PlayerState can be
/// tested with a stub.
protocol StreamResolving: Sendable {
    /// `playlistId` is the playlist the play comes from (attribution context),
    /// when known — sent with the player request so the listen is attributed
    /// to that playlist/radio.
    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream
    /// Tells the resolver a stream it returned died mid-track (with AVPlayer's
    /// error), before the player reloads it, so the next resolve can avoid the cause.
    func streamFailed(_ stream: ResolvedStream, error: Error?) async
}

extension StreamResolving {
    func streamFailed(_ stream: ResolvedStream, error: Error?) async {}

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

    /// How long the first track of a session waits for the account response
    /// to learn whether the account offers Premium audio.
    static let firstTrackDeadline = 0.5

    private var session = StreamSession()
    /// The visitor id the visionOS client plays under, taken from its first
    /// `LOGIN_REQUIRED` answer and reused for later tracks.
    private var visionOSVisitorData: String?

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        PlaybackLog.note("resolving videoId=\(videoId) playlist=\(playlistId ?? "—")")
        // The account's player response is needed whichever source streams: its
        // stats URLs record the play in the user's history, it tells whether the
        // account offers Premium audio, and it is the account source itself. Only
        // it needs the player JS (signature timestamp); visionOS doesn't.
        let accountResponse = Task {
            let signatureTimestamp = try await decipher.signatureTimestamp()
            return try await playerResponse(
                videoId: videoId,
                signatureTimestamp: signatureTimestamp,
                playlistId: playlistId
            )
        }

        let premiumAudio = await premiumAudio(awaiting: accountResponse, waits: preferences.sourceMode == .automatic)
        let excluded = session.failures.excluded(for: videoId, at: Date())
        let preferred = StreamSourcePolicy.order(
            mode: preferences.sourceMode,
            custom: preferences.customSources,
            quality: preferences.audioQuality,
            premiumAudio: premiumAudio
        )
        // Never skip everything: with every source excluded, try them all again.
        let remaining = preferred.filter { !excluded.contains($0) }
        let order = remaining.isEmpty ? preferred : remaining
        PlaybackLog.note("source order: \(order.map(\.rawValue).joined(separator: ", ")) "
            + "(premium audio \(premiumAudio), quality \(preferences.audioQuality.rawValue))")

        var lastError: Error = StreamError.noCompatibleAudio
        for source in order {
            try Task.checkCancellation()
            do {
                switch source {
                case .visionOS:
                    return try await visionOSStream(videoId: videoId, preferences: preferences,
                                                    accountResponse: accountResponse)
                case .account:
                    let response = try await accountResponse.value
                    session.record(response)
                    return try await accountStream(videoId: videoId, response: response, preferences: preferences)
                }
            } catch {
                // The user moved on: don't fall through to (and mint for) the next source.
                if Task.isCancelled || StreamSourcePolicy.isCancellation(error) { throw error }
                PlaybackLog.problem("stream source \(source.rawValue) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        if preferences.sourceMode == .custom, preferences.customSources.filter(\.isEnabled).count == 1 {
            throw StreamError.notPlayable(
                "\(lastError.localizedDescription) Turn on another source in Settings → Streaming to try it as a fallback."
            )
        }
        throw lastError
    }

    func streamFailed(_ stream: ResolvedStream, error: Error?) async {
        guard let videoId = stream.videoId,
              let failure = StreamSourcePolicy.classify(stream, error: error, at: Date()) else { return }
        switch failure {
        case .expired:
            PlaybackLog.note("stream for \(videoId) expired; re-resolving with the same order")
        case .connectivity:
            PlaybackLog.note("stream for \(videoId) lost its connection; re-resolving with the same order")
        case .sourceFailed(let source):
            session.failures.record(source, videoId: videoId, at: Date())
            PlaybackLog.problem("stream source \(source.rawValue) broke off for \(videoId); skipping it for 10 min")
        case .tokenFreeRejected:
            session.tokenFreeRejected = true
            PlaybackLog.problem("token-free account stream rejected; using a token for this session")
        }
    }

    /// Whether the signed-in account offers Premium audio. Known after the
    /// first account response of a session; for the first track (Automatic
    /// mode only), waits for it up to `firstTrackDeadline`, else assumes no.
    private func premiumAudio(awaiting accountResponse: Task<PlayerResponse, Error>, waits: Bool) async -> Bool {
        let sapisid = await CredentialStore.shared.credentials?.sapisid
        session.reset(for: sapisid)
        guard sapisid != nil else { return false }
        if let known = session.premiumAudio { return known }
        guard waits, let response = await awaitValue(of: accountResponse, within: Self.firstTrackDeadline) else {
            if waits { PlaybackLog.note("account response not there in time; assuming no Premium audio for this track") }
            return false
        }
        session.record(response)
        return session.premiumAudio ?? false
    }

    /// A stream from the visionOS client. Its URLs are complete as served: no
    /// signature, `n` parameter or PO token. Starts without waiting for the
    /// account response, whose stats URLs follow as `lateTracking`.
    private func visionOSStream(
        videoId: String,
        preferences: StreamPreferences,
        accountResponse: Task<PlayerResponse, Error>
    ) async throws -> ResolvedStream {
        let sentVisitorData = visionOSVisitorData
        var response = try await client.visionOSPlayer(videoId: videoId, visitorData: sentVisitorData)
        if let fresh = StreamSourcePolicy.retryVisitorData(after: response, sentWith: sentVisitorData) {
            visionOSVisitorData = fresh
            response = try await client.visionOSPlayer(videoId: videoId, visitorData: fresh)
        }
        PlaybackLog.note("visionOS playabilityStatus=\(response.playabilityStatus?.status ?? "nil")")
        try checkPlayability(response)

        let format = try selectAudioFormat(response, preferences: preferences)
        guard let url = StreamSourcePolicy.directURL(of: format) else {
            throw StreamError.notPlayable("visionOS stream URL needs deciphering")
        }
        PlaybackLog.note("visionOS selected itag=\(format.itag ?? -1) mime=\(format.mimeType ?? "?")")

        var stream = resolved(url: url, format: format, response: response,
                              videoId: videoId, source: .visionOS, usedToken: false)
        let visionOSTracking = response.playbackTracking
        stream.lateTracking = Task {
            let account = try? await accountResponse.value
            if let account { recordAccountResponse(account) }
            return account?.playbackTracking ?? visionOSTracking
        }
        return stream
    }

    private func recordAccountResponse(_ response: PlayerResponse) {
        session.record(response)
    }

    /// A stream from the signed-in WEB_REMIX response, deciphered in
    /// JavaScriptCore. Plays in full without a PO token for Premium accounts.
    private func accountStream(
        videoId: String,
        response: PlayerResponse,
        preferences: StreamPreferences
    ) async throws -> ResolvedStream {
        let status = response.playabilityStatus?.status ?? "nil"
        let adaptiveCount = response.streamingData?.adaptiveFormats?.count ?? 0
        PlaybackLog.note(
            "playabilityStatus=\(status) · adaptiveFormats=\(adaptiveCount) "
                + "· lengthSeconds=\(response.videoDetails?.lengthSeconds ?? "nil")"
        )

        try checkPlayability(response)

        let format = try selectAudioFormat(response, preferences: preferences)
        PlaybackLog.note("selected itag=\(format.itag ?? -1) mime=\(format.mimeType ?? "?") quality=\(preferences.audioQuality.rawValue)")

        let deciphered = try await decipher.streamURL(for: format)
        let token = try await accountToken(videoId: videoId, response: response, url: deciphered)
        var stream = resolved(url: Self.appendingPoToken(token, to: deciphered), format: format, response: response,
                              videoId: videoId, source: .account, usedToken: token != nil)
        stream.historyURL = response.playbackTracking?.playbackURL
        stream.watchtimeURL = response.playbackTracking?.watchtimeURL
        return stream
    }

    /// The PO token the account stream needs, or nil when it plays in full
    /// without one (Premium, verified once per session by a probe).
    private func accountToken(videoId: String, response: PlayerResponse, url: URL) async throws -> String? {
        let plan = StreamSourcePolicy.accountTokenPlan(
            premiumAudio: session.premiumAudio ?? false,
            tokenFreeRejected: session.tokenFreeRejected,
            tokenFreeWorks: session.tokenFreeWorks
        )
        switch plan {
        case .tokenFree:
            return nil
        case .probeThenDecide:
            if let works = await client.streamPlaysPastFirstMegabyte(url) {
                session.tokenFreeWorks = works
                PlaybackLog.note("potoken: Premium streams \(works ? "play" : "don't play") without a token")
                if works { return nil }
            }
        case .mint:
            break
        }
        let config = await currentPageConfig()
        let binding: String? = config.bindsToVideoId
            ? videoId
            : config.dataSyncId ?? response.responseContext?.visitorData
        guard let binding else {
            throw StreamError.notPlayable("no session to bind a stream token to")
        }
        return try await PoTokenProvider.shared.token(for: binding)
    }

    /// The page config deciding PO token bindings, keyed by the SAPISID it was
    /// read with (nil = signed out) so a sign-in change re-reads it.
    private var pageConfig: (sapisid: String?, config: PlayerPageConfig)?

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

    /// Tags `url` with a fresh content-playback nonce and packs the result
    /// (history URLs are set by the caller). The same nonce goes into the
    /// history ping, so YouTube correlates the two and the play counts.
    private func resolved(
        url: URL,
        format: PlayerResponse.Format,
        response: PlayerResponse,
        videoId: String,
        source: StreamSource,
        usedToken: Bool
    ) -> ResolvedStream {
        let cpn = WatchHistory.generateCPN()
        let url = WatchHistory.appendingCPN(to: url, cpn: cpn)
        PlaybackLog.note("resolved stream host=\(url.host ?? "?") source=\(source.rawValue)")
        let bitrate = format.bitrate
        let premium = session.premiumAudio ?? false
        Task { @MainActor in
            StreamStatus.shared.recordStream(from: source, bitrate: bitrate, usedToken: usedToken)
            StreamStatus.shared.recordPremiumAudio(premium)
        }
        return ResolvedStream(
            url: url,
            duration: format.approxDuration ?? response.videoDetails?.duration,
            cpn: cpn,
            loudnessDb: format.loudnessDb ?? response.playerConfig?.audioConfig?.loudnessDb,
            videoId: videoId,
            source: source,
            usedToken: usedToken
        )
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
