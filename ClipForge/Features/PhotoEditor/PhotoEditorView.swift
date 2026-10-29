import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Photo editing: AI operations (enhance, retouch, cut-out, styles),
/// light adjustments, cover-maker title, save/share, or turn into a video.
struct PhotoEditorView: View {
    let image: UIImage
    let initialOperation: PhotoOperation?
    let isCoverMaker: Bool

    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.modelContext) private var context

    @State private var history: [UIImage] = []
    @State private var base: UIImage?
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var warmth: Double = 0
    @State private var display: UIImage?
    @State private var showOriginal = false
    @State private var working: PhotoOperation?
    @State private var tab: Tab = .ai
    @State private var coverTitle = ""
    @State private var coverStyle: TextStyle = .outline
    @State private var toast: String?
    @State private var shareImage: UIImage?
    @State private var didStart = false

    enum Tab: String, CaseIterable, Identifiable {
        case ai = "AI", adjust = "Adjust", cover = "Cover"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
        .onChange(of: brightness) { _, _ in renderAdjustments() }
        .onChange(of: contrast) { _, _ in renderAdjustments() }
        .onChange(of: saturation) { _, _ in renderAdjustments() }
        .onChange(of: warmth) { _, _ in renderAdjustments() }
        .sheet(item: Binding(get: { shareImage.map(ShareImage.init) }, set: { shareImage = $0?.image })) { item in
            ActivityView(items: [item.image])
        }
    }

    // MARK: Layout

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { router.dismissFlow() } label: { Image(systemName: "xmark").font(.headline) }
                .accessibilityLabel("Close")
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(history.isEmpty)
                .accessibilityLabel("Undo")
            Spacer()
            Menu {
                Button { Task { await save() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                Button { shareImage = finalImage() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { makeVideo() } label: { Label("Edit as video", systemImage: "film") }
            } label: {
                Text("Export").font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
    }

    private var preview: some View {
        ZStack {
            Image(uiImage: showOriginal ? image : (display ?? image))
                .resizable()
                .scaledToFit()
                .overlay {
                    if tab == .cover && !coverTitle.isEmpty && !showOriginal {
                        GeometryReader { geo in
                            CoverTitle(text: coverTitle, style: coverStyle, width: geo.size.width)
                                .position(x: geo.size.width / 2, y: geo.size.height * 0.78)
                        }
                    }
                }
                .accessibilityLabel(showOriginal ? "Original photo" : "Edited photo")
            if let working {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("\(working.title)…").font(.subheadline).foregroundStyle(.white)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "square.split.2x1")
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
                .padding(12)
                .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { showOriginal = $0 })
                .accessibilityLabel("Hold to compare with original")
                .accessibilityAction { showOriginal.toggle() }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Tool", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            switch tab {
            case .ai:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(PhotoOperation.allCases) { op in
                            Button { apply(op) } label: {
                                VStack(spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        Image(systemName: op.symbol)
                                            .font(.title3)
                                            .frame(width: 54, height: 54)
                                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                        if op.requiresPro && !purchases.isPro {
                                            Image(systemName: "diamond.fill").font(.caption2).foregroundStyle(Theme.pro).offset(x: 4, y: -4)
                                        }
                                    }
                                    Text(op.title).font(.caption)
                                }
                                .foregroundStyle(.white)
                            }
                            .disabled(working != nil)
                            .accessibilityLabel(op.title + (op.requiresPro && !purchases.isPro ? ", Pro" : ""))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            case .adjust:
                VStack(spacing: 8) {
                    LabeledSlider(title: "Brightness", value: $brightness, range: -0.5...0.5, format: { "\(Int($0 * 200))" })
                    LabeledSlider(title: "Contrast", value: $contrast, range: 0.5...1.5, format: { "\(Int(($0 - 1) * 200))" })
                    LabeledSlider(title: "Saturation", value: $saturation, range: 0...2, format: { "\(Int(($0 - 1) * 100))" })
                    LabeledSlider(title: "Warmth", value: $warmth, range: -1...1, format: { "\(Int($0 * 100))" })
                }
                .padding(.horizontal, 16)
                .foregroundStyle(.white)
            case .cover:
                VStack(spacing: 10) {
                    TextField("Cover title", text: $coverTitle)
                        .padding(10)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(TextStyle.allCases) { s in
                                Button { coverStyle = s } label: { ChipView(title: s.title, isSelected: coverStyle == s) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 190, alignment: .top)
        .background(Color(white: 0.08))
    }

    // MARK: Actions

    private func start() {
        guard !didStart else { return }
        didStart = true
        // Work on a screen-sized copy so sliders stay interactive with 48 MP photos.
        let working = Self.downscaled(image, maxSide: 2400)
        base = working
        display = working
        if isCoverMaker { tab = .cover; coverTitle = "My video" }
        if let initialOperation { apply(initialOperation) }
    }

    private func apply(_ op: PhotoOperation) {
        if op.requiresPro && !purchases.require(.advancedAI) { return }
        guard let current = base else { return }
        working = op
        let input = adjusted(current) ?? current
        Task {
            do {
                let result = try await AIServiceProvider.current.editPhoto(input, operation: op)
                history.append(current)
                base = result
                brightness = 0; contrast = 1; saturation = 1; warmth = 0
                display = result
            } catch {
                show(error.localizedDescription)
            }
            working = nil
        }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        base = previous
        brightness = 0; contrast = 1; saturation = 1; warmth = 0
        display = previous
    }

    private var hasAdjustments: Bool { brightness != 0 || contrast != 1 || saturation != 1 || warmth != 0 }

    private func renderAdjustments() {
        guard let base else { return }
        display = adjusted(base) ?? base
    }

    private func adjusted(_ source: UIImage) -> UIImage? {
        guard hasAdjustments, let ci = CIImage(image: source) else { return nil }
        let color = CIFilter.colorControls()
        color.inputImage = ci
        color.brightness = Float(brightness)
        color.contrast = Float(contrast)
        color.saturation = Float(saturation)
        var output = color.outputImage ?? ci
        if warmth != 0 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6500 + warmth * 2500, y: 0)
            output = temp.outputImage ?? output
        }
        guard let cg = RenderContext.shared.createCGImage(output, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: source.scale, orientation: .up)
    }

    /// The edited photo with the cover title burned in.
    private func finalImage() -> UIImage {
        let edited = display ?? image
        guard tab == .cover || isCoverMaker, !coverTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return edited }
        let renderer = ImageRenderer(content:
            Image(uiImage: edited).resizable().frame(width: edited.size.width, height: edited.size.height)
                .overlay {
                    CoverTitle(text: coverTitle, style: coverStyle, width: edited.size.width)
                        .position(x: edited.size.width / 2, y: edited.size.height * 0.78)
                }
        )
        renderer.scale = edited.scale
        return renderer.uiImage ?? edited
    }

    private func save() async {
        do {
            try await MediaLibraryService.saveImageToPhotos(finalImage())
            show("Saved to Photos")
        } catch {
            show(error.localizedDescription)
        }
    }

    private func makeVideo() {
        let photo = finalImage()
        Task {
            do {
                let still = try await FrameVideoWriter.stillVideo(from: photo)
                var clip = try await MediaProbe.clip(fileName: still.fileName, kind: .photo)
                clip.sourceEnd = min(clip.sourceDuration, 3)
                var timeline = Timeline(clips: [clip])
                if photo.size.width > photo.size.height { timeline.aspectRatio = .landscape16x9 }
                let project = ProjectStore.create(timeline, in: context)
                await ProjectStore.updateThumbnail(project, context: context)
                router.open(project)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if toast == message { toast = nil } }
        }
    }
}

/// Title rendering shared by the preview overlay and the exported image.
private struct CoverTitle: View {
    let text: String
    let style: TextStyle
    let width: CGFloat

    var body: some View {
        let size = max(18, width * 0.09)
        let label = Text(text).font(.system(size: size, weight: .heavy)).multilineTextAlignment(.center)
        Group {
            switch style {
            case .plain:
                label.foregroundStyle(.white)
            case .outline:
                ZStack {
                    ForEach(0..<8, id: \.self) { i in
                        let a = Double(i) / 8 * 2 * .pi
                        label.foregroundStyle(.black).offset(x: cos(a) * size * 0.06, y: sin(a) * size * 0.06)
                    }
                    label.foregroundStyle(.white)
                }
            case .background:
                label.foregroundStyle(.black)
                    .padding(.horizontal, size * 0.4).padding(.vertical, size * 0.15)
                    .background(.white, in: RoundedRectangle(cornerRadius: size * 0.2))
            case .neon:
                label.foregroundStyle(.white)
                    .shadow(color: Color(hex: "#00E5FF"), radius: size * 0.2)
                    .shadow(color: Color(hex: "#00E5FF"), radius: size * 0.4)
            case .shadow:
                label.foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: size * 0.1, x: 0, y: size * 0.08)
            }
        }
        .frame(maxWidth: width * 0.9)
        .accessibilityHidden(true)
    }
}

private struct ShareImage: Identifiable {
    let image: UIImage
    let id = UUID()
}
