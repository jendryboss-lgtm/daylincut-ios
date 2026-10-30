import SwiftData
import SwiftUI

// MARK: - Looks

/// Tabs in the review screen's looks tray.
enum LooksTab: String, CaseIterable, Identifiable {
    case forYou = "For you", lifestyle = "Lifestyle", beat = "Beat", lyrics = "Lyrics"
    var id: String { rawValue }

    /// Templates shown in this tab; bookmarked ones come first in "For you".
    func templates(bookmarked: Set<String>) -> [TemplatePreset] {
        let all = TemplatePreset.all
        switch self {
        case .forYou:
            return all.sorted { a, b in
                let ab = bookmarked.contains(a.id), bb = bookmarked.contains(b.id)
                return ab != bb ? ab : a.uses > b.uses
            }
        case .lifestyle:
            return all.filter { [.travel, .vlog, .fitness].contains($0.category) }
        case .beat:
            return all.filter { $0.pacing == .fast || $0.style == .energetic || $0.style == .socialMedia }
        case .lyrics:
            return all.filter { !$0.titleText.isEmpty }
        }
    }

    /// Lyrics looks also caption the audio.
    var addsCaptions: Bool { self == .lyrics }
}

/// Persists bookmarked looks.
enum LookBookmarks {
    static let key = "review.bookmarkedLooks"
    static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
    static func toggle(_ id: String, _ defaults: UserDefaults = .standard) -> Set<String> {
        var set = load(defaults)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        defaults.set(set.sorted(), forKey: key)
        return set
    }
}

// MARK: - Header

/// Back · music pill · resolution chip · Export (CapCut review header).
struct ReviewHeader: View {
    var musicTitle: String
    var resolutionTitle: String
    var enabled: Bool
    var chipOpen: Bool = false
    var onBack: () -> Void
    var onMusic: () -> Void
    var onResolution: () -> Void
    var onExport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Back")
            Spacer(minLength: 4)
            if !musicTitle.isEmpty {
                Button(action: onMusic) {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                        Text(musicTitle).lineLimit(1)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 34)
                    .frame(maxWidth: 160)
                    .background(Theme.chip, in: Capsule())
                }
                .accessibilityLabel("Music, \(musicTitle)")
                .disabled(!enabled)
            }
            Spacer(minLength: 4)
            Button(action: onResolution) {
                HStack(spacing: 4) {
                    Text(resolutionTitle)
                    Image(systemName: chipOpen ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 10).frame(height: 34)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Export settings, \(resolutionTitle)")
            .disabled(!enabled)
            Button(action: onExport) {
                Text("Export")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Theme.accent.opacity(enabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!enabled)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 50)
    }
}

// MARK: - Looks tray

/// Bottom sheet: bookmark, tabs, an "Edit" tile then look tiles, and the
/// "Edit & remix in AI lab" button.
struct LooksTray: View {
    @Binding var tab: LooksTab
    /// nil = the "Edit" (original) tile.
    var selected: String?
    var editThumbnail: UIImage?
    var editDuration: Double?
    var isLoading: Bool
    var isBookmarked: Bool
    var bookmarked: Set<String> = []
    var onBookmark: () -> Void
    var onEdit: () -> Void
    var onSelect: (TemplatePreset) -> Void
    var onRemix: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                Button(action: onBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 18))
                }
                .accessibilityLabel(isBookmarked ? "Remove bookmark" : "Bookmark look")
                .disabled(isLoading || selected == nil)
                ForEach(LooksTab.allCases) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 16, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? .white : Theme.mutedText)
                    }
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    editTile
                    ForEach(tab.templates(bookmarked: bookmarked)) { t in
                        lookTile(t)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 118)
            .redacted(reason: isLoading ? .placeholder : [])
            .disabled(isLoading)

            Button(action: onRemix) {
                HStack(spacing: 8) {
                    Image(systemName: "atom")
                    Text("Edit & remix in AI lab")
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isLoading)
            .opacity(isLoading ? 0.5 : 1)
            .padding(.horizontal, 16)
        }
        .foregroundStyle(.white)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Theme.panel, in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
    }

    private var editTile: some View {
        Button(action: onEdit) {
            ZStack {
                if let editThumbnail {
                    Image(uiImage: editThumbnail).resizable().scaledToFill()
                } else {
                    Theme.chip
                }
                Color.black.opacity(0.35)
                VStack(spacing: 4) {
                    Image(systemName: "pencil.line").font(.system(size: 18, weight: .semibold))
                    Text("Edit").font(.system(size: 13, weight: .semibold))
                }
                if let editDuration {
                    durationLabel(editDuration)
                }
            }
            .frame(width: 80, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: selected == nil && !isLoading ? 2 : 0))
        }
        .accessibilityLabel("Edit")
    }

    private func lookTile(_ t: TemplatePreset) -> some View {
        Button { onSelect(t) } label: {
            ZStack {
                LinearGradient(colors: t.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: t.symbol).font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                if bookmarked.contains(t.id) {
                    Image(systemName: "bookmark.fill").font(.system(size: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                }
                durationLabel(t.duration)
            }
            .frame(width: 80, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: selected == t.id ? 2 : 0))
        }
        .accessibilityLabel("\(t.title), \(Int(t.duration)) seconds")
    }

    private func durationLabel(_ d: Double) -> some View {
        Text(d.timecode)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(6)
    }
}

// MARK: - Review screen

