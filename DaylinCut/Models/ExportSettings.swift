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

// MARK: - ExportFormat

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case video, gif
    var id: String { rawValue }
    /// Tab titles exactly as shown in the export panel.
    var title: String { self == .video ? "video" : "GIF" }
}

// MARK: - ExportCodec

enum ExportCodec: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic, h264, hevc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
    var subtitle: String {
        switch self {
        case .automatic: return "H.264 up to 1080p, HEVC above"
        case .h264: return "Plays everywhere"
        case .hevc: return "Smaller files, same quality"
        }
    }
}

// MARK: - ExportSettings

struct ExportSettings: Codable, Hashable, Sendable {
    static let frameRates: [Int] = [24, 25, 30, 50, 60]
    /// Bitrate stops (Mbps) offered by the export panel.
    static let bitrateOptions: [Double] = [5, 10, 20, 50, 100]
    /// GIF frame rates and short-side sizes (GIFs are kept small on purpose).
    static let gifFrameRates: [Int] = [10, 15, 20, 25]
    static let gifSizes: [Int] = [240, 360, 480]

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
    var format: ExportFormat = .video
    var codec: ExportCodec = .automatic
    var gifFrameRate: Int = 15
    var gifShortSide: Int = 360

    init() {}

    private enum CodingKeys: String, CodingKey {
        case resolution, frameRate, bitrateMbps, aiUltraHD, smartHDR, shareToTikTok, tikTokPromote, saveToPhotos, addWatermark, audioBitrateKbps, format, codec, gifFrameRate, gifShortSide
    }

    /// Tolerant decoding: settings saved by older builds keep their values and
    /// new fields fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(ExportResolution.self, forKey: .resolution) { resolution = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .frameRate) { frameRate = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .bitrateMbps) { bitrateMbps = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .aiUltraHD) { aiUltraHD = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .smartHDR) { smartHDR = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .shareToTikTok) { shareToTikTok = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .tikTokPromote) { tikTokPromote = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .saveToPhotos) { saveToPhotos = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .addWatermark) { addWatermark = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) { audioBitrateKbps = v }
        if let v = try? c.decodeIfPresent(ExportFormat.self, forKey: .format) { format = v }
        if let v = try? c.decodeIfPresent(ExportCodec.self, forKey: .codec) { codec = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .gifFrameRate) { gifFrameRate = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .gifShortSide) { gifShortSide = v }
    }

    /// Bitrate recommended for the current resolution and frame rate.
    var recommendedBitrate: Double {
        let base = resolution.recommendedBitrate
        return frameRate > 30 ? base * 1.5 : base
    }

    mutating func resetBitrate() { bitrateMbps = recommendedBitrate }

    /// Whether the SDR render uses HEVC for a frame of this size.
    func usesHEVC(width: Int, height: Int) -> Bool {
        switch codec {
        case .automatic: return width * height > 1920 * 1080
        case .h264: return false
        case .hevc: return true
        }
    }

    /// The bitrate stop closest to the recommendation ("Recommended for this video (10)").
    var recommendedBitrateOption: Double { Self.nearestBitrateOption(to: recommendedBitrate) }

    /// Index of the current bitrate among `bitrateOptions` (nearest stop).
    var bitrateOptionIndex: Int {
        let target = Self.nearestBitrateOption(to: bitrateMbps)
        return Self.bitrateOptions.firstIndex(of: target) ?? 1
    }

    static func nearestBitrateOption(to mbps: Double) -> Double {
        bitrateOptions.min(by: { abs(log($0) - log(max(mbps, 0.1))) < abs(log($1) - log(max(mbps, 0.1))) }) ?? 10
    }

    /// Size of a GIF frame for the timeline aspect.
    func gifRenderSize(for aspect: AspectRatio) -> (width: Int, height: Int) {
        aspect.renderSize(shortSide: gifShortSide)
    }

    /// Rough GIF size: palette-indexed frames compress to ~0.35 bytes per pixel.
    func estimatedGIFBytes(duration: Double, aspect: AspectRatio) -> Double {
        let size = gifRenderSize(for: aspect)
        let frames = (max(0, duration) * Double(gifFrameRate)).rounded(.up)
        return Double(size.width * size.height) * 0.35 * frames
    }

    /// Estimated size text for the selected format.
    func estimatedSizeText(duration: Double, aspect: AspectRatio) -> String {
        guard format == .gif else { return estimatedSizeText(duration: duration) }
        return Self.sizeText(bytes: estimatedGIFBytes(duration: duration, aspect: aspect))
    }

    static func sizeText(bytes: Double) -> String {
        let mb = bytes / 1_000_000
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
        return String(format: "%.1f MB", mb)
    }

    var bitsPerSecond: Int { Int(bitrateMbps * 1_000_000) }

    /// Estimated output size in bytes for a video of `duration` seconds.
    func estimatedBytes(duration: Double) -> Double {
        let videoBits = bitrateMbps * 1_000_000 * (smartHDR ? 1.1 : 1)
        let audioBits = Double(audioBitrateKbps) * 1000
        let containerOverhead = 1.02
        return (videoBits + audioBits) * max(0, duration) / 8 * containerOverhead
    }

    func estimatedSizeText(duration: Double) -> String {
        Self.sizeText(bytes: estimatedBytes(duration: duration))
    }

    func renderSize(for aspect: AspectRatio) -> (width: Int, height: Int) {
        aspect.renderSize(shortSide: resolution.shortSide)
    }
}
