import Photos
import SwiftData
import SwiftUI

struct EditorView: View {
    let project: Project
    var launchAction: EditorLaunchAction = .none

    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases
    @Environment(MediaLibraryService.self) private var library
    @State private var vm: EditorViewModel
    @State private var didLaunch = false
    @State private var importingMedia = false
    @State private var importProgress: Double = 0
    /// Draws the TikTok/Reels safe zone over the preview.
    @AppStorage("editor.safeZone") private var showSafeZone = false

    init(project: Project, launchAction: EditorLaunchAction = .none) {
        self.project = project
        self.launchAction = launchAction
        _vm = State(initialValue: EditorViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            playbackBar
            EditorTimeline(vm: vm)
                .frame(height: timelineHeight)
                .overlay(alignment: .bottomLeading) { aiLabButton }
            EditorToolbar(vm: vm)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .overlay(alignment: .top) { exportOptionsOverlay }
        .animation(.easeOut(duration: 0.2), value: vm.showExportOptions)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $vm.showSearch) {
            EditorToolSearch(vm: vm)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $vm.showFullscreen) {
            FullscreenPreview(vm: vm)
        }
        .sheet(item: $vm.panel) { panel in
            EditorPanelHost(panel: panel, vm: vm)
                .presentationDetents(panel.detents)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(340)))
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $vm.showExport) {
            ExportSheet(vm: vm)
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $vm.showAddMedia) {
            MediaPickerView(mode: .videosAndPhotos, confirmTitle: "Add", onCancel: { vm.showAddMedia = false }) { assets in
                vm.showAddMedia = false
                importMedia(assets, asOverlay: false)
            }
        }
        .fullScreenCover(isPresented: $vm.showOverlayPicker) {
            MediaPickerView(mode: .single, confirmTitle: "Add", onCancel: { vm.showOverlayPicker = false }) { assets in
                vm.showOverlayPicker = false
                importMedia(assets, asOverlay: true)
            }
        }
        .onAppear(perform: handleLaunch)
        .onDisappear {
            vm.tearDown()
            Task { await vm.refreshThumbnail() }
        }
    }

    private var timelineHeight: CGFloat {
        var h: CGFloat = 20 + 54 + 28 + 28 + 6 * 4 + 40
        if !vm.timeline.overlays.isEmpty { h += 34 }
        if !vm.timeline.captions.isEmpty { h += 28 }
        return h
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                vm.saveNow()
                router.dismissFlow()
            } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .regular))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Close")

            Button { vm.pause(); vm.showSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .regular))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Search tools")

            Spacer(minLength: 4)

            if !purchases.isPro {
                Button { _ = purchases.require(.noWatermark) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "diamond.fill").foregroundStyle(Color(red: 0.72, green: 0.55, blue: 1))
                        Text("Pro \(purchases.startPriceText)").lineLimit(1)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Start Pro")
            }

            Button {
                vm.pause()
                vm.exportOptionsExpanded = true
                vm.showExportOptions.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(resolutionChipTitle)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8))
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 10).frame(height: 34)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Export settings, \(resolutionChipTitle)")

            Button {
                vm.pause()
                vm.showExportOptions = false
                vm.autoStartExport = true
                vm.showExport = true
            } label: {
                Text("Export")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(vm.timeline.clips.isEmpty)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var resolutionChipTitle: String {
        vm.exportSettings.aiUltraHD ? "AI UHD" : vm.exportSettings.resolution.title
    }

    /// CapCut's drop-down export panel under the top bar.
    @ViewBuilder
    private var exportOptionsOverlay: some View {
        if vm.showExportOptions {
            ZStack(alignment: .top) {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { vm.showExportOptions = false }
                ExportOptionsPanel(settings: $vm.exportSettings,
                                   expanded: vm.exportOptionsExpanded,
                                   buttonTitle: resolutionChipTitle,
                                   duration: vm.duration,
                                   aspect: vm.timeline.aspectRatio,
                                   previewUltraHD: $vm.previewUltraHD,
                                   onClose: { vm.showExportOptions = false },
                                   onExport: {
                                       vm.showExportOptions = false
                                       vm.autoStartExport = true
                                       vm.showExport = true
                                   },
                                   onMore: {
                                       vm.showExportOptions = false
                                       vm.autoStartExport = false
                                       vm.showExport = true
                                   })
                    .frame(maxHeight: 560)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Floating AI lab button over the timeline.
    private var aiLabButton: some View {
        Menu {
            Button { vm.panel = .autoCut } label: { Label("AutoCut", systemImage: "wand.and.stars") }
            Button { vm.panel = .clipper } label: { Label("AI clipper", systemImage: "scissors.badge.ellipsis") }
            Button { vm.generateCaptions(); vm.panel = .captions } label: { Label("Auto captions", systemImage: "captions.bubble") }
            Button { vm.panel = .generate } label: { Label("Generate media", systemImage: "sparkles.rectangle.stack") }
            Button { vm.panel = .avatar } label: { Label("AI avatar", systemImage: "person.crop.square.badge.camera") }
            Button { vm.autoEnhanceAll() } label: { Label("Enhance all", systemImage: "wand.and.rays") }
        } label: {
            Image(systemName: "atom")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .frame(width: 50, height: 50)
                .background(Theme.chip, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6)
        }
        .accessibilityLabel("AI lab")
        .padding(.leading, 14)
        .padding(.bottom, 6)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Theme.canvas
            PlayerView(player: vm.player)
                .aspectRatio(CGFloat(vm.timeline.aspectRatio.value), contentMode: .fit)
                .onTapGesture { vm.togglePlay() }
                .accessibilityLabel("Video preview")
                .accessibilityHint("Double tap to play or pause")
                .accessibilityAddTraits(.startsMediaSession)
                .overlay { if showSafeZone { SafeZoneOverlay() } }
            if vm.timeline.clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.largeTitle)
                    Text("Add media to start editing").font(.headline)
                    Button("Add media") { vm.showAddMedia = true }.buttonStyle(PillButtonStyle())
                }
                .foregroundStyle(.secondary)
            }
            if let error = vm.buildError {
                Text(error).font(.footnote).padding(8)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxHeight: .infinity, alignment: .top).padding()
            }
            if vm.isWorking || importingMedia {
                WorkingOverlay(title: importingMedia ? "Importing media" : vm.workTitle,
                               progress: importingMedia ? importProgress : vm.workProgress) {
                    vm.cancelWork()
                }
            }
            if let toast = vm.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: vm.toast)
    }

    private var playbackBar: some View {
        ZStack {
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause" : "play")
                    .font(.system(size: 22, weight: .light))
                    .frame(width: 44, height: 40)
            }
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            HStack(spacing: 16) {
                Button { vm.pause(); vm.showFullscreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 17))
                }
                .accessibilityLabel("Full screen preview")
                Spacer()
                Button { showSafeZone.toggle() } label: {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 18))
                        .overlay(alignment: .bottomTrailing) {
                            Text(showSafeZone ? "ON" : "OFF")
                                .font(.system(size: 6, weight: .heavy))
                                .padding(.horizontal, 1.5)
                                .background(Theme.canvas)
                                .offset(x: 5, y: 3)
                        }
                }
                .accessibilityLabel("Safe zone")
                .accessibilityValue(showSafeZone ? "On" : "Off")
                Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 17)) }
                    .disabled(!vm.canUndo).accessibilityLabel("Undo")
                Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 17)) }
                    .disabled(!vm.canRedo).accessibilityLabel("Redo")
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    // MARK: Actions

    private func importMedia(_ assets: [PHAsset], asOverlay: Bool) {
        guard !assets.isEmpty else { return }
        importingMedia = true
        importProgress = 0
        Task {
            defer { importingMedia = false }
            do {
                let clips = try await library.importAssets(assets) { p in importProgress = p }
                if asOverlay, let first = clips.first { vm.addOverlay(from: first) } else { vm.addClips(clips) }
            } catch {
                vm.show(error.localizedDescription)
            }
        }
    }

    private func handleLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        switch launchAction {
        case .none: break
        case .autoCut: vm.panel = .autoCut
        case .captions: vm.generateCaptions(); vm.panel = .captions
        case .clipper: vm.panel = .clipper
        case .remove:
            vm.selection = vm.timeline.clips.first.map { .clip($0.id) }
            vm.removeBackground(true)
            vm.show("Background removed with on-device segmentation")
        case .enhance: vm.autoEnhanceAll()
        case .text: _ = vm.addText(); vm.panel = .text
        case .extend:
            vm.selection = vm.timeline.clips.last.map { .clip($0.id) }
            vm.panel = .extend
        case .exportOptions:
            vm.exportOptionsExpanded = true
            vm.showExportOptions = true
        case .exportSheet:
            vm.autoStartExport = false
            vm.showExport = true
        }
    }
}

