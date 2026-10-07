//
//  PlayerResponse.swift
//  YT Music
//
//  Decodable models for the InnerTube `player` endpoint, which returns playback
//  status and the available media streams for a video.
//

import Foundation

struct PlayerResponse: Decodable, Sendable {
    let playabilityStatus: PlayabilityStatus?
    let streamingData: StreamingData?
    let videoDetails: VideoDetails?
    let playbackTracking: PlaybackTracking?
    let playerConfig: PlayerConfig?

    nonisolated struct PlayerConfig: Decodable, Sendable {
        let audioConfig: AudioConfig?

        nonisolated struct AudioConfig: Decodable, Sendable {
            let loudnessDb: Double?
            let perceptualLoudnessDb: Double?
        }
    }

    var responseContext: ResponseContext? = nil

    /// The visitor id YouTube assigned this session. A signed-out stream's PO
    /// token is bound to it (see `PoTokenProvider`).
    nonisolated struct ResponseContext: Decodable, Sendable {
        let visitorData: String?
    }

    struct PlayabilityStatus: Decodable, Sendable {
        let status: String?     // "OK", "LOGIN_REQUIRED", "UNPLAYABLE", "ERROR"
        let reason: String?
    }

    /// Stats endpoints the web player pings during playback. Pinging
    /// `videostatsPlaybackUrl` (with a content-playback nonce) is what registers
    /// a play in the signed-in user's YouTube Music watch history.
    nonisolated struct PlaybackTracking: Decodable, Sendable {
        let videostatsPlaybackUrl: TrackingURL?
        let videostatsWatchtimeUrl: TrackingURL?

        nonisolated struct TrackingURL: Decodable, Sendable {
            let baseUrl: String?
        }
    }

    /// Authoritative metadata for the video — notably `lengthSeconds`, which is
    /// the true track length (AVPlayer's `duration` can be a bad estimate while a
    /// progressive stream is still buffering).
    nonisolated struct VideoDetails: Decodable, Sendable {
        let lengthSeconds: String?
        let title: String?
        let author: String?

        var duration: Double? { lengthSeconds.flatMap(Double.init) }
    }

    struct StreamingData: Decodable, Sendable {
        let adaptiveFormats: [Format]?
        let formats: [Format]?
    }

    /// A single media stream. Either `url` is present directly, or the URL is
    /// hidden inside `signatureCipher` and must be deciphered.
    nonisolated struct Format: Decodable, Sendable {
        let itag: Int?
        let mimeType: String?
        let bitrate: Int?
        let url: String?
        let signatureCipher: String?
        let cipher: String?         // older key name
        let audioQuality: String?
        let loudnessDb: Double?
        /// This stream's own length in milliseconds — more precise than
        /// `lengthSeconds`, which is rounded to whole seconds.
        var approxDurationMs: String? = nil

        var cipherString: String? { signatureCipher ?? cipher }

        var approxDuration: Double? {
            approxDurationMs.flatMap(Double.init).map { $0 / 1000 }
        }

        var isAudio: Bool { (mimeType ?? "").hasPrefix("audio/") }

        /// AVFoundation can't decode Opus/WebM, so we only consider MP4/AAC.
        var isAVPlayerCompatible: Bool {
            let type = mimeType ?? ""
            return type.contains("mp4") || type.contains("mp4a")
        }
    }
}
