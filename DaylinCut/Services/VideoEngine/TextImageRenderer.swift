import CoreImage
import UIKit

// MARK: - TextImageRenderer

/// Rasterises styled text into images for the compositor (text overlays, captions,
/// watermark) and computes per-frame animation state.
enum TextImageRenderer {

    struct Animated {
        var opacity: Double = 1
        var scale: Double = 1
        var offsetY: Double = 0   // fraction of canvas height, positive = up
        var visibleCharacters: Int? = nil
    }

    static func animationState(_ animation: TextAnimation, text: String, localTime: Double, duration: Double) -> Animated {
        let inDur = min(0.35, duration / 3)
        let outDur = min(0.25, duration / 4)
        let pIn = inDur > 0 ? min(1, max(0, localTime / inDur)) : 1
        let pOut = outDur > 0 ? min(1, max(0, (duration - localTime) / outDur)) : 1
        var s = Animated()
        switch animation {
        case .none:
            break
        case .fade:
            s.opacity = min(pIn, pOut)
        case .pop:
            // Overshoot spring-like curve.
            let x = pIn
            s.scale = x < 1 ? 0.5 + 0.5 * x + 0.18 * sin(x * .pi) : 1
            s.opacity = min(1, x * 2) * pOut
        case .slideUp:
            let eased = 1 - pow(1 - pIn, 3)
            s.offsetY = -0.06 * (1 - eased)
            s.opacity = min(eased, pOut)
        case .typewriter:
            let charsPerSecond = max(12.0, Double(text.count) / max(0.4, duration * 0.5))
            s.visibleCharacters = min(text.count, Int(localTime * charsPerSecond) + 1)
            s.opacity = pOut
        }
        return s
    }

    /// Renders `text` with `style`. `pointSize` is in output pixels.
    static func render(text: String,
                       fontName: String,
                       pointSize: CGFloat,
                       color: UIColor,
                       style: TextStyle,
                       maxWidth: CGFloat) -> CGImage? {
        guard !text.isEmpty, pointSize > 1, maxWidth > 10 else { return nil }
        let font = UIFont(name: fontName, size: pointSize) ?? .systemFont(ofSize: pointSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        switch style {
        case .plain, .background:
            break
        case .outline:
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -4.0
        case .neon:
            let shadow = NSShadow()
            shadow.shadowColor = color
            shadow.shadowBlurRadius = pointSize * 0.45
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        case .shadow:
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = pointSize * 0.12
            shadow.shadowOffset = CGSize(width: pointSize * 0.06, height: pointSize * 0.06)
            attributes[.shadow] = shadow
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let padding = pointSize * (style == .background ? 0.45 : 0.5)
        let bounds = string.boundingRect(with: CGSize(width: maxWidth - padding * 2, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let size = CGSize(width: ceil(bounds.width + padding * 2), height: ceil(bounds.height + padding * 2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            if style == .background {
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: padding * 0.25, dy: padding * 0.25)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: pointSize * 0.25)
                let isLight = color.isLight
                (isLight ? UIColor.black.withAlphaComponent(0.72) : UIColor.white.withAlphaComponent(0.9)).setFill()
                path.fill()
            }
            string.draw(with: CGRect(x: padding, y: padding, width: bounds.width, height: bounds.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            _ = ctx
        }
        return image.cgImage
    }

    /// "Daylin Cut" watermark shown on exports for non-Pro users.
    static func watermark(canvasWidth: CGFloat) -> CGImage? {
        render(text: "✂︎ Daylin Cut", fontName: "AvenirNext-DemiBold", pointSize: max(14, canvasWidth * 0.035),
               color: UIColor.white.withAlphaComponent(0.85), style: .shadow, maxWidth: canvasWidth)
    }
}

extension UIColor {
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}