// MARK: - Working overlay

struct WorkingOverlay: View {
    let title: String
    let progress: Double
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(width: 180)
            Text("\(title)... \(Int(progress * 100))%")
                .font(.subheadline.weight(.semibold))
            if let onCancel {
                Button("Cancel", action: onCancel).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Safe zone

/// Areas covered by TikTok/Reels UI (caption at the bottom, actions on the right).
struct SafeZoneOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.35).frame(width: w, height: h * 0.08)
                Color.black.opacity(0.35).frame(width: w, height: h * 0.2).offset(y: h * 0.8)
                Color.black.opacity(0.35).frame(width: w * 0.16, height: h * 0.72).offset(x: w * 0.84, y: h * 0.08)
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: w * 0.84, height: h * 0.72)
                    .offset(y: h * 0.08)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Full screen preview

struct FullscreenPreview: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: vm.player)
                .aspectRatio(CGFloat(vm.timeline.aspectRatio.value), contentMode: .fit)
                .onTapGesture { vm.togglePlay() }
            VStack {
                HStack {
                    Spacer()
                    Button { vm.pause(); dismiss() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 18)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Exit full screen")
                }
                Spacer()
                HStack(spacing: 14) {
                    Button { vm.togglePlay() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                    .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
                    Text("\(vm.currentTime.timecode) / \(vm.duration.timecode)")
                        .font(.caption.monospacedDigit())
                }
                .padding(.bottom, 20)
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tool search

struct EditorToolSearch: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [EditorPanel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return EditorPanel.allCases.filter { q.isEmpty || $0.title.lowercased().contains(q) || "\($0)".lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { panel in
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { open(panel) }
                } label: {
                    Text(panel.title).foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tools")
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func open(_ panel: EditorPanel) {
        switch panel {
        case .speed, .volume, .transition, .crop, .extend:
            if let id = vm.targetClipID { vm.selection = .clip(id) }
        case .text:
            if vm.timeline.texts.isEmpty { _ = vm.addText() }
        default: break
        }
        vm.panel = panel
    }
}
