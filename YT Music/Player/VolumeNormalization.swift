//
//  VolumeNormalization.swift
//  YT Music
//

import Foundation

/// YouTube-style loudness normalization: tracks louder than the reference level
/// are turned down to it; quieter tracks are left alone.
nonisolated enum VolumeNormalization {
    static func gain(loudnessDb: Double?) -> Double {
        guard let loudnessDb, loudnessDb > 0 else { return 1 }
        return pow(10, -loudnessDb / 20)
    }
}
