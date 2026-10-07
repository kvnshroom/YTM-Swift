//
//  StreamSourcePolicy.swift
//  YT Music
//
//  The decisions behind choosing where a track's stream comes from, kept free
//  of networking so they can be unit-tested. StreamResolver applies them.
//
//  Background (2026-10): googlevideo cuts signed-in WEB_REMIX streams without a
//  PO token after ~1 MB, except for Premium accounts (yt-dlp:
//  `not_required_for_premium`, innertubex: `premiumMayBypass`). The visionOS
//  client serves complete streams without a token or deciphering. So free
//  accounts stream from visionOS, Premium accounts from the account (256 kbps,
//  itag 141), each falling back to the other.
//

import Foundation

/// Where a track's stream URL comes from.
nonisolated enum StreamSource: String, Codable, CaseIterable, Sendable, Hashable {
    /// The anonymous visionOS client: complete AAC streams up to 128 kbps with
    /// no PO token and no deciphering. Can't play private uploads or
    /// age-restricted / made-for-kids videos.
    case visionOS
    /// The signed-in WEB_REMIX client. Plays everything the account can,
    /// including Premium's 256 kbps AAC.
    case account
}

nonisolated enum StreamSourcePolicy {
    /// The automatic order: visionOS first, unless the account offers Premium
    /// audio and the best quality is wanted. Both sources are always listed, so
    /// each is the other's fallback.
    static func automaticOrder(quality: AudioQuality, premiumAudio: Bool) -> [StreamSource] {
        let wantsBest = quality == .auto || quality == .high
        return premiumAudio && wantsBest ? [.account, .visionOS] : [.visionOS, .account]
    }

    /// Whether a player response lists Premium's 256 kbps AAC (itag 141). YT
    /// Music serves it only to Premium accounts, so it doubles as detection.
    static func offersPremiumAudio(_ response: PlayerResponse) -> Bool {
        (response.streamingData?.adaptiveFormats ?? []).contains { $0.itag == 141 && $0.isAVPlayerCompatible }
    }

    /// The visitor id to retry a visionOS request with: YouTube answers a
    /// request without one (or with one it no longer accepts) with
    /// `LOGIN_REQUIRED` and a fresh id. nil when a retry wouldn't help.
    static func retryVisitorData(after response: PlayerResponse, sentWith sent: String?) -> String? {
        guard response.playabilityStatus?.status == "LOGIN_REQUIRED",
              let fresh = response.responseContext?.visitorData,
              fresh != sent else { return nil }
        return fresh
    }

    /// The format's URL when it is served ready to play, nil when it is hidden
    /// behind a signature cipher.
    static func directURL(of format: PlayerResponse.Format) -> URL? {
        guard format.cipherString == nil else { return nil }
        return format.url.flatMap { URL(string: $0) }
    }
}

/// What the resolver knows about the signed-in account during this app
/// session. Nothing is persisted: it starts over on relaunch and when the
/// signed-in account (SAPISID) changes.
nonisolated struct StreamSession: Sendable {
    private(set) var sapisid: String?
    /// Whether the latest account response offered Premium audio; nil until
    /// one was seen. Re-read on every response, so an expired or new
    /// subscription takes effect from the next track on.
    private(set) var premiumAudio: Bool?
    /// Sources to skip for a video after its stream broke off.
    var failures = StreamFailureMemory()

    /// Starts over when the signed-in account changed.
    mutating func reset(for sapisid: String?) {
        guard sapisid != self.sapisid else { return }
        self = StreamSession()
        self.sapisid = sapisid
    }

    mutating func record(_ response: PlayerResponse) {
        premiumAudio = StreamSourcePolicy.offersPremiumAudio(response)
    }
}

/// Why a stream died mid-track.
nonisolated enum StreamFailure: Equatable, Sendable {
    /// The URL outlived googlevideo's expiry (e.g. a long pause): the source is fine.
    case expired
    /// The source served a stream that broke off.
    case sourceFailed(StreamSource)
}

extension StreamSourcePolicy {
    /// A stream older than this has most likely just expired.
    static let expiryAge: TimeInterval = 3600

    /// Classifies a stream that died mid-track; nil when its source is unknown.
    static func classify(_ stream: ResolvedStream, at now: Date) -> StreamFailure? {
        guard let source = stream.source else { return nil }
        if now.timeIntervalSince(stream.resolvedAt) > expiryAge { return .expired }
        return .sourceFailed(source)
    }
}

/// Sources that broke off for a video recently, skipped for that video for a
/// while (like Metrolist's `streamClientFailures`). Nothing outlives the session.
nonisolated struct StreamFailureMemory: Sendable {
    static let lifetime: TimeInterval = 600

    private var entries: [String: [StreamSource: Date]] = [:]

    mutating func record(_ source: StreamSource, videoId: String, at now: Date) {
        entries[videoId, default: [:]][source] = now
    }

    func excluded(for videoId: String, at now: Date) -> Set<StreamSource> {
        Set((entries[videoId] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.lifetime }.keys)
    }
}

/// The task's value if it succeeds within `seconds`, else nil. The task keeps
/// running either way, so its result can still be used later. (A task group
/// can't do this: it waits for every child, including one stuck on `task`.)
nonisolated func awaitValue<T: Sendable>(of task: Task<T, Error>, within seconds: Double) async -> T? {
    let race = FirstResult<T?>()
    return await withCheckedContinuation { continuation in
        race.start(continuation)
        Task { race.finish(try? await task.value) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            race.finish(nil)
        }
    }
}

/// Resumes a continuation with whichever result arrives first.
private nonisolated final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func start(_ continuation: CheckedContinuation<Value, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
