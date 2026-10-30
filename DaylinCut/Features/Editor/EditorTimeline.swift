import SwiftUI
import UIKit

/// Caches timeline filmstrip thumbnails.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [String: UIImage] = [:]
    private var order: [String] = []

    func image(fileName: String, time: Double, height: CGFloat) async -> UIImage? {
        let key = "\(fileName)@\(Int((time * 2).rounded()))"
        if let hit = images[key] { return hit }
        let size = CGSize(width: height * 2, height: height * 2)
        guard let cg = await VideoEngine.thumbnail(fileName: fileName, at: (time * 2).rounded() / 2, maxSize: size) else { return nil }
        let image = UIImage(cgImage: cg)
        images[key] = image
        order.append(key)
        if order.count > 400 { images[order.removeFirst()] = nil }
        return image
    }
}

/// CapCut-style timeline: fixed centre playhead, content scrolls under it.
struct EditorTimeline: View {
    @Bindable var vm: EditorViewModel

    @State private var dragStartTime: Double?
    @State private var zoomStart: CGFloat?

    private let rulerHeight: CGFloat = 20
    private let clipHeight: CGFloat = 54
    private let rowHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let originX = width / 2 - CGFloat(vm.currentTime) * vm.pixelsPerSecond
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { vm.selection = nil }
                VStack(alignment: .leading, spacing: 6) {
                    ruler(originX: originX, width: width)
                    clipsRow(originX: originX, width: width)
                    audioRow(originX: originX)
                    textRow(originX: originX)
                    if !vm.timeline.overlays.isEmpty { overlayRow(originX: originX) }
                    if !vm.timeline.captions.isEmpty { captionRow(originX: originX) }
                }
                .padding(.top, 6)

                leftColumn(width: width)

