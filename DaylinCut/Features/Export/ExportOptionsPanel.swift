import SwiftUI

// MARK: - StopSlider

/// The thin teal slider with labelled stops used in the export panel.
struct StopSlider: View {
    let labels: [String]
    @Binding var index: Int
    var accessibilityTitle: String
    /// Return false to refuse a stop (e.g. Pro-gated 4K); the knob snaps back.
    var canSelect: (Int) -> Bool = { _ in true }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let inset: CGFloat = 8
                let width = max(1, geo.size.width - inset * 2)
                let step = labels.count > 1 ? width / CGFloat(labels.count - 1) : 0
                let x = inset + CGFloat(index) * step
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 2).padding(.horizontal, inset)
                    Capsule().fill(Theme.accent).frame(width: max(0, x - inset), height: 2).offset(x: inset)
                    ForEach(labels.indices, id: \.self) { i in
                        Circle().fill(i <= index ? Theme.accent : Color.white.opacity(0.35))
                            .frame(width: 3, height: 3)
                            .position(x: inset + CGFloat(i) * step, y: geo.size.height / 2)
                    }
                    Circle().fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .position(x: x, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard step > 0 else { return }
                    let i = Int(((g.location.x - inset) / step).rounded())
                    let clamped = min(labels.count - 1, max(0, i))
                    if clamped != index, canSelect(clamped) { index = clamped }
                })
            }
            .frame(height: 22)
            HStack(spacing: 0) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i])
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedText)
                        .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : (i == labels.count - 1 ? .trailing : .center))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(labels.indices.contains(index) ? labels[index] : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index < labels.count - 1, canSelect(index + 1) { index += 1 }
            case .decrement: if index > 0, canSelect(index - 1) { index -= 1 }
            @unknown default: break
            }
        }
    }
}

// MARK: - ExportOptionsForm

/// Export choices in the CapCut layout. `.compact` is the "1080P" dropdown
/// (480–1080, TikTok rows), `.expanded` is the "AI UHD" dropdown (all
/// resolutions, frame rate, bitrate stops) and `.full` is the export sheet.
struct ExportOptionsForm: View {
    enum Style { case compact, expanded, full }

    @Binding var settings: ExportSettings
    let style: Style
    let duration: Double
    let aspect: AspectRatio
    @Binding var previewUltraHD: Bool
    var onMore: (() -> Void)?

    @Environment(PurchaseManager.self) private var purchases
    @State private var showResolutionHelp = false
    @State private var showPromoteHelp = false

