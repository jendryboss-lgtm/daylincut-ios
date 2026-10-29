import AVFoundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Editor state

enum EditorSelection: Hashable {
    case clip(UUID)
    case text(UUID)
    case audio(UUID)
    case overlay(UUID)
    case caption(UUID)
}

enum EditorPanel: String, Identifiable, Hashable {
    case speed, volume, transition, filters, adjust, effects, text, audio, overlay, captions, transcript
    case avatar, generate, aspect, autoCut, clipper, extend, crop
    var id: String { rawValue }
}

/// The editor's view model. All timeline mutations go through `apply(_:)` so they
/// get undo/redo, a debounced composition rebuild and autosave.
@MainActor
@Observable
final class EditorViewModel {

    // MARK: Document
    let project: Project
    private(set) var timeline: Timeline
    private var undoStack: [Timeline] = []
    private var redoStack: [Timeline] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Playback
    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuilding = false
    private(set) var buildError: String?
    var isScrubbing = false
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var built: BuiltComposition?

    // MARK: UI state
    var selection: EditorSelection?
    var panel: EditorPanel?
    var showExport = false
    var showAddMedia = false
    var showOverlayPicker = false
    var isWorking = false
    var workProgress: Double = 0
    var workTitle = ""
    var toast: String?
    var pixelsPerSecond: CGFloat = 60
    var previewResolution: ExportResolution = .p1080

    private var workTask: Task<Void, Never>?

