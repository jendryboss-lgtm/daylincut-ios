import SwiftUI
import UIKit

/// Export: the full settings page ("More export settings"), real rendering
/// with progress (AVAssetWriter for video, ImageIO for GIF), save to Photos,
/// and sharing (TikTok via the system share sheet).
struct ExportSheet: View {
    @Bindable var vm: EditorViewModel
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .configure
    @State private var progress: Double = 0
    @State private var service = ExportService()
    @State private var gifService = GIFExportService()
    @State private var task: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var started = false

    enum Phase: Equatable {
        case configure
        case exporting
        case done(URL, Int64, savedToPhotos: Bool, hdr: Bool, isGIF: Bool)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .configure: configure
                case .exporting: exporting
                case .done(let url, let bytes, let saved, let hdr, let gif): done(url: url, bytes: bytes, saved: saved, hdr: hdr, isGIF: gif)
                case .failed(let message): failed(message)
                }
            }
            .navigationTitle(phase == .configure ? "Export settings" : "Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .exporting ? "Cancel" : "Close") {
                        if phase == .exporting { cancel() } else { dismiss() }
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(phase == .exporting)
        .onAppear(perform: appear)
        .onDisappear { vm.autoStartExport = false }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url }), onDismiss: openPromoteIfNeeded) { item in
            ActivityView(items: [item.url])
        }
    }

    // MARK: Configure

    private var configure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("Format", selection: $vm.exportSettings.format) {
                    ForEach(ExportFormat.allCases) { Text($0 == .video ? "Video" : "GIF").tag($0) }
                }
                .pickerStyle(.segmented)

                ExportOptionsForm(settings: $vm.exportSettings, style: .full, duration: vm.duration,
                                  aspect: vm.timeline.aspectRatio, previewUltraHD: $vm.previewUltraHD)

                Button { start() } label: {
                    Text(vm.exportSettings.format == .gif ? "Export GIF" : "Export").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(20)
        }
        .background(Theme.panel.ignoresSafeArea())
    }

    // MARK: Exporting

    private var exporting: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.chip, lineWidth: 10)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%").font(.largeTitle.weight(.bold).monospacedDigit())
            }
            .frame(width: 160, height: 160)
            .accessibilityElement()
            .accessibilityLabel("Exporting")
            .accessibilityValue("\(Int(progress * 100)) percent")
            Text(exportingTitle).font(.headline)
            Text("Keep Daylin Cut open until the export finishes.").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.panel.ignoresSafeArea())
    }

    private var exportingTitle: String {
        let s = vm.exportSettings
        if s.format == .gif { return "Exporting GIF · \(s.gifShortSide)P · \(s.gifFrameRate) fps" }
        let res = s.resolution.requiresPro && !purchases.isPro ? ExportResolution.p1080 : s.resolution
        return "Exporting \(res.title) · \(s.frameRate) fps · \(Int(s.bitrateMbps)) Mbps"
    }

    private func done(url: URL, bytes: Int64, saved: Bool, hdr: Bool, isGIF: Bool) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.accent)
            Text(saved ? "Saved to Photos" : "Export complete").font(.title2.weight(.bold))
            Text("\(isGIF ? "GIF · " : "")\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\(hdr ? " · HDR" : "")")
                .foregroundStyle(.secondary)
            Button { shareTikTok(url) } label: { Label("Share to TikTok", systemImage: "music.note.tv").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle())
            Button { shareURL = url } label: { Label("More options", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(filled: false))
            Spacer()
        }
        .padding(24)
        .background(Theme.panel.ignoresSafeArea())
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(.orange)
            Text("Export failed").font(.title3.weight(.bold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Try again") { start() }.buttonStyle(PillButtonStyle())
            Button("Settings") { phase = .configure }.buttonStyle(PillButtonStyle(filled: false))
            Spacer()
        }
        .padding(24)
        .background(Theme.panel.ignoresSafeArea())
    }

    // MARK: Actions

    private func appear() {
        if !purchases.isPro {
            vm.exportSettings.addWatermark = true
            if vm.exportSettings.resolution.requiresPro { vm.exportSettings.resolution = .p1080; vm.exportSettings.resetBitrate() }
            vm.exportSettings.aiUltraHD = false
            vm.exportSettings.smartHDR = false
        }
        if vm.autoStartExport && !started { start() }
    }

    private func start() {
        started = true
        vm.pause()
        vm.showExportOptions = false
        phase = .exporting
        progress = 0
        let timeline = vm.timeline
        let settings = vm.exportSettings
        let isPro = purchases.isPro
        let service = ExportService()
        let gifService = GIFExportService()
        self.service = service
        self.gifService = gifService
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let report: @Sendable (Double) -> Void = { p in Task { @MainActor in progress = max(progress, p) } }
                if settings.format == .gif {
                    let result = try await gifService.export(timeline: timeline, settings: settings, isPro: isPro, progress: report)
                    var saved = false
                    if settings.saveToPhotos || settings.shareToTikTok {
                        try await MediaLibraryService.saveImageFileToPhotos(result.url)
                        saved = true
                    }
                    phase = .done(result.url, result.bytes, savedToPhotos: saved, hdr: false, isGIF: true)
                } else {
                    let result = try await service.export(timeline: timeline, settings: settings, isPro: isPro, progress: report)
                    var saved = false
                    if settings.saveToPhotos || settings.shareToTikTok {
                        try await MediaLibraryService.saveVideoToPhotos(result.url)
                        saved = true
                    }
                    phase = .done(result.url, result.bytes, savedToPhotos: saved, hdr: result.usedHDR, isGIF: false)
                    if settings.shareToTikTok { shareTikTok(result.url) }
                }
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
        gifService.cancel()
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
        let s = vm.exportSettings
        guard s.shareToTikTok, s.tikTokPromote else { return }
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
