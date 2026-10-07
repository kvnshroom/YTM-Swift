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
