import AVFoundation
import CoreImage
import UIKit

// MARK: - RenderPlan

/// Immutable snapshot of everything the compositor needs to draw a frame.
/// Built once per composition on the main side and read on the render queue.
final class RenderPlan: @unchecked Sendable {

    struct ClipLayer: Sendable {
        var clip: Clip
        var trackID: CMPersistentTrackID
        var orientation: CGImagePropertyOrientation
        var placement: TimelineLayout.Placement
    }

    struct OverlayLayer: Sendable {
        var item: OverlayItem
        var trackID: CMPersistentTrackID
        var orientation: CGImagePropertyOrientation
    }

    struct Options: Hashable, Sendable {
        var renderSize: CGSize
        var frameRate: Int = 30
        var watermark: Bool = false
        var ultraHD: Bool = false
        var smartHDR: Bool = false
        /// Preview renders use faster Vision/blur settings.
        var isPreview: Bool = true

        static func preview(for timeline: Timeline) -> Options {
            let size = timeline.aspectRatio.renderSize(shortSide: 720)
            return Options(renderSize: CGSize(width: size.width, height: size.height))
        }
    }

    let timeline: Timeline
    let layout: TimelineLayout
    let options: Options
    let clipLayers: [ClipLayer]
    let overlayLayers: [OverlayLayer]

    var renderSize: CGSize { options.renderSize }
    var canvas: CGRect { CGRect(origin: .zero, size: options.renderSize) }

    private let lock = NSLock()
    private var textCache: [String: CIImage] = [:]
    private var autoCache: [UUID: FilterRenderer.AutoAdjustment] = [:]
    private var lastMasks: [UUID: CIImage] = [:]

    init(timeline: Timeline, layout: TimelineLayout, options: Options, clipLayers: [ClipLayer], overlayLayers: [OverlayLayer]) {
        self.timeline = timeline
        self.layout = layout
        self.options = options
        self.clipLayers = clipLayers
        self.overlayLayers = overlayLayers
    }

    // MARK: Caches (render queue)

    func cachedText(_ key: String, make: () -> CIImage?) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = textCache[key] { return hit }
        guard let made = make() else { return nil }
        if textCache.count > 400 { textCache.removeAll() }
        textCache[key] = made
        return made
    }

    func autoAdjustment(for clipID: UUID, make: () -> FilterRenderer.AutoAdjustment) -> FilterRenderer.AutoAdjustment {
        lock.lock(); defer { lock.unlock() }
        if let hit = autoCache[clipID] { return hit }
        let made = make()
        autoCache[clipID] = made
        return made
    }

    /// Remembers the last good segmentation mask so a missed detection doesn't flash.
    func mask(for id: UUID, fresh: CIImage?) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let fresh { lastMasks[id] = fresh; return fresh }
        return lastMasks[id]
    }
}

// MARK: - CompositionInstruction

final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    // Effects and animations change every frame.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let segment: TimelineLayout.Segment
    let plan: RenderPlan

    init(timeRange: CMTimeRange, segment: TimelineLayout.Segment, trackIDs: [CMPersistentTrackID], plan: RenderPlan) {
        self.timeRange = timeRange
        self.segment = segment
        self.plan = plan
        var seen = Set<CMPersistentTrackID>()
        let unique = trackIDs.filter { seen.insert($0).inserted }
        self.requiredSourceTrackIDs = unique.isEmpty ? nil : unique.map { NSNumber(value: $0) }
        super.init()
    }
}