/// The screen after compiling: preview with play/pause and scrub line, looks
/// tray, export chip/panel. "Edit" opens the full editor.
struct ReviewView: View {
    let project: Project
    let base: Timeline

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @State private var vm: EditorViewModel
    @State private var tab: LooksTab = .forYou
    @State private var selected: String?
    @State private var bookmarked = LookBookmarks.load()
    @State private var thumbnail: UIImage?
    @State private var leaving = false
    @State private var discarded = false

    init(project: Project, base: Timeline) {
        self.project = project
        self.base = base
        _vm = State(initialValue: EditorViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(musicTitle: vm.timeline.musicTitle,
                         resolutionTitle: resolutionTitle,
                         enabled: !vm.timeline.clips.isEmpty && !vm.isWorking,
                         chipOpen: vm.showExportOptions,
                         onBack: back,
                         onMusic: { vm.pause(); vm.panel = .audio },
                         onResolution: {
                             vm.pause()
                             vm.exportOptionsExpanded = false
                             vm.showExportOptions.toggle()
                         },
                         onExport: {
                             vm.pause()
                             vm.showExportOptions = false
                             vm.autoStartExport = true
                             vm.showExport = true
                         })
            preview
            LooksTray(tab: $tab, selected: selected, editThumbnail: thumbnail, editDuration: base.duration,
                      isLoading: false,
                      isBookmarked: selected.map { bookmarked.contains($0) } ?? false,
                      bookmarked: bookmarked,
                      onBookmark: { if let selected { bookmarked = LookBookmarks.toggle(selected) } },
                      onEdit: openEditor,
                      onSelect: { t in
                          selected = t.id
                          vm.applyTemplate(t, base: base, captions: tab.addsCaptions)
                      },
                      onRemix: {
                          vm.saveNow()
                          leaving = true
                          router.flow?.stage = .editing(project, .autoCut)
                      })
        }
        .background(Theme.canvas.ignoresSafeArea())
        .overlay(alignment: .top) { exportOptionsOverlay }
        .animation(.easeOut(duration: 0.2), value: vm.showExportOptions)
        .preferredColorScheme(.dark)
        .sheet(item: $vm.panel) { panel in
            EditorPanelHost(panel: panel, vm: vm)
                .presentationDetents(panel.detents)
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $vm.showExport) {
            ExportSheet(vm: vm)
                .presentationDetents([.large])
        }
        .task {
            thumbnail = await Self.firstFrame(of: base)
            if !vm.isPlaying { vm.togglePlay() }
        }
        .onDisappear {
            guard !discarded else { return }
            vm.tearDown()
            if !leaving { Task { await vm.refreshThumbnail() } }
        }
    }

    private var resolutionTitle: String {
        vm.exportSettings.aiUltraHD ? "AI UHD" : vm.exportSettings.resolution.title
    }

    private var preview: some View {
        ZStack {
            PlayerView(player: vm.player)
                .aspectRatio(CGFloat(vm.timeline.aspectRatio.value), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { vm.togglePlay() }
            if vm.isWorking {
                VStack(spacing: 14) {
                    CompilingBadge()
                    Text("\(vm.workTitle)... \(Int(vm.workProgress * 100))%")
                        .font(.system(size: 15, weight: .medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas.opacity(0.85))
            }
        }
        .overlay(alignment: .bottom) { scrubBar }
        .frame(maxHeight: .infinity)
    }

    private var scrubBar: some View {
        VStack(spacing: 6) {
            HStack {
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18)).frame(width: 36, height: 30)
                }
                .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
                Spacer()
                Text("\(vm.currentTime.timecode) / \(vm.duration.timecode)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            GeometryReader { geo in
                let frac = vm.duration > 0 ? min(1, vm.currentTime / vm.duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 2)
                    Capsule().fill(.white).frame(width: geo.size.width * frac, height: 2)
                    Circle().fill(.white).frame(width: 8, height: 8)
                        .offset(x: geo.size.width * frac - 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    vm.pause()
                    vm.seek(to: max(0, min(1, g.location.x / geo.size.width)) * vm.duration, precise: false)
                })
            }
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel("Playhead")
            .accessibilityValue(vm.currentTime.timecode)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .disabled(vm.isWorking)
    }

    @ViewBuilder
    private var exportOptionsOverlay: some View {
        if vm.showExportOptions {
            ZStack(alignment: .top) {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { vm.showExportOptions = false }
                ExportOptionsPanel(settings: $vm.exportSettings,
                                   expanded: vm.exportOptionsExpanded,
                                   buttonTitle: resolutionTitle,
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

    private func openEditor() {
        vm.saveNow()
        leaving = true
        router.flow?.stage = .editing(project, .none)
    }

    /// Back returns to the picker; the compiled draft is discarded unless the
    /// user exported it or picked a look (it then stays in Projects).
    private func back() {
        vm.cancelWork()
        if selected == nil {
            leaving = true
            vm.tearDown()
            discarded = true
            ProjectStore.delete(project, in: context)
        }
        router.flow?.stage = .picking
    }

    static func firstFrame(of timeline: Timeline) async -> UIImage? {
        guard let clip = timeline.clips.first else { return nil }
        let time = clip.sourceStart + min(0.5, clip.trimmedDuration / 2)
        guard let cg = await VideoEngine.thumbnail(fileName: clip.fileName, at: time, maxSize: CGSize(width: 240, height: 240)) else { return nil }
        return UIImage(cgImage: cg)
    }
}