                // Add media, pinned to the right edge like CapCut.
                Button { vm.showAddMedia = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.black)
                }
                .accessibilityLabel("Add media")
                .offset(x: width - 34 - 10, y: 6 + rulerHeight + 6 + (clipHeight - 34) / 2)

                // Playhead
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: width / 2 - 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(scrub)
            .simultaneousGesture(zoom)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
            .accessibilityValue("\(vm.currentTime.timecode) of \(vm.duration.timecode)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: vm.seek(to: vm.currentTime + 1)
                case .decrement: vm.seek(to: vm.currentTime - 1)
                @unknown default: break
                }
            }
        }
        .background(Theme.timelineBackground)
    }

    // MARK: Gestures

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartTime == nil {
                    dragStartTime = vm.currentTime
                    vm.pause()
                    vm.isScrubbing = true
                }
                let t = (dragStartTime ?? 0) - Double(value.translation.width / vm.pixelsPerSecond)
                vm.seek(to: t, precise: false)
            }
            .onEnded { _ in
                vm.isScrubbing = false
                vm.seek(to: vm.currentTime)
                dragStartTime = nil
            }
    }

    private var zoom: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if zoomStart == nil { zoomStart = vm.pixelsPerSecond }
                vm.pixelsPerSecond = max(15, min(400, (zoomStart ?? 60) * scale))
            }
            .onEnded { _ in zoomStart = nil }
    }

    // MARK: Rows

    private func x(_ t: Double, _ originX: CGFloat) -> CGFloat { originX + CGFloat(t) * vm.pixelsPerSecond }

    private func ruler(originX: CGFloat, width: CGFloat) -> some View {
        let pps = vm.pixelsPerSecond
        let step: Double = pps > 160 ? 0.5 : pps > 60 ? 1 : pps > 30 ? 2 : 5
        let first = max(0, floor((0 - Double(originX)) / Double(pps) / step) * step)
        let last = min(max(vm.duration, step * 2), (Double(width - originX) / Double(pps)))
        let ticks = stride(from: first, through: max(first, last), by: step).map { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                let labelled = Int((t / step).rounded()) % 2 == 0
                Group {
                    if labelled {
                        Text(t.timecode).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.mutedText)
                    } else {
                        Circle().fill(Theme.mutedText).frame(width: 3, height: 3)
                    }
                }
                .fixedSize()
                .frame(width: 40)
                .offset(x: x(t, originX) - 20)
            }
            // Current / total time, fixed at the left like CapCut.
            HStack(spacing: 3) {
                Text(vm.currentTime.timecode).foregroundStyle(.white)
                Text("/ \(vm.duration.timecode)").foregroundStyle(Theme.mutedText)
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.leading, 16).padding(.trailing, 10)
            .frame(height: rulerHeight)
            .background(Theme.timelineBackground)
            .accessibilityLabel("Time \(vm.currentTime.timecode) of \(vm.duration.timecode)")
        }
        .frame(height: rulerHeight, alignment: .topLeading)
    }

    private func clipsRow(originX: CGFloat, width: CGFloat) -> some View {
        let layout = vm.layout
        let clips = vm.timeline.clips
        return ZStack(alignment: .topLeading) {
            ForEach(layout.placements, id: \.index) { p in
                if clips.indices.contains(p.index) {
                    let clip = clips[p.index]
                    let selected = vm.selectedClipID == clip.id
                    ClipStripView(clip: clip, width: CGFloat(p.duration) * vm.pixelsPerSecond, height: clipHeight,
                                  visibleRange: (-x(p.start, originX) - 100)...(width - x(p.start, originX) + 100),
                                  isSelected: selected)
                        .overlay(alignment: .topLeading) {
                            if clip.speed != 1 {
                                Text(String(format: "%.1fx", clip.speed))
                                    .font(.system(size: 9, weight: .bold)).padding(2)
                                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                    .padding(3)
                            }
                        }
                        .overlay { if selected { trimHandles(for: clip) } }
                        .offset(x: x(p.start, originX))
                        .onTapGesture { vm.selection = selected ? nil : .clip(clip.id) }
                        .accessibilityElement()
                        .accessibilityLabel("Clip \(p.index + 1), \(p.duration.timecode)")
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    if p.index < clips.count - 1 {
                        transitionButton(for: clip)
                            .offset(x: x(p.end - p.transitionOut / 2, originX) - 11, y: clipHeight / 2 - 11)
                    }
                }
            }
            // "+ Add ending" right after the last clip.
            Button { vm.addEnding() } label: {
                Label("Add ending", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: clipHeight)
                    .background(Theme.chip, in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6))
            }
            .accessibilityLabel("Add ending")
            .offset(x: x(layout.totalDuration, originX))
        }
        .frame(height: clipHeight, alignment: .topLeading)
    }

    private func transitionButton(for clip: Clip) -> some View {
        Button {
            vm.selection = .clip(clip.id)
            vm.panel = .transition
        } label: {
            Image(systemName: clip.transition.type == .none ? "square.split.2x1" : clip.transition.type.symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(clip.transition.type == .none ? Color.white : Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.black)
        }
        .accessibilityLabel("Transition: \(clip.transition.type.title)")
    }

    /// Fixed column to the left of the playhead: Mute clip audio, AI clipper,
    /// Cover, plus the audio/text row icons.
    private func leftColumn(width: CGFloat) -> some View {
        let columnWidth = max(150, width / 2 - 26)
        return VStack(alignment: .trailing, spacing: 6) {
            Color.clear.frame(height: rulerHeight)
            HStack(spacing: 6) {
                Button { vm.toggleMuteClipAudio() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: vm.timeline.muteOriginalAudio ? "speaker.slash" : "speaker.wave.1")
                            .font(.system(size: 17))
                        Text(vm.timeline.muteOriginalAudio ? "Unmute clip audio" : "Mute clip audio")
                            .font(.system(size: 9)).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(width: 54, height: clipHeight)
                }
                .accessibilityLabel(vm.timeline.muteOriginalAudio ? "Unmute clip audio" : "Mute clip audio")
                Button { vm.panel = .clipper } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "scissors.badge.ellipsis").font(.system(size: 17)).foregroundStyle(Theme.accent)
                        Text("AI clipper").font(.system(size: 9))
                    }
                    .frame(width: 54, height: clipHeight)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6))
                }
                Button { Task { await vm.setCoverFromCurrentFrame() } } label: {
                    ZStack {
                        if let cover = vm.coverImage {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Theme.chip
                        }
                        Color.black.opacity(0.35)
                        VStack(spacing: 2) {
                            Image(systemName: "pencil").font(.system(size: 15))
                            Text("Cover").font(.system(size: 9))
                        }
                    }
                    .frame(width: 54, height: clipHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Set cover from current frame")
            }
            .foregroundStyle(.white)
            rowIcon("music.note", label: "Audio") { vm.panel = .audio }
            rowIcon("textformat.size.larger", label: "Text") { _ = vm.addText(); vm.panel = .text }
        }
        .padding(.top, 6)
        .padding(.trailing, 10)
        .frame(width: columnWidth, alignment: .trailing)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(stops: [.init(color: Theme.timelineBackground, location: 0.88),
                                   .init(color: Theme.timelineBackground.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        )
    }

    private func rowIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 34, height: rowHeight)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(width: 54)
        .accessibilityLabel(label)
    }

    private func trimHandles(for clip: Clip) -> some View {
        HStack {
            TrimHandle(edge: .leading) { delta in
                vm.trimSelected(start: clip.sourceStart + Double(delta / vm.pixelsPerSecond) * clip.speed)
            }
            Spacer(minLength: 0)
            TrimHandle(edge: .trailing) { delta in
                vm.trimSelected(end: clip.sourceEnd + Double(delta / vm.pixelsPerSecond) * clip.speed)
            }
        }
    }

    private func textRow(originX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if vm.timeline.texts.isEmpty {
                placeholder("Add text", symbol: "textformat") { _ = vm.addText(); vm.panel = .text }
                    .offset(x: x(0, originX))
            }
            ForEach(vm.timeline.texts) { t in
                TimedItemView(title: t.text, symbol: "textformat", color: Theme.textTrack,
                              width: CGFloat(t.duration) * vm.pixelsPerSecond, height: rowHeight,
                              isSelected: vm.selection == .text(t.id),
                              onTap: { vm.selection = .text(t.id); vm.panel = .text },
                              onMove: { delta in
                                  vm.updateText(id: t.id) { $0.start = max(0, min(vm.duration - $0.duration, t.start + Double(delta / vm.pixelsPerSecond))) }
                              })
                    .offset(x: x(t.start, originX))
            }
        }
        .frame(height: rowHeight, alignment: .topLeading)
    }

    private func audioRow(originX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if vm.timeline.audio.isEmpty {
                placeholder("Add audio", symbol: "music.note") { vm.panel = .audio }
                    .offset(x: x(0, originX))
            }
            ForEach(vm.timeline.audio) { a in
                TimedItemView(title: a.title, symbol: a.kind == .voiceover ? "mic.fill" : "music.note", color: Theme.audioTrack,
                              width: CGFloat(a.duration) * vm.pixelsPerSecond, height: rowHeight,
                              isSelected: vm.selection == .audio(a.id), beats: a.beats.map { ($0 - a.sourceStart) / max(a.duration, 0.01) },
                              onTap: { vm.selection = .audio(a.id); vm.panel = .audio },
                              onMove: { delta in
                                  vm.updateAudio(id: a.id) { $0.start = max(0, a.start + Double(delta / vm.pixelsPerSecond)) }
                              })
                    .offset(x: x(a.start, originX))
            }
        }
        .frame(height: rowHeight, alignment: .topLeading)
    }

    private func overlayRow(originX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(vm.timeline.overlays) { o in
                TimedItemView(title: "Overlay", symbol: "square.on.square", color: Theme.overlayTrack,
                              width: CGFloat(o.duration) * vm.pixelsPerSecond, height: rowHeight,
                              isSelected: vm.selection == .overlay(o.id),
                              onTap: { vm.selection = .overlay(o.id); vm.panel = .overlay },
                              onMove: { delta in
                                  vm.updateOverlay(id: o.id) { $0.start = max(0, o.start + Double(delta / vm.pixelsPerSecond)) }
                              })
                    .offset(x: x(o.start, originX))
            }
        }
        .frame(height: rowHeight, alignment: .topLeading)
    }

    private func captionRow(originX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(vm.timeline.captions) { c in
                TimedItemView(title: c.text, symbol: "captions.bubble", color: Theme.captionTrack,
                              width: CGFloat(c.duration) * vm.pixelsPerSecond, height: 22,
                              isSelected: vm.selection == .caption(c.id),
                              onTap: { vm.selection = .caption(c.id); vm.panel = .captions }, onMove: nil)
                    .offset(x: x(c.start, originX))
            }
        }
        .frame(height: 22, alignment: .topLeading)
    }

    private func placeholder(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: rowHeight)
                .background(Theme.chip.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(Theme.mutedText)
    }
}

