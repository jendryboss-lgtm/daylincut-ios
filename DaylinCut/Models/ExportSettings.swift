import Foundation

// MARK: - ExportResolution

enum ExportResolution: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case k2 = 1440
    case k4 = 2160

    var id: Int { rawValue }
    var shortSide: Int { rawValue }

    var title: String {
        switch self {
        case .p480: return "480P"
        case .p720: return "720P"
        case .p1080: return "1080P"
        case .k2: return "2K"
        case .k4: return "4K"
        }
    }

    var subtitle: String {
        switch self {
        case .p480: return "Standard definition – smallest file size"
        case .p720: return "HD – great for quick sharing"
        case .p1080: return "High definition – the ultimate viewing experience"
        case .k2: return "Quad HD – extra crisp on large screens"
        case .k4: return "Ultra HD – maximum detail"
        }
    }

    var requiresPro: Bool { self == .k4 }

    /// Recommended bitrate in Mbps at 30 fps.
    var recommendedBitrate: Double {
        switch self {
        case .p480: return 2.5
        case .p720: return 5
        case .p1080: return 10
        case .k2: return 16
        case .k4: return 35
        }
    }
}

// MARK: - ExportSettings

struct ExportSettings: Codable, Hashable, Sendable {
    static let frameRates: [Int] = [24, 25, 30, 50, 60]

    var resolution: ExportResolution = .p1080
    var frameRate: Int = 30
    /// Video bitrate in Mbps.
    var bitrateMbps: Double = ExportResolution.p1080.recommendedBitrate
    var aiUltraHD: Bool = false
    var smartHDR: Bool = false
    var shareToTikTok: Bool = false
    var tikTokPromote: Bool = false
    var saveToPhotos: Bool = true
    var addWatermark: Bool = true
    var audioBitrateKbps: Int = 192

    /// Bitrate recommended for the current resolution and frame rate.
    var recommendedBitrate: Double {
        let base = resolution.recommendedBitrate
        return frameRate > 30 ? base * 1.5 : base
    }

    mutating func resetBitrate() { bitrateMbps = recommendedBitrate }

    var bitsPerSecond: Int { Int(bitrateMbps * 1_000_000) }

    /// Estimated output size in bytes for a video of `duration` seconds.
    func estimatedBytes(duration: Double) -> Double {
        let videoBits = bitrateMbps * 1_000_000 * (smartHDR ? 1.1 : 1)
        let audioBits = Double(audioBitrateKbps) * 1000
        let containerOverhead = 1.02
        return (videoBits + audioBits) * max(0, duration) / 8 * containerOverhead
    }

    func estimatedSizeText(duration: Double) -> String {
        let mb = estimatedBytes(duration: duration) / 1_000_000
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
        return String(format: "%.1f MB", mb)
    }

    func renderSize(for aspect: AspectRatio) -> (width: Int, height: Int) {
        aspect.renderSize(shortSide: resolution.shortSide)
    }
}
