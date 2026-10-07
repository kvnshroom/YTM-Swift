//
//  StreamStatus.swift
//  YT Music
//
//  What the stream resolver last did, for the Playback settings: which source
//  served the last stream at what bitrate, whether it needed a web token, and
//  whether the signed-in account offers Premium audio.
//

import Foundation

@MainActor
@Observable
final class StreamStatus {
    static let shared = StreamStatus()

    private(set) var lastSource: StreamSource?
    /// Bitrate of the last stream in bits per second, as YouTube reports it.
    private(set) var lastBitrate: Int?
    private(set) var lastUsedToken = false
    private(set) var premiumAudioDetected = false

    func recordStream(from source: StreamSource, bitrate: Int?, usedToken: Bool) {
        lastSource = source
        lastBitrate = bitrate
        lastUsedToken = usedToken
    }

    func recordPremiumAudio(_ detected: Bool) {
        premiumAudioDetected = detected
    }
}