// MARK: - Pieces

struct ClipStripView: View {
    let clip: Clip
    let width: CGFloat
    let height: CGFloat
    let visibleRange: ClosedRange<CGFloat>
    let isSelected: Bool

    var body: some View {
        let tileWidth = max(24, height * CGFloat(min(1.2, max(0.5, clip.displayWidth / max(1, clip.displayHeight)))))
        let count = max(1, Int(ceil(width / tileWidth)))
        let firstVisible = max(0, Int(floor(visibleRange.lowerBound / tileWidth)))
        let lastVisible = min(count - 1, Int(ceil(visibleRange.upperBound / tileWidth)))
        ZStack(alignment: .topLeading) {
            Theme.surfaceRaised
            if firstVisible <= lastVisible {
                ForEach(firstVisible...lastVisible, id: \.self) { i in
                    let localTime = (Double(i) + 0.5) * Double(tileWidth / max(width, 1)) * clip.trimmedDuration
                    FilmTile(fileName: clip.fileName, time: clip.sourceStart + localTime, height: height)
                        .frame(width: tileWidth, height: height)
                        .clipped()
                        .offset(x: CGFloat(i) * tileWidth)
                }
            }
        }
        .frame(width: max(2, width), height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.white : Color.black.opacity(0.4), lineWidth: isSelected ? 2 : 1))
    }
}