    init(project: Project) {
        self.project = project
        self.timeline = project.timeline
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                self.isPlaying = self.player.rate != 0
            }
        }
        rebuild(immediately: true)
    }

    func tearDown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        rebuildTask?.cancel()
        workTask?.cancel()
        saveNow()
    }

    var duration: Double { timeline.duration }
    var layout: TimelineLayout { TimelineLayout(clips: timeline.clips) }

    // MARK: Mutations

    /// Applies a change with undo support. `coalesce` merges rapid slider changes into one undo step.
    func apply(_ change: (inout Timeline) -> Void, coalesce: Bool = false) {
        var next = timeline
        change(&next)
        guard next != timeline else { return }
        if !(coalesce && lastCoalesce.map({ Date().timeIntervalSince($0) < 0.8 }) == true) {
            undoStack.append(timeline)
            if undoStack.count > 80 { undoStack.removeFirst() }
        }
        lastCoalesce = coalesce ? Date() : nil
        redoStack.removeAll()
        timeline = next
        didChange()
    }
    private var lastCoalesce: Date?

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(timeline)
        timeline = prev
        didChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(timeline)
        timeline = next
        didChange()
    }

    private func didChange() {
        validateSelection()
        rebuild()
        scheduleSave()
    }

    private func validateSelection() {
        switch selection {
        case .clip(let id): if !timeline.clips.contains(where: { $0.id == id }) { selection = nil }
        case .text(let id): if !timeline.texts.contains(where: { $0.id == id }) { selection = nil }
        case .audio(let id): if !timeline.audio.contains(where: { $0.id == id }) { selection = nil }
        case .overlay(let id): if !timeline.overlays.contains(where: { $0.id == id }) { selection = nil }
        case .caption(let id): if !timeline.captions.contains(where: { $0.id == id }) { selection = nil }
        case nil: break
        }
    }

    // MARK: Composition

    func rebuild(immediately: Bool = false) {
        rebuildTask?.cancel()
        let snapshot = timeline
        rebuildTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 140_000_000) }
            guard !Task.isCancelled, let self else { return }
            guard !snapshot.clips.isEmpty else {
                self.player.replaceCurrentItem(with: nil)
                self.built = nil
                return
            }
            self.isBuilding = true
            defer { self.isBuilding = false }
            do {
                let built = try await VideoEngine.build(timeline: snapshot, options: self.previewOptions(for: snapshot))
                guard !Task.isCancelled else { return }
                let wasPlaying = self.player.rate != 0
                let time = min(self.currentTime, max(0, snapshot.duration - 0.05))
                let item = built.makePlayerItem()
                self.player.replaceCurrentItem(with: item)
                self.built = built
                self.observeEnd(of: item)
                _ = await self.player.seek(to: VideoEngine.cm(time), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { self.player.play() }
                self.buildError = nil
            } catch {
                self.buildError = error.localizedDescription
            }
        }
    }

    private func previewOptions(for timeline: Timeline) -> RenderPlan.Options {
        var options = RenderPlan.Options.preview(for: timeline)
        // Preview at 720p max for smooth playback regardless of the export choice.
        let short = min(720, previewResolution.shortSide)
        let size = timeline.aspectRatio.renderSize(shortSide: short)
        options.renderSize = CGSize(width: size.width, height: size.height)
        return options
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    // MARK: Playback

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: Double, precise: Bool = true) {
        let t = max(0, min(time, max(0, duration - 0.001)))
        currentTime = t
        let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 30)
        player.seek(to: VideoEngine.cm(t), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    // MARK: Selection helpers

    var selectedClipID: UUID? {
        if case .clip(let id) = selection { return id }
        return nil
    }

    var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        return timeline.clips.first { $0.id == id }
    }

    /// Selected clip, or the clip under the playhead.
    var targetClipID: UUID? {
        if let id = selectedClipID { return id }
        guard let i = layout.clipIndex(at: currentTime), timeline.clips.indices.contains(i) else { return nil }
        return timeline.clips[i].id
    }

    var targetClip: Clip? {
        guard let id = targetClipID else { return nil }
        return timeline.clips.first { $0.id == id }
    }

    func updateTargetClip(coalesce: Bool = false, _ edit: @escaping (inout Clip) -> Void) {
        guard let id = targetClipID else { return }
        apply({ $0.updateClip(id: id, edit) }, coalesce: coalesce)
    }

    // MARK: Clip operations

    func splitAtPlayhead() {
        var newID: UUID?
        apply { newID = $0.split(at: currentTime) }
        if let newID { selection = .clip(newID) } else { show("Move the playhead inside a clip to split") }
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id):
            guard timeline.clips.count > 1 else { show("A project needs at least one clip"); return }
            apply { $0.deleteClip(id: id) }
        case .text(let id): apply { $0.texts.removeAll { $0.id == id } }
        case .audio(let id): apply { $0.audio.removeAll { $0.id == id } }
        case .overlay(let id): apply { $0.overlays.removeAll { $0.id == id } }
        case .caption(let id): apply { $0.captions.removeAll { $0.id == id } }
        case nil: break
        }
        selection = nil
    }

    func duplicateSelection() {
        switch selection {
        case .clip(let id):
            var newID: UUID?
            apply { newID = $0.duplicateClip(id: id) }
            if let newID { selection = .clip(newID) }
        case .text(let id):
            guard var t = timeline.texts.first(where: { $0.id == id }) else { return }
            t.id = UUID(); t.start = min(duration - 0.2, t.end)
            apply { $0.texts.append(t) }
            selection = .text(t.id)
        default: break
        }
    }

    func moveSelectedClip(by delta: Int) {
        guard let id = selectedClipID else { return }
        apply { $0.moveClip(id: id, by: delta) }
    }

    func trimSelected(start: Double? = nil, end: Double? = nil) {
        guard let id = selectedClipID else { return }
        apply({ tl in
            tl.updateClip(id: id) { clip in
                clip = clip.trimmed(start: start ?? clip.sourceStart, end: end ?? clip.sourceEnd)
            }
            tl.clampToDuration()
        }, coalesce: true)
    }

    func addClips(_ clips: [Clip]) {
        apply { $0.insert(clips, at: $0.clips.isEmpty ? nil : currentTime) }
    }

    /// "Add ending": a branded end card with the project title.
    func addEnding() {
        runWork("Adding ending") { vm, progress in
            let aspect = vm.timeline.aspectRatio
            var clip = try await AIServiceProvider.current.generateVideo(prompt: "Thanks for watching", duration: 2.5,
                                                                          aspect: aspect, progress: progress)
            clip.transition = Transition()
            let start = vm.duration
            vm.apply { tl in
                if !tl.clips.isEmpty { tl.clips[tl.clips.count - 1].transition = Transition(type: .fadeBlack, duration: 0.5) }
                tl.clips.append(clip)
            }
            vm.apply { tl in
                tl.texts.append(TextOverlay(text: "Thanks for watching", start: max(0, start - 0.3), duration: 2.6,
                                            centerY: 0.5, fontScale: 0.06, style: .neon, animation: .pop))
            }
        }
    }

    // MARK: Text

    func addText(_ text: String = "Enter text") -> UUID {
        let t = TextOverlay(text: text, start: min(currentTime, max(0, duration - 1)), duration: min(3, max(0.5, duration - currentTime)))
        apply { $0.texts.append(t) }
        selection = .text(t.id)
        return t.id
    }

    func updateText(id: UUID, coalesce: Bool = true, _ edit: @escaping (inout TextOverlay) -> Void) {
        apply({ tl in
            if let i = tl.texts.firstIndex(where: { $0.id == id }) { edit(&tl.texts[i]) }
        }, coalesce: coalesce)
    }

    // MARK: Audio

    func addAudio(_ item: AudioItem, at start: Double? = nil) {
        var item = item
        if let start { item.start = start } else if item.kind != .music { item.start = currentTime }
        item.duration = min(item.duration, max(0.1, duration - item.start))
        apply { $0.audio.append(item) }
        selection = .audio(item.id)
    }

    func updateAudio(id: UUID, coalesce: Bool = true, _ edit: @escaping (inout AudioItem) -> Void) {
        apply({ tl in
            if let i = tl.audio.firstIndex(where: { $0.id == id }) { edit(&tl.audio[i]) }
            tl.clampToDuration()
        }, coalesce: coalesce)
    }

    func importAudioFile(_ url: URL) {
        runWork("Importing audio") { vm, _ in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let name = try MediaStore.importFile(at: url)
            let info = try await MediaProbe.probe(MediaStore.url(for: name))
            guard info.hasAudio else { throw VideoEngineError.unreadableMedia(url.lastPathComponent) }
            vm.addAudio(AudioItem(kind: .music, title: url.deletingPathExtension().lastPathComponent, fileName: name,
                                  sourceDuration: info.duration, start: 0, duration: info.duration, volume: 0.8, fadeOut: 1))
        }
    }

    func addBeat(style: AutoCutStyle) {
        runWork("Composing \(style.title) beat") { vm, _ in
            var item = try await AIServiceProvider.current.generateMusic(style: style, duration: max(4, vm.duration))
            item.start = 0
            vm.addAudio(item)
        }
    }

    /// Extracts the selected clip's audio into its own audio item and mutes the clip.
    func extractAudio() {
        guard let clip = targetClip, clip.hasAudio, clip.mediaKind == .video,
              let index = timeline.clips.firstIndex(where: { $0.id == clip.id }) else {
            show("This clip has no audio to extract"); return
        }
        let start = layout.placements[index].start
        runWork("Extracting audio") { vm, _ in
            let asset = AVURLAsset(url: MediaStore.url(for: clip.fileName))
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw VideoEngineError.unreadableMedia(clip.fileName)
            }
            let target = MediaStore.newFile(extension: "m4a")
            session.outputURL = target.url
            session.outputFileType = .m4a
            session.timeRange = CMTimeRange(start: VideoEngine.cm(clip.sourceStart), end: VideoEngine.cm(clip.sourceEnd))
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? VideoEngineError.writerFailed("Audio extraction failed")
            }
            let length = clip.trimmedDuration
            vm.apply { tl in
                tl.updateClip(id: clip.id) { $0.volume = 0 }
                tl.audio.append(AudioItem(kind: .extracted, title: "Extracted audio", fileName: target.name,
                                          sourceDuration: length, start: start, duration: min(length / clip.speed, tl.duration - start),
                                          volume: clip.volume))
            }
        }
    }

    // MARK: Overlay

    func addOverlay(from clip: Clip) {
        let item = OverlayItem(mediaKind: clip.mediaKind, fileName: clip.fileName, sourceDuration: clip.sourceDuration,
                               start: currentTime, sourceStart: 0,
                               duration: min(clip.mediaKind == .photo ? 3 : clip.sourceDuration, max(0.2, duration - currentTime)),
                               displayWidth: clip.displayWidth, displayHeight: clip.displayHeight)
        apply { $0.overlays.append(item) }
        selection = .overlay(item.id)
    }

    func updateOverlay(id: UUID, coalesce: Bool = true, _ edit: @escaping (inout OverlayItem) -> Void) {
        apply({ tl in
            if let i = tl.overlays.firstIndex(where: { $0.id == id }) { edit(&tl.overlays[i]) }
            tl.clampToDuration()
        }, coalesce: coalesce)
    }

    // MARK: AI tools

    func runAutoCut(_ settings: AutoCutSettings) {
        runWork("AutoCut") { vm, progress in
            let outcome = try await AutoCutEngine.run(on: vm.timeline, settings: settings) { p, _ in progress(p) }
            vm.apply { $0 = outcome.timeline }
            vm.seek(to: 0)
            let bpmText = outcome.bpm.map { " at \(Int($0.rounded())) BPM" } ?? ""
            vm.show("AutoCut made \(outcome.shotCount) shots from \(outcome.sceneCount) scenes\(bpmText)")
        }
    }

    func generateCaptions() {
        runWork("Generating captions") { vm, progress in
            let captions = try await CaptionService.captions(for: vm.timeline, progress: progress)
            vm.apply { $0.captions = captions }
            vm.show("Added \(captions.count) captions")
        }
    }

    func autoEnhanceAll(_ on: Bool = true) {
        apply { tl in for i in tl.clips.indices { tl.clips[i].autoEnhance = on } }
        show(on ? "Auto enhance applied to all clips" : "Auto enhance off")
    }

    func removeBackground(_ on: Bool) {
        updateTargetClip { $0.removeBackground = on }
        if on && timeline.background == .blur { apply { $0.background = .gradient } }
    }

    func extendTargetClip(by seconds: Double) {
        guard let clip = targetClip, let index = timeline.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        runWork("Extending video") { vm, progress in
            let extended = try await AIServiceProvider.current.extend(clip: clip, by: seconds, aspect: vm.timeline.aspectRatio, progress: progress)
            vm.apply { tl in
                tl.clips[index].transition = Transition(type: .dissolve, duration: 0.3)
                tl.clips.insert(extended, at: index + 1)
            }
            vm.show("Added \(Int(seconds)) s extension")
        }
    }

    func generateMedia(prompt: String, duration: Double) {
        runWork("Generating media") { vm, progress in
            let clip = try await AIServiceProvider.current.generateVideo(prompt: prompt, duration: duration,
                                                                         aspect: vm.timeline.aspectRatio, progress: progress)
            vm.addClips([clip])
        }
    }

    func addAvatar(script: String, look: AvatarLook, asOverlay: Bool) {
        runWork("Creating AI avatar") { vm, progress in
            let clip = try await AIServiceProvider.current.makeAvatar(script: script, look: look,
                                                                      aspect: asOverlay ? .square1x1 : vm.timeline.aspectRatio,
                                                                      progress: progress)
            if asOverlay {
                var item = OverlayItem(mediaKind: .video, fileName: clip.fileName, sourceDuration: clip.sourceDuration,
                                       start: vm.currentTime, sourceStart: 0,
                                       duration: min(clip.sourceDuration, max(0.2, vm.duration - vm.currentTime)),
                                       centerX: 0.76, centerY: 0.74, widthScale: 0.38, volume: 1,
                                       displayWidth: clip.displayWidth, displayHeight: clip.displayHeight)
                item.removeBackground = false
                vm.apply { $0.overlays.append(item) }
            } else {
                vm.addClips([clip])
            }
        }
    }

    func applyHighlights(_ highlights: [AIClipper.Highlight]) {
        apply { tl in
            var result: [Clip] = []
            for h in highlights {
                guard var c = tl.clips.first(where: { $0.id == h.clipID }) else { continue }
                c = c.trimmed(start: h.start, end: h.end)
                c.id = UUID()
                c.transition = Transition(type: .dissolve, duration: 0.3)
                result.append(c)
            }
            if !result.isEmpty {
                result[result.count - 1].transition = Transition()
                tl.clips = result
                tl.clampToDuration()
            }
        }
        seek(to: 0)
    }

    func cutRange(start: Double, end: Double) {
        apply { $0.removeRange(start: start, end: end) }
    }

    // MARK: Background work

    func runWork(_ title: String, _ work: @escaping @MainActor (EditorViewModel, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        workTask?.cancel()
        pause()
        workTitle = title
        workProgress = 0
        isWorking = true
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self) { p in
                    Task { @MainActor [weak self] in self?.workProgress = max(self?.workProgress ?? 0, min(1, p)) }
                }
            } catch is CancellationError {
            } catch VideoEngineError.cancelled {
            } catch {
                self.show(error.localizedDescription)
            }
            self.isWorking = false
        }
    }

    func cancelWork() {
        workTask?.cancel()
        isWorking = false
    }

    func show(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let context = project.modelContext else { return }
        ProjectStore.save(timeline, to: project, in: context)
    }

    func refreshThumbnail() async {
        guard let context = project.modelContext else { return }
        await ProjectStore.updateThumbnail(project, context: context)
    }

    // MARK: Frames

    func currentFrame(maxSize: CGSize = CGSize(width: 1080, height: 1080)) async -> UIImage? {
        guard let built else { return nil }
        guard let cg = await VideoEngine.renderedFrame(of: built, at: currentTime, maxSize: maxSize) else { return nil }
        return UIImage(cgImage: cg)
    }
}
