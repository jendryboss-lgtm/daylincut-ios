import AVFoundation
import CoreImage
import CoreVideo

// MARK: - ClipCompositor

/// Custom `AVVideoCompositing` that renders every frame with Core Image on Metal.
/// Used for both the live `AVPlayer` preview and `AVAssetReader` exports.
class ClipCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    private let renderQueue = DispatchQueue(label: "com.daylincut.compositor", qos: .userInteractive)
    private let stateLock = NSLock()
    private var cancelled = false
    private var renderContext: AVVideoCompositionRenderContext?

    class var pixelFormat: OSType { kCVPixelFormatType_32BGRA }
    class var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    #if compiler(>=6.0)
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [Int(Self.pixelFormat)],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Int(Self.pixelFormat)],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    #else
    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [Int(Self.pixelFormat)],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Int(Self.pixelFormat)],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    #endif

    var supportsWideColorSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateLock.lock()
        renderContext = newRenderContext
        stateLock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            self.stateLock.lock()
            let isCancelled = self.cancelled
            self.stateLock.unlock()
            if isCancelled {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                self.render(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
        // Requests already queued finish as cancelled; flip back for new requests.
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.cancelled = false
            self.stateLock.unlock()
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "DaylinCut.Compositor", code: -1,
                                         userInfo: [NSLocalizedDescriptionKey: "Missing instruction or output buffer"]))
            return
        }
        let time = request.compositionTime.seconds
        let image = FrameRenderer.render(plan: instruction.plan,
                                         segment: instruction.segment,
                                         time: time,
                                         source: { request.sourceFrame(byTrackID: $0) })
        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)
        // Plans are built for the same render size, but guard against mismatch.
        var final = image
        if abs(image.extent.width - size.width) > 1 || abs(image.extent.height - size.height) > 1 {
            let sx = size.width / max(1, image.extent.width), sy = size.height / max(1, image.extent.height)
            final = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        RenderContext.shared.render(final.cropped(to: canvas), to: output, bounds: canvas, colorSpace: Self.colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}

/// 10-bit compositor used for Smart HDR exports (HEVC Main10 / HLG).
final class HDRClipCompositor: ClipCompositor, @unchecked Sendable {
    override class var pixelFormat: OSType { kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
    override class var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.itur_2100_HLG) ?? CGColorSpace(name: CGColorSpace.sRGB)! }
}
