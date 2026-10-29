import AVFoundation
import CoreImage
import UIKit

// MARK: - FrameRenderer

/// Draws one output frame of a `RenderPlan`. Stateless apart from the plan's caches,
/// so it is used by the compositor (preview + export) and by unit tests.
enum FrameRenderer {

    typealias SourceProvider = (CMPersistentTrackID) -> CVPixelBuffer?

    static func render(plan: RenderPlan, segment: TimelineLayout.Segment, time: Double, source: SourceProvider) -> CIImage {
        let canvas = plan.canvas
        var frame: CIImage
        switch segment.kind {
        case .single(let index):
            frame = renderClip(index, plan: plan, time: time, source: source)
        case .transition(let from, let to, let type):
            let a = renderClip(from, plan: plan, time: time, source: source)
            let b = renderClip(to, plan: plan, time: time, source: source)
            let progress = segment.duration > 0 ? (time - segment.start) / segment.duration : 1
            frame = FilterRenderer.transition(type, from: a, to: b, progress: progress, canvas: canvas)
        }

        frame = composeOverlays(on: frame, plan: plan, time: time, source: source)
        frame = composeTexts(on: frame, plan: plan, time: time)
        frame = composeCaptions(on: frame, plan: plan, time: time)

        if plan.options.smartHDR {
            frame = FilterRenderer.smartHDR(frame)
        }
        if plan.options.watermark, let mark = plan.cachedText("wm-\(Int(canvas.width))", make: {
            TextImageRenderer.watermark(canvasWidth: canvas.width).map { CIImage(cgImage: $0) }
        }) {
            let margin = canvas.width * 0.04
            let placed = mark.transformed(by: CGAffineTransform(translationX: canvas.maxX - mark.extent.width - margin,
                                                                y: canvas.minY + margin))
            frame = placed.composited(over: frame)
        }
        return frame.cropped(to: canvas)
    }

    // MARK: Clip

    static func renderClip(_ index: Int, plan: RenderPlan, time: Double, source: SourceProvider) -> CIImage {
        let canvas = plan.canvas
        guard plan.clipLayers.indices.contains(index) else { return CIImage(color: .black).cropped(to: canvas) }
        let layer = plan.clipLayers[index]
        let clip = layer.clip
        guard let buffer = source(layer.trackID) else {
            return background(plan.timeline.background, content: nil, canvas: canvas, isPreview: plan.options.isPreview)
        }

        var image = CIImage(cvPixelBuffer: buffer).oriented(layer.orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let local = max(0, time - layer.placement.start)
        let progress = layer.placement.duration > 0 ? min(1, local / layer.placement.duration) : 0

        image = look(for: clip, image: image, plan: plan, localTime: local, progress: progress)

        // Subject isolation.
        var subject = image
        if clip.removeBackground {
            let fresh = SegmentationService.personMask(for: image, quality: plan.options.isPreview ? .fast : .accurate)
            if let mask = plan.mask(for: clip.id, fresh: fresh) {
                subject = SegmentationService.cutOut(image, mask: mask)
            }
        }

        // Fit into canvas.
        let fit = min(canvas.width / max(1, image.extent.width), canvas.height / max(1, image.extent.height))
        let geo = FilterRenderer.geometry(for: clip.effect, progress: progress, localTime: local, canvas: canvas.size)
        let scale = fit * CGFloat(max(0.2, clip.adjustments.zoom)) * geo.scale
        let w = image.extent.width * scale, h = image.extent.height * scale
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: canvas.midX - w / 2 + geo.dx, y: canvas.midY - h / 2 + geo.dy))
        let placed = subject.transformed(by: transform)

