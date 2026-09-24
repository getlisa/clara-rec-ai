import MWDATCamera
import SwiftUI

enum VideoQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var detail: String {
        switch self {
        case .low: return "360 × 640 — most reliable over Bluetooth"
        case .medium: return "504 × 896 — balanced"
        case .high: return "720 × 1280 — best quality, needs a strong link"
        }
    }

    var resolution: StreamingResolution {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

enum AppSettings {
    static let videoQualityKey = "videoQuality"

    /// Auto-import photos taken with the glasses' own button onto the open estimate.
    /// On by default: it is the reason a technician wears the glasses while quoting.
    static let handsFreeCaptureKey = "handsFreeCapture"

    static var handsFreeCapture: Bool {
        // `object(forKey:)` rather than `bool(forKey:)` so an unset value reads as the default
        // rather than as false.
        UserDefaults.standard.object(forKey: handsFreeCaptureKey) as? Bool ?? true
    }

    static var videoQuality: VideoQuality {
        let raw = UserDefaults.standard.string(forKey: videoQualityKey) ?? VideoQuality.medium.rawValue
        return VideoQuality(rawValue: raw) ?? .medium
    }
}
