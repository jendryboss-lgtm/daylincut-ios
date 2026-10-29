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
            EditorToolbar(vm: vm)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
        var h: CGFloat = 20 + 54 + 28 + 28 + 6 * 4 + 12
        if !vm.timeline.overlays.isEmpty { h += 34 }
        if !vm.timeline.captions.isEmpty { h += 28 }
        return h
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                vm.saveNow()
                router.dismissFlow()
            } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Back")

            Button { vm.panel = .audio } label: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                    Text(vm.timeline.musicTitle).lineLimit(1)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).frame(height: 32)
                .background(Theme.surface, in: Capsule())
            }
            .accessibilityLabel("Music: \(vm.timeline.musicTitle)")

            Spacer()

            Menu {
                Picker("Resolution", selection: $vm.previewResolution) {
                    ForEach(ExportResolution.allCases) { r in
                        Text(r.requiresPro && !purchases.isPro ? "\(r.title) (Pro)" : r.title).tag(r)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(vm.previewResolution.title)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .onChange(of: vm.previewResolution) { _, new in
                if new.requiresPro && !purchases.require(.export4K) { vm.previewResolution = .p1080 }
            }
            .accessibilityLabel("Export resolution \(vm.previewResolution.title)")

            Button("Export") {
                vm.pause()
                vm.showExport = true
            }
            .buttonStyle(PillButtonStyle())
            .disabled(vm.timeline.clips.isEmpty)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black
            PlayerView(player: vm.player)
                .aspectRatio(CGFloat(vm.timeline.aspectRatio.value), contentMode: .fit)
                .onTapGesture { vm.togglePlay() }
                .accessibilityLabel("Video preview")
                .accessibilityHint("Double tap to play or pause")
                .accessibilityAddTraits(.startsMediaSession)
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
        HStack(spacing: 18) {
            Text("\(vm.currentTime.timecode) / \(vm.duration.timecode)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Time \(vm.currentTime.timecode) of \(vm.duration.timecode)")
            Spacer()
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo).accessibilityLabel("Undo")
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo).accessibilityLabel("Redo")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 40)
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