        let bgContent: CIImage? = clip.removeBackground ? nil : image
        let bg = background(plan.timeline.background, content: bgContent, canvas: canvas, isPreview: plan.options.isPreview)
        return placed.composited(over: bg).cropped(to: canvas)
    }

    /// Colour pipeline for a clip (enhance → adjustments → filter → AI HD → effect).
    static func look(for clip: Clip, image: CIImage, plan: RenderPlan?, localTime: Double, progress: Double) -> CIImage {
        var out = image
        if clip.autoEnhance {
            let auto: FilterRenderer.AutoAdjustment
            if let plan {
                let snapshot = out
                auto = plan.autoAdjustment(for: clip.id) { FilterRenderer.autoAdjustment(for: snapshot) }
            } else {
                auto = FilterRenderer.autoAdjustment(for: out)
            }
            out = FilterRenderer.apply(auto, to: out)
        }
        out = FilterRenderer.apply(clip.adjustments, to: out)
        out = FilterRenderer.apply(clip.filter, intensity: clip.filterIntensity, to: out)
        if clip.aiUltraHD || (plan?.options.ultraHD ?? false) {
            out = FilterRenderer.ultraHD(out)
        }
        out = FilterRenderer.apply(clip.effect, to: out, progress: progress, localTime: localTime)
        return out
    }

    static func background(_ kind: CanvasBackground, content: CIImage?, canvas: CGRect, isPreview: Bool) -> CIImage {
        switch kind {
        case .black:
            return CIImage(color: .black).cropped(to: canvas)
        case .white:
            return CIImage(color: .white).cropped(to: canvas)
        case .gradient:
            return FilterRenderer.gradientBackground(canvas)
        case .blur:
            guard let content else { return FilterRenderer.gradientBackground(canvas) }
            // Aspect-fill, downscale, blur, upscale: cheap and smooth.
            let fill = max(canvas.width / max(1, content.extent.width), canvas.height / max(1, content.extent.height))
            let down: CGFloat = 0.125
            let small = content.transformed(by: CGAffineTransform(scaleX: fill * down, y: fill * down))
            let blurred = small.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: isPreview ? 6 : 8])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08, kCIInputSaturationKey: 1.1])
                .cropped(to: small.extent)
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            let w = blurred.extent.width, h = blurred.extent.height
            let centered = blurred.transformed(by: CGAffineTransform(translationX: canvas.midX - w / 2 - blurred.extent.minX,
                                                                     y: canvas.midY - h / 2 - blurred.extent.minY))
            return centered.clampedToExtent().cropped(to: canvas)
        }
    }

    // MARK: Overlays (picture-in-picture)

    static func composeOverlays(on base: CIImage, plan: RenderPlan, time: Double, source: SourceProvider) -> CIImage {
        var out = base
        let canvas = plan.canvas
        for layer in plan.overlayLayers {
            let item = layer.item
            guard time >= item.start, time < item.end, let buffer = source(layer.trackID) else { continue }
            var image = CIImage(cvPixelBuffer: buffer).oriented(layer.orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            if item.removeBackground {
                let fresh = SegmentationService.personMask(for: image, quality: plan.options.isPreview ? .fast : .balanced)
                if let mask = plan.mask(for: item.id, fresh: fresh) {
                    image = SegmentationService.cutOut(image, mask: mask)
                }
            }
            let targetW = canvas.width * CGFloat(item.widthScale)
            let scale = targetW / max(1, image.extent.width)
            let w = image.extent.width * scale, h = image.extent.height * scale
            // Model coordinates are top-left based; Core Image is bottom-left.
            let cx = canvas.width * CGFloat(item.centerX)
            let cy = canvas.height * (1 - CGFloat(item.centerY))
            var placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: cx - w / 2, y: cy - h / 2)))
            if item.opacity < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(item.opacity))
                ])
            }
            out = placed.composited(over: out)
        }
        return out
    }

    // MARK: Text

    static func composeTexts(on base: CIImage, plan: RenderPlan, time: Double) -> CIImage {
        var out = base
        let canvas = plan.canvas
        for text in plan.timeline.texts where text.isVisible(at: time) {
            let local = time - text.start
            let state = TextImageRenderer.animationState(text.animation, text: text.text, localTime: local, duration: text.duration)
            var string = text.text
            if let n = state.visibleCharacters { string = String(string.prefix(n)) }
            let pointSize = canvas.height * CGFloat(text.fontScale)
            let key = "t-\(text.id)-\(string.hashValue)-\(text.style.rawValue)-\(text.colorHex)-\(text.fontName)-\(Int(pointSize))-\(Int(canvas.width))"
            guard let image = plan.cachedText(key, make: {
                TextImageRenderer.render(text: string, fontName: text.fontName, pointSize: pointSize,
                                         color: UIColor(hex: text.colorHex), style: text.style,
                                         maxWidth: canvas.width * 0.92).map { CIImage(cgImage: $0) }
            }) else { continue }
            out = place(image, on: out, canvas: canvas, centerX: text.centerX, centerY: text.centerY, state: state)
        }
        return out
    }

    static func composeCaptions(on base: CIImage, plan: RenderPlan, time: Double) -> CIImage {
        let canvas = plan.canvas
        let style = plan.timeline.captionStyle
        guard let caption = plan.timeline.captions.first(where: { $0.isVisible(at: time) }) else { return base }
        let string = style.uppercase ? caption.text.uppercased() : caption.text
        let pointSize = canvas.height * CGFloat(style.fontScale)
        let key = "c-\(caption.id)-\(string.hashValue)-\(style.style.rawValue)-\(style.colorHex)-\(Int(pointSize))"
        guard let image = plan.cachedText(key, make: {
            TextImageRenderer.render(text: string, fontName: "AvenirNext-Bold", pointSize: pointSize,
                                     color: UIColor(hex: style.colorHex), style: style.style,
                                     maxWidth: canvas.width * 0.86).map { CIImage(cgImage: $0) }
        }) else { return base }
        let local = time - caption.start
        let state = TextImageRenderer.animationState(.pop, text: string, localTime: local, duration: caption.duration)
        return place(image, on: base, canvas: canvas, centerX: 0.5, centerY: style.centerY, state: state)
    }

    static func place(_ image: CIImage, on base: CIImage, canvas: CGRect, centerX: Double, centerY: Double, state: TextImageRenderer.Animated) -> CIImage {
        let s = CGFloat(state.scale)
        let w = image.extent.width * s, h = image.extent.height * s
        let cx = canvas.width * CGFloat(centerX)
        let cy = canvas.height * (1 - CGFloat(centerY)) + canvas.height * CGFloat(state.offsetY)
        var placed = image.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: cx - w / 2, y: cy - h / 2)))
        if state.opacity < 0.999 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, state.opacity)))
            ])
        }
        return placed.composited(over: base)
    }
}