    private var resolutions: [ExportResolution] {
        style == .compact ? [.p480, .p720, .p1080] : ExportResolution.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 18 : 26) {
            if settings.format == .gif && style != .compact {
                gifControls
            } else {
                ultraHDRow
                resolutionRow
                if style != .compact {
                    frameRateRow
                    bitrateRow
                }
                toggleRow("Smart HDR", subtitle: "Converts your clip to an HDR video", isOn: proBinding(\.smartHDR, .smartHDR))
                if style != .expanded {
                    toggleRow("Save and share to TikTok", subtitle: "Without Daylin Cut watermark", isOn: $settings.shareToTikTok)
                    toggleRow("TikTok Promote", subtitle: "Boost your video on TikTok", isOn: $settings.tikTokPromote, help: $showPromoteHelp)
                }
                if style == .full { fullExtras }
            }
            estimatedSize
            if style == .expanded, let onMore { moreBanner(onMore) }
        }
        .alert("Resolution", isPresented: $showResolutionHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Higher resolutions look sharper on big screens but make larger files. 4K needs Daylin Cut Pro.")
        }
        .alert("TikTok Promote", isPresented: $showPromoteHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("After sharing, Daylin Cut opens TikTok so you can boost the post with Promote.")
        }
    }

    // MARK: Rows

    private var ultraHDRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("AI ultra HD").font(.system(size: 16, weight: .medium))
                    Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(Theme.pro)
                }
                if style == .compact {
                    (Text("Make your video clearer and smoother with AI enhancement and frame interpolation. ").foregroundColor(Theme.accent)
                     + Text("|  ").foregroundColor(Theme.mutedText))
                        .font(.system(size: 13))
                    previewButton
                } else {
                    HStack(alignment: .bottom) {
                        Text("Make your video clearer and smoother with AI enhancement and frame interpolation.")
                            .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        Spacer(minLength: 12)
                        Text("|").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        previewButton
                    }
                }
            }
            Spacer(minLength: 16)
            Toggle("AI ultra HD", isOn: proBinding(\.aiUltraHD, .ultraHD)).labelsHidden().tint(Theme.accent)
        }
    }

    private var previewButton: some View {
        Button {
            if !previewUltraHD && !purchases.isPro && !purchases.require(.ultraHD) { return }
            previewUltraHD.toggle()
        } label: {
            Label(previewUltraHD ? "Previewing" : "Preview", systemImage: "play.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(previewUltraHD ? Theme.accent : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(previewUltraHD ? "Stop AI ultra HD preview" : "Preview AI ultra HD")
    }

    private var resolutionRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if style == .compact {
                VStack(alignment: .leading, spacing: 6) {
                    header("Resolution", help: $showResolutionHelp)
                    Text(settings.resolution.subtitle).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                }
            } else {
                HStack {
                    header("Resolution", help: $showResolutionHelp)
                    Spacer()
                    Text(settings.resolution.subtitle).font(.system(size: 12)).foregroundStyle(Theme.mutedText).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            StopSlider(labels: resolutions.map(\.title), index: Binding(
                get: { resolutions.firstIndex(of: settings.resolution) ?? resolutions.count - 1 },
                set: { i in
                    settings.resolution = resolutions[i]
                    settings.resetBitrate()
                }), accessibilityTitle: "Resolution",
                canSelect: { i in
                    let r = resolutions[i]
                    return !r.requiresPro || purchases.isPro || purchases.require(.export4K)
                })
        }
    }

    private var frameRateRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Frame rate").font(.system(size: 16, weight: .medium))
                Spacer()
                Text("Smoother playback").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            }
            StopSlider(labels: ExportSettings.frameRates.map(String.init), index: Binding(
                get: { ExportSettings.frameRates.firstIndex(of: settings.frameRate) ?? 2 },
                set: { i in
                    settings.frameRate = ExportSettings.frameRates[i]
                    settings.bitrateMbps = settings.recommendedBitrateOption
                }), accessibilityTitle: "Frame rate")
        }
    }

    private var bitrateRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bitrate (Mbps)").font(.system(size: 16, weight: .medium))
                Spacer()
                Button("Recommended for this video (\(Int(settings.recommendedBitrateOption)))") {
                    settings.bitrateMbps = settings.recommendedBitrateOption
                }
                .font(.system(size: 12)).foregroundStyle(Theme.mutedText).buttonStyle(.plain)
            }
            StopSlider(labels: ExportSettings.bitrateOptions.map { String(Int($0)) }, index: Binding(
                get: { settings.bitrateOptionIndex },
                set: { settings.bitrateMbps = ExportSettings.bitrateOptions[$0] }), accessibilityTitle: "Bitrate")
        }
    }

    private var gifControls: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Resolution").font(.system(size: 16, weight: .medium))
                    Spacer()
                    let size = settings.gifRenderSize(for: aspect)
                    Text("\(size.width)×\(size.height)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.mutedText)
                }
                StopSlider(labels: ExportSettings.gifSizes.map { "\($0)P" }, index: Binding(
                    get: { ExportSettings.gifSizes.firstIndex(of: settings.gifShortSide) ?? 1 },
                    set: { settings.gifShortSide = ExportSettings.gifSizes[$0] }), accessibilityTitle: "GIF resolution")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Frame rate").font(.system(size: 16, weight: .medium))
                    Spacer()
                    Text("Loops forever").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
                StopSlider(labels: ExportSettings.gifFrameRates.map(String.init), index: Binding(
                    get: { ExportSettings.gifFrameRates.firstIndex(of: settings.gifFrameRate) ?? 1 },
                    set: { settings.gifFrameRate = ExportSettings.gifFrameRates[$0] }), accessibilityTitle: "GIF frame rate")
            }
            toggleRow("Save to Photos", subtitle: "Animated GIF in your library", isOn: $settings.saveToPhotos)
        }
    }

    @ViewBuilder private var fullExtras: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codec").font(.system(size: 16, weight: .medium))
            Picker("Codec", selection: $settings.codec) {
                ForEach(ExportCodec.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settings.smartHDR ? "Smart HDR always uses 10-bit HEVC" : settings.codec.subtitle)
                .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
        }
        toggleRow("Save to Photos", subtitle: "Keep a copy in your library", isOn: $settings.saveToPhotos)
        if purchases.isPro {
            toggleRow("Daylin Cut watermark", subtitle: "Show the logo in the corner", isOn: $settings.addWatermark)
        } else {
            Button { _ = purchases.require(.noWatermark) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remove watermark").font(.system(size: 16, weight: .medium))
                        Text("Included with Pro").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    }
                    Spacer()
                    ProBadge()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var estimatedSize: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Estimated file size: \(settings.estimatedSizeText(duration: duration, aspect: aspect))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.mutedText)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        }
        .accessibilityElement(children: .combine)
    }

    private func moreBanner(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("More export settings").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color(white: 0.15), Color(red: 0.35, green: 0.2, blue: 0.6)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 112, height: 72)
                        .overlay(alignment: .topLeading) { bannerTag("Codec", symbol: "cpu").offset(x: -10, y: 18) }
                    bannerTag("Bit Rate", symbol: "waveform.path.ecg").offset(x: 4, y: 4)
                }
            }
            .padding(.leading, 18).padding(.vertical, 12).padding(.trailing, 10)
            .background(
                LinearGradient(colors: [Color(white: 0.06), Color(red: 0.22, green: 0.10, blue: 0.40)], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private func bannerTag(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.pro, lineWidth: 1))
            .foregroundStyle(.white)
    }

    // MARK: Helpers

    private func header(_ title: String, help: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 16, weight: .medium))
            Button { help.wrappedValue = true } label: {
                Image(systemName: "questionmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title)")
        }
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>, help: Binding<Bool>? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                if let help { header(title, help: help) } else { Text(title).font(.system(size: 16, weight: .medium)) }
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            }
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().tint(Theme.accent)
        }
    }

    private func proBinding(_ key: WritableKeyPath<ExportSettings, Bool>, _ feature: PurchaseManager.Feature) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { v in
            if v && !purchases.isPro && !purchases.require(feature) { return }
            settings[keyPath: key] = v
        })
    }
}

