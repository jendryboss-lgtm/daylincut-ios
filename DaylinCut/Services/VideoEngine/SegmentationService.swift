import CoreImage
import Vision

// MARK: - SegmentationService

/// On-device subject isolation with Vision.
/// - Video frames: `VNGeneratePersonSegmentationRequest` (fast, temporally stable).
/// - Photos: `VNGenerateForegroundInstanceMaskRequest` (any salient subject, iOS 17).
enum SegmentationService {

    enum Quality { case fast, balanced, accurate }

    /// Returns a mask (white = person) the size of `image.extent`, or nil when no person is found.
    static func personMask(for image: CIImage, quality: Quality) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        switch quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        return scaledMask(CIImage(cvPixelBuffer: buffer), to: image.extent)
    }

    /// Subject (foreground) mask for still images.
    static func subjectMask(for image: CIImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return personMask(for: image, quality: .accurate) }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return scaledMask(CIImage(cvPixelBuffer: buffer), to: image.extent)
        } catch {
            return personMask(for: image, quality: .accurate)
        }
    }

    /// Cuts the subject out of `image`, leaving transparency elsewhere.
    static func cutOut(_ image: CIImage, mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }

    /// Bounding box (in image coordinates) of detected humans, used by the AI clipper.
    static func humanRects(in cgImage: CGImage) -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Face rectangles (normalised, Vision coordinates) used by Retouch.
    static func faceRects(in image: CIImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    private static func scaledMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let sx = extent.width / max(1, mask.extent.width)
        let sy = extent.height / max(1, mask.extent.height)
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