struct FilmTile: View {
    let fileName: String
    let time: Double
    let height: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.25)
            }
        }
        .task(id: "\(fileName)\(Int(time * 2))") {
            image = await ThumbnailCache.shared.image(fileName: fileName, time: time, height: height)
        }
    }
}

struct TrimHandle: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 14)
            .overlay(Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 12, weight: .heavy)).foregroundStyle(.black))
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = value.translation.width - last
                        last = value.translation.width
                        onDrag(delta)
                    }
                    .onEnded { _ in last = 0 }
            )
            .accessibilityLabel(edge == .leading ? "Trim start" : "Trim end")
            .accessibilityAdjustableAction { dir in
                onDrag(dir == .increment ? 6 : -6)
            }
    }
}

struct TimedItemView: View {
    let title: String
    let symbol: String
    let color: Color
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    var beats: [Double] = []
    let onTap: () -> Void
    let onMove: ((CGFloat) -> Void)?
    @State private var last: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: max(8, width), height: height, alignment: .leading)
        .background {
            ZStack(alignment: .leading) {
                color.opacity(0.85)
                GeometryReader { g in
                    ForEach(Array(beats.enumerated()), id: \.offset) { _, b in
                        if b >= 0 && b <= 1 {
                            Circle().fill(.white.opacity(0.8)).frame(width: 3, height: 3)
                                .position(x: g.size.width * b, y: g.size.height - 3)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Color.white : .clear, lineWidth: 2))
        .foregroundStyle(.white)
        .onTapGesture(perform: onTap)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.25).sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    guard let onMove, case .second(true, let drag?) = value else { return }
                    let delta = drag.translation.width - last
                    last = drag.translation.width
                    onMove(delta)
                }
                .onEnded { _ in last = 0 }
        )
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(onMove == nil ? "" : "Long press and drag to move")
    }
}