// MARK: - ExportOptionsPanel

/// The dropdown that slides down from the editor/review top bar: format tabs,
/// the resolution button that opened it (now pointing up) and Export.
struct ExportOptionsPanel: View {
    @Binding var settings: ExportSettings
    let expanded: Bool
    let buttonTitle: String
    let duration: Double
    let aspect: AspectRatio
    @Binding var previewUltraHD: Bool
    var onClose: () -> Void
    var onExport: () -> Void
    var onMore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(expanded ? ExportFormat.allCases : [.video]) { f in
                    Button { settings.format = f } label: {
                        VStack(spacing: 6) {
                            Text(f.title)
                                .font(.system(size: 16, weight: settings.format == f || !expanded ? .semibold : .regular))
                                .foregroundStyle(settings.format == f || !expanded ? .white : Theme.mutedText)
                            Capsule().fill(settings.format == f || !expanded ? Theme.accent : .clear).frame(width: 40, height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Text(buttonTitle).font(.system(size: 15, weight: .semibold))
                        Image(systemName: "triangle.fill").font(.system(size: 6))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Close export options")
                Button(action: onExport) {
                    Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 14)

            ScrollView {
                ExportOptionsForm(settings: $settings, style: expanded ? .expanded : .compact,
                                  duration: duration, aspect: aspect, previewUltraHD: $previewUltraHD,
                                  onMore: onMore)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: expanded ? 660 : 470)
        }
        .foregroundStyle(.white)
        .background(Theme.panel.ignoresSafeArea(edges: .top))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        .environment(\.colorScheme, .dark)
    }
}
