import CoreImage
import Metal
import Foundation
import UIKit

// MARK: - FilterRenderer

/// Core Image implementations for filters, adjustments, effects and transitions.
/// Every function is a pure `CIImage -> CIImage` transform so it can be used by the
/// video compositor, the photo editor and the thumbnail generator alike.
enum FilterRenderer {

    // MARK: Filters

    static func apply(_ preset: FilterPreset, intensity: Double, to image: CIImage) -> CIImage {
        guard preset != .none, intensity > 0.001 else { return image }
        let extent = image.extent
        var out: CIImage
        switch preset {
        case .none:
            out = image
        case .vivid:
            out = image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.08])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4])
        case .warm:
            out = colorMatrix(image, r: 1.08, g: 1.02, b: 0.88)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
        case .cool:
            out = colorMatrix(image, r: 0.9, g: 1.0, b: 1.1)
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.05])
        case .cinematic:
            out = colorMatrix(image, r: 1.06, g: 1.0, b: 0.94, bias: (0.0, 0.015, 0.035))
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15, kCIInputSaturationKey: 0.88])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.6, kCIInputRadiusKey: 1.6])
        case .mono:
            out = image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            out = image.applyingFilter("CIPhotoEffectNoir")
        case .fade:
            out = image.applyingFilter("CIPhotoEffectFade")
        case .chrome:
            out = image.applyingFilter("CIPhotoEffectChrome")
        case .instant:
            out = image.applyingFilter("CIPhotoEffectInstant")
        case .retro:
            out = image.applyingFilter("CIPhotoEffectTransfer")
        case .sepia:
            out = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        case .dramatic:
            out = image
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.35, kCIInputSaturationKey: 1.15])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 0.5])
        case .pastel:
            out = image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75, kCIInputBrightnessKey: 0.05, kCIInputContrastKey: 0.9])
        }
        out = out.cropped(to: extent)
        if intensity >= 0.999 { return out }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: out,
            kCIInputTimeKey: intensity
        ]).cropped(to: extent)
    }

    // MARK: Adjustments

    static func apply(_ adj: Adjustments, to image: CIImage) -> CIImage {
        guard !adj.isIdentity else { return image }
        let extent = image.extent
        var out = image
        if adj.brightness != 0 || adj.contrast != 1 || adj.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adj.brightness,
                kCIInputContrastKey: adj.contrast,
                kCIInputSaturationKey: adj.saturation
            ])
        }
        if adj.exposure != 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adj.exposure])
        }
        if abs(adj.temperature - 6500) > 1 {
            // Warmer below 6500 K target, cooler above, expressed as a channel gain.
            let t = (6500 - adj.temperature) / 3500 // -1 ... 1
            out = colorMatrix(out, r: 1 + 0.12 * t, g: 1 + 0.02 * t, b: 1 - 0.14 * t)
        }
        if adj.sharpness > 0 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adj.sharpness * 1.5])
        }
        if adj.vignette > 0 {
            out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: adj.vignette, kCIInputRadiusKey: 1.5])
        }
        return out.cropped(to: extent)
    }

    // MARK: AI ultra HD (on-device enhancement)

    static func ultraHD(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, kCIInputSharpnessKey: 0.4])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.45])
            .cropped(to: extent)
    }

    // MARK: Smart HDR look

    /// Local tone mapping that lifts shadows and protects highlights before HDR encoding.
    static func smartHDR(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image
            .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.85, "inputShadowAmount": 0.35])
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25])
            .cropped(to: extent)
    }

    // MARK: Auto enhance

    /// Serialisable form of `CIImage.autoAdjustmentFilters` so it can be cached per clip
    /// and re-applied on any thread.
    struct AutoAdjustment: @unchecked Sendable {
        var steps: [(name: String, parameters: [String: Any])]
    }

    static func autoAdjustment(for image: CIImage) -> AutoAdjustment {
        let filters = image.autoAdjustmentFilters(options: [.redEye: false])
        var steps: [(String, [String: Any])] = []
        for f in filters {
            var params: [String: Any] = [:]
            for key in f.inputKeys where key != kCIInputImageKey {
                if let v = f.value(forKey: key) { params[key] = v }
            }
            steps.append((f.name, params))
        }
        return AutoAdjustment(steps: steps)
    }

    static func apply(_ auto: AutoAdjustment, to image: CIImage) -> CIImage {
        let extent = image.extent
        var out = image
        for step in auto.steps {
            out = out.applyingFilter(step.name, parameters: step.parameters)
        }
        // Gentle extra pop on top of Apple's auto adjustments.
        out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15])
        return out.cropped(to: extent)
    }

    // MARK: Effects

    /// - Parameters:
    ///   - progress: 0...1 position inside the clip.
    ///   - localTime: seconds since the clip started.
    static func apply(_ effect: VisualEffect, to image: CIImage, progress: Double, localTime: Double) -> CIImage {
        let extent = image.extent
        switch effect {
        case .none, .kenBurns, .shake:
            // Geometric effects are handled by `geometry(for:)` during placement.
            return image
        case .rgbSplit:
            let amount = 4 + 6 * abs(sin(localTime * 6))
            return rgbSplit(image, offset: amount).cropped(to: extent)
        case .vignette:
            return image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.2, kCIInputRadiusKey: 1.4]).cropped(to: extent)
        case .bloom:
            return image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 12, kCIInputIntensityKey: 0.7]).cropped(to: extent)
        case .pixelate:
            let scale = max(8, min(extent.width, extent.height) / 60)
            return image.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: scale,
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)
            ]).cropped(to: extent)
        case .comic:
            return image.applyingFilter("CIComicEffect").cropped(to: extent)
        case .blurPulse:
            let radius = 10 * pow(sin(localTime * .pi * 1.5), 2)
            guard radius > 0.3 else { return image }
            return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        case .filmGrain:
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .clear)
            let shift = CGAffineTransform(translationX: CGFloat(Int(localTime * 997) % 300), y: CGFloat(Int(localTime * 613) % 300))
            let grain = noise.transformed(by: shift)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0.09)
                ])
                .cropped(to: extent)
            return grain.composited(over: image.applyingFilter("CIPhotoEffectFade")).cropped(to: extent)
        case .mirror:
            let half = CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height)
            let left = image.cropped(to: half)
            let flipped = left
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: extent.minX * 2 + extent.width, y: 0))
            return flipped.composited(over: left).cropped(to: extent)
        case .flash:
            let beat = localTime.truncatingRemainder(dividingBy: 0.5)
            let boost = 1.2 * exp(-beat * 10)
            guard boost > 0.02 else { return image }
            return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: boost]).cropped(to: extent)
        }
    }

    /// Scale multiplier and offset (in points of the canvas) for geometric effects.
    static func geometry(for effect: VisualEffect, progress: Double, localTime: Double, canvas: CGSize) -> (scale: CGFloat, dx: CGFloat, dy: CGFloat) {
        switch effect {
        case .kenBurns:
            return (CGFloat(1 + 0.12 * progress), 0, 0)
        case .shake:
            let a = min(canvas.width, canvas.height) * 0.012
            return (1.05, CGFloat(sin(localTime * 41)) * a, CGFloat(cos(localTime * 37)) * a)
        default:
            return (1, 0, 0)
        }
    }

    // MARK: Transitions

    /// Renders a transition between two canvas-sized images.
    static func transition(_ type: TransitionType, from a: CIImage, to b: CIImage, progress rawProgress: Double, canvas: CGRect) -> CIImage {
        let p = max(0, min(1, rawProgress))
        let eased = p * p * (3 - 2 * p)
        let w = canvas.width, h = canvas.height
        switch type {
        case .none:
            return (p < 0.5 ? a : b)
        case .dissolve:
            return dissolve(a, b, eased, canvas)
        case .fadeBlack, .fadeWhite:
            let solid = CIImage(color: type == .fadeBlack ? .black : .white).cropped(to: canvas)
            return p < 0.5 ? dissolve(a, solid, eased * 2, canvas) : dissolve(solid, b, (eased - 0.5) * 2, canvas)
        case .wipeLeft:
            let x = canvas.minX + w * (1 - eased)
            let revealed = b.cropped(to: CGRect(x: x, y: canvas.minY, width: w - (x - canvas.minX), height: h))
            return revealed.composited(over: a).cropped(to: canvas)
        case .wipeRight:
            let revealed = b.cropped(to: CGRect(x: canvas.minX, y: canvas.minY, width: w * eased, height: h))
            return revealed.composited(over: a).cropped(to: canvas)
        case .slideLeft:
            let outgoing = a.transformed(by: CGAffineTransform(translationX: -w * eased, y: 0))
            let incoming = b.transformed(by: CGAffineTransform(translationX: w * (1 - eased), y: 0))
            return incoming.composited(over: outgoing).cropped(to: canvas)
        case .slideUp:
            // Core Image's y axis points up, so "up" is a positive translation.
            let outgoing = a.transformed(by: CGAffineTransform(translationX: 0, y: h * eased))
            let incoming = b.transformed(by: CGAffineTransform(translationX: 0, y: -h * (1 - eased)))
            return incoming.composited(over: outgoing).cropped(to: canvas)
        case .zoomIn:
            let s = 1 + 0.6 * eased
            let zoomed = a.transformed(by: scaleAbout(center: CGPoint(x: canvas.midX, y: canvas.midY), scale: s)).cropped(to: canvas)
            let s2 = 1.3 - 0.3 * eased
            let incoming = b.transformed(by: scaleAbout(center: CGPoint(x: canvas.midX, y: canvas.midY), scale: s2)).cropped(to: canvas)
            return dissolve(zoomed, incoming, eased, canvas)
        case .blur:
            let radius = 30 * sin(.pi * p)
            let ba = a.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: canvas)
            let bb = b.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: canvas)
            return dissolve(ba, bb, eased, canvas)
        case .circle:
            let maxRadius = (w * w + h * h).squareRoot() / 2
            let r = maxRadius * eased
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                "inputRadius0": r,
                "inputRadius1": r + 2,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black
            ])?.outputImage?.cropped(to: canvas) ?? CIImage(color: .white).cropped(to: canvas)
            return b.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: a,
                kCIInputMaskImageKey: mask
            ]).cropped(to: canvas)
        case .glitch:
            let amount = 24 * sin(.pi * p)
            let mixed = dissolve(a, b, p < 0.5 ? 0 : 1, canvas)
            let band = CGFloat(Int(p * 37) % 7) / 7 * h
            let shifted = mixed.transformed(by: CGAffineTransform(translationX: amount * 2, y: 0))
                .cropped(to: CGRect(x: canvas.minX, y: canvas.minY + band, width: w, height: h * 0.12))
            return shifted.composited(over: rgbSplit(mixed, offset: amount)).cropped(to: canvas)
        }
    }

    // MARK: Helpers

    static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double, _ canvas: CGRect) -> CIImage {
        a.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: b,
            kCIInputTimeKey: max(0, min(1, t))
        ]).cropped(to: canvas)
    }

    static func colorMatrix(_ image: CIImage, r: Double, g: Double, b: Double, bias: (Double, Double, Double) = (0, 0, 0)) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(r), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(g), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(b), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: CGFloat(bias.0), y: CGFloat(bias.1), z: CGFloat(bias.2), w: 0)
        ])
    }

    static func rgbSplit(_ image: CIImage, offset: Double) -> CIImage {
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        let o = CGFloat(offset)
        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: o, y: 0))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: -o, y: 0))
        return red
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: image.extent)
    }

    static func scaleAbout(center: CGPoint, scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
    }

    /// Gradient used for the "Gradient" canvas and for background removal.
    static func gradientBackground(_ canvas: CGRect) -> CIImage {
        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: canvas.minX, y: canvas.maxY),
            "inputPoint1": CIVector(x: canvas.maxX, y: canvas.minY),
            "inputColor0": CIColor(red: 0.36, green: 0.16, blue: 0.95),
            "inputColor1": CIColor(red: 0.0, green: 0.78, blue: 0.86)
        ])
        return (filter?.outputImage ?? CIImage(color: .black)).cropped(to: canvas)
    }

    /// Applies an `UIImage`-style orientation derived from a track's preferred transform.
    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = transform.a, b = transform.b, c = transform.c, d = transform.d
        if a == 0 && b == 1 && c == -1 && d == 0 { return .right }
        if a == 0 && b == -1 && c == 1 && d == 0 { return .left }
        if a == -1 && b == 0 && c == 0 && d == -1 { return .down }
        if a == -1 && d == 1 { return .upMirrored }
        return .up
    }

    /// Renders a preview image for UI swatches.
    static func previewImage(_ preset: FilterPreset, from cgImage: CGImage, context: CIContext = RenderContext.shared) -> UIImage? {
        let ci = CIImage(cgImage: cgImage)
        let out = apply(preset, intensity: 1, to: ci)
        guard let cg = context.createCGImage(out, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - RenderContext

/// Shared Metal-backed Core Image context.
enum RenderContext {
    static let shared: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
}
