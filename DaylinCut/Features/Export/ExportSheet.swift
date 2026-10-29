import SwiftUI
import UIKit

/// Export settings, size estimate, real AVAssetWriter render with progress,
/// save to Photos, and sharing (TikTok via the system share sheet).
struct ExportSheet: View {
    @Bindable var vm: EditorViewModel
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.settings") private var stored: Data = Data()

    @State private var settings = ExportSettings()
    @State private var phase: Phase = .configure
    @State private var progress: Double = 0
    @State private var service = ExportService()
    @State private var task: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var loaded = false

    enum Phase: Equatable {
        case configure
        case exporting
        case done(URL, Int64, savedToPhotos: Bool, hdr: Bool)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .configure: configure
                case .exporting: exporting
                case .done(let url, let bytes, let saved, let hdr): done(url: url, bytes: bytes, saved: saved, hdr: hdr)
                case .failed(let message): failed(message)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .exporting ? "Cancel" : "Close") {
                        if phase == .exporting { cancel() } else { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase == .exporting)
        .onAppear(perform: load)
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url }), onDismiss: openPromoteIfNeeded) { item in
            ActivityView(items: [item.url])
        }
    }

    // MARK: Configure

    private var configure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                proToggle("AI ultra HD", subtitle: "Sharpen and upscale every frame", isOn: $settings.aiUltraHD, feature: .ultraHD)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Resolution").font(.headline)
                        Spacer()
                        Text(settings.resolution.title).font(.headline).foregroundStyle(Theme.accent)
                        if settings.resolution.requiresPro && !purchases.isPro { ProBadge() }
                    }
                    Slider(value: Binding(
                        get: { Double(ExportResolution.allCases.firstIndex(of: settings.resolution) ?? 2) },
                        set: { v in
                            let r = ExportResolution.allCases[Int(v.rounded())]
                            if r.requiresPro && !purchases.isPro {
                                _ = purchases.require(.export4K)
                                return
                            }
                            settings.resolution = r
                            settings.resetBitrate()
                        }), in: 0...Double(ExportResolution.allCases.count - 1), step: 1)
                    .tint(Theme.accent)
                    .accessibilityLabel("Resolution")
                    .accessibilityValue(settings.resolution.title)
                    HStack {
                        ForEach(ExportResolution.allCases) { Text($0.title).font(.caption2).frame(maxWidth: .infinity) }
                    }
                    .foregroundStyle(.secondary)
                    Text(settings.resolution.subtitle).font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Frame rate").font(.headline)
                        Spacer()
                        Text("\(settings.frameRate) fps").font(.headline).foregroundStyle(Theme.accent)
                    }
                    Slider(value: Binding(
                        get: { Double(ExportSettings.frameRates.firstIndex(of: settings.frameRate) ?? 2) },
                        set: { v in
                            settings.frameRate = ExportSettings.frameRates[Int(v.rounded())]
                            settings.resetBitrate()
                        }), in: 0...Double(ExportSettings.frameRates.count - 1), step: 1)
                    .tint(Theme.accent)
                    .accessibilityLabel("Frame rate")
                    .accessibilityValue("\(settings.frameRate) frames per second")
                    HStack {
                        ForEach(ExportSettings.frameRates, id: \.self) { Text("\($0)").font(.caption2).frame(maxWidth: .infinity) }
                    }
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bitrate").font(.headline)
                        Spacer()
                        Text(String(format: "%.1f Mbps", settings.bitrateMbps)).font(.headline.monospacedDigit()).foregroundStyle(Theme.accent)
                    }
                    Slider(value: $settings.bitrateMbps, in: 1...max(60, settings.recommendedBitrate * 2), step: 0.5).tint(Theme.accent)
                        .accessibilityLabel("Bitrate")
                    HStack {
                        Text("Recommended \(String(format: "%.1f", settings.recommendedBitrate)) Mbps").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { settings.resetBitrate() }.font(.caption)
                    }
                }

                proToggle("Smart HDR", subtitle: "10-bit HEVC with HLG for brighter highlights", isOn: $settings.smartHDR, feature: .smartHDR)

                if purchases.isPro {
                    Toggle("Add Daylin Cut watermark", isOn: $settings.addWatermark).tint(Theme.accent)
                } else {
                    Button { _ = purchases.require(.noWatermark) } label: {
                        HStack {
                            Text("Remove watermark")
                            Spacer()
                            ProBadge()
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Divider()
                Toggle(isOn: $settings.shareToTikTok) {
                    Label("Save and share to TikTok", systemImage: "music.note.tv")
                }
                .tint(Theme.accent)
                if settings.shareToTikTok {
                    Toggle(isOn: $settings.tikTokPromote) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TikTok Promote")
                            Text("Opens TikTok after posting so you can boost the video with Promote.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(Theme.accent)
                }
                Toggle("Save to Photos", isOn: $settings.saveToPhotos).tint(Theme.accent)

                HStack {
                    VStack(alignment: .leading) {
                        Text("Estimated file size").font(.subheadline).foregroundStyle(.secondary)
                        Text(settings.estimatedSizeText(duration: vm.duration)).font(.title3.weight(.bold).monospacedDigit())
                    }
                    Spacer()
                    let size = settings.renderSize(for: vm.timeline.aspectRatio)
                    VStack(alignment: .trailing) {
                        Text("\(size.width)×\(size.height)").font(.subheadline.monospacedDigit())
                        Text(vm.duration.timecode).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)

                Button { start() } label: {
                    Text("Export").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(20)
        }
    }

    private func proToggle(_ title: String, subtitle: String, isOn: Binding<Bool>, feature: PurchaseManager.Feature) -> some View {
        Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { v in
            if v && !purchases.require(feature) { return }
            isOn.wrappedValue = v
        })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if !purchases.isPro { ProBadge() }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(Theme.accent)
    }

    // MARK: Exporting

    private var exporting: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.surfaceRaised, lineWidth: 10)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%").font(.largeTitle.weight(.bold).monospacedDigit())
            }
            .frame(width: 160, height: 160)
            .accessibilityElement()
            .accessibilityLabel("Exporting")
            .accessibilityValue("\(Int(progress * 100)) percent")
            Text("Exporting \(settings.resolution.title) · \(settings.frameRate) fps").font(.headline)
            Text("Keep Daylin Cut open until the export finishes.").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func done(url: URL, bytes: Int64, saved: Bool, hdr: Bool) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.accent)
            Text(saved ? "Saved to Photos" : "Export complete").font(.title2.weight(.bold))
            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\(hdr ? " · HDR" : "")")
                .foregroundStyle(.secondary)
            Button { shareTikTok(url) } label: { Label("Share to TikTok", systemImage: "music.note.tv").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle())
            Button { shareURL = url } label: { Label("More options", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(filled: false))
            Spacer()
        }
        .padding(24)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(.orange)
            Text("Export failed").font(.title3.weight(.bold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Try again") { phase = .configure }.buttonStyle(PillButtonStyle())
            Spacer()
        }
        .padding(24)
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = try? JSONDecoder().decode(ExportSettings.self, from: stored) { settings = s } else if purchases.isPro { settings.addWatermark = false }
        settings.resolution = vm.previewResolution.requiresPro && !purchases.isPro ? .p1080 : vm.previewResolution
        if !purchases.isPro {
            settings.addWatermark = true
            settings.aiUltraHD = false
            settings.smartHDR = false
        }
        settings.resetBitrate()
    }

    private func start() {
        if let data = try? JSONEncoder().encode(settings) { stored = data }
        vm.pause()
        phase = .exporting
        progress = 0
        let service = ExportService()
        self.service = service
        let timeline = vm.timeline
        let settings = settings
        let isPro = purchases.isPro
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let result = try await service.export(timeline: timeline, settings: settings, isPro: isPro) { p in
                    Task { @MainActor in progress = max(progress, p) }
                }
                var saved = false
                if settings.saveToPhotos || settings.shareToTikTok {
                    try await MediaLibraryService.saveVideoToPhotos(result.url)
                    saved = true
                }
                phase = .done(result.url, result.bytes, savedToPhotos: saved, hdr: result.usedHDR)
                if settings.shareToTikTok { shareTikTok(result.url) }
            } catch is CancellationError {
                phase = .configure
            } catch VideoEngineError.cancelled {
                phase = .configure
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        service.cancel()
        task?.cancel()
        phase = .configure
    }

    /// TikTok has no public upload API without its SDK, so the saved video is
    /// handed to the share sheet (TikTok appears there when installed).
    private func shareTikTok(_ url: URL) {
        shareURL = url
    }

    /// After sharing, TikTok Promote opens the TikTok app (or its website)
    /// so the user can boost the post they just made.
    private func openPromoteIfNeeded() {
        guard settings.shareToTikTok, settings.tikTokPromote else { return }
        guard let app = URL(string: "tiktok://"), let web = URL(string: "https://www.tiktok.com/") else { return }
        UIApplication.shared.open(app) { opened in
            if !opened { UIApplication.shared.open(web) }
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
