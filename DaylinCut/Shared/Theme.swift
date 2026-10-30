import SwiftUI

// MARK: - Theme

/// CapCut-like palette. Colours adapt to light/dark mode where it matters.
enum Theme {
    static let accent = Color(red: 0.0, green: 0.80, blue: 0.88)          // cyan "Export" button
    static let accentDark = Color(red: 0.0, green: 0.55, blue: 0.62)
    static let pro = Color(red: 0.70, green: 0.45, blue: 1.0)             // diamond purple
    static let proGradient = LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1.0), Color(red: 0.0, green: 0.78, blue: 0.9)],
                                            startPoint: .leading, endPoint: .trailing)
    static let heroGradient = LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.05, green: 0.30, blue: 0.38)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)

    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceRaised = Color(uiColor: .tertiarySystemBackground)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let timelineBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.93, alpha: 1) })
    static let textTrack = Color(red: 0.95, green: 0.62, blue: 0.15)
    static let audioTrack = Color(red: 0.22, green: 0.72, blue: 0.45)
    static let overlayTrack = Color(red: 0.55, green: 0.42, blue: 0.98)
    static let captionTrack = Color(red: 0.95, green: 0.35, blue: 0.55)

    static let cornerRadius: CGFloat = 12

    // CapCut-style dark chrome
    static let canvas = Color.black
    static let panel = Color(white: 0.11)
    static let chip = Color(white: 0.17)
    static let chipHighlight = Color(white: 0.22)
    static let hairline = Color.white.opacity(0.08)
    static let mutedText = Color.white.opacity(0.55)
}

// MARK: - Common styles

struct PillButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(filled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(filled ? Color.black : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ChipView: View {
    var title: String
    var symbol: String? = nil
    var isSelected: Bool
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title).lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.accent.opacity(0.18) : Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 1.5))
        .foregroundStyle(isSelected ? Theme.accent : Color.primary)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct ProBadge: View {
    var body: some View {
        Image(systemName: "diamond.fill")
            .font(.caption2)
            .foregroundStyle(Theme.pro)
            .accessibilityLabel("Pro feature")
    }
}

extension Double {
    /// "0:07" / "1:02:03"
    var timecode: String {
        guard isFinite else { return "0:00" }
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "4.2s"
    var shortSeconds: String { String(format: "%.1fs", self) }
}
