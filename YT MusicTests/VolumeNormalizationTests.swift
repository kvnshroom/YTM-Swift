//
//  VolumeNormalizationTests.swift
//  YT MusicTests
//

import Testing
import Foundation
@testable import YT_Music

@Suite("Volume normalization")
struct VolumeNormalizationTests {
    @Test("Tracks at or below the reference level are left alone")
    func quietTracksUnchanged() {
        #expect(VolumeNormalization.gain(loudnessDb: nil) == 1)
        #expect(VolumeNormalization.gain(loudnessDb: 0) == 1)
        #expect(VolumeNormalization.gain(loudnessDb: -14.7) == 1)
    }

    @Test("Louder tracks are attenuated by their excess loudness")
    func loudTracksAttenuated() {
        #expect(abs(VolumeNormalization.gain(loudnessDb: 6) - 0.501) < 0.001)
        #expect(abs(VolumeNormalization.gain(loudnessDb: 20) - 0.1) < 0.0001)
    }

    @Test("Reads track loudness from the player response")
    func decodesLoudness() throws {
        let json = """
        { "playerConfig": { "audioConfig": { "loudnessDb": 1.76, "perceptualLoudnessDb": -5.24 } },
          "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4", "bitrate": 130000, "loudnessDb": 1.7 }
          ] } }
        """
        let response = try JSONDecoder().decode(PlayerResponse.self, from: Data(json.utf8))
        #expect(response.playerConfig?.audioConfig?.loudnessDb == 1.76)
        #expect(response.streamingData?.adaptiveFormats?.first?.loudnessDb == 1.7)
    }
}
