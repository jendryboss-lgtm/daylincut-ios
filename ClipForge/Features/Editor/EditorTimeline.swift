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
                    textRow(originX: originX)
                    audioRow(originX: originX)
                    if !vm.timeline.overlays.isEmpty { overlayRow(originX: originX) }
                    if !vm.timeline.captions.isEmpty { captionRow(originX: originX) }
                }
                .padding(.top, 6)

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
        let last = min(vm.duration, (Double(width - originX) / Double(pps)))
        let ticks = stride(from: first, through: max(first, last), by: step).map { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                VStack(spacing: 1) {
                    Text(t.shortSeconds).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    Circle().fill(.secondary).frame(width: 2, height: 2)
                }
                .fixedSize()
                .offset(x: x(t, originX) - 10)
            }
        }
        .frame(height: rulerHeight, alignment: .topLeading)
        .accessibilityHidden(true)
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
            // Add media + Add ending at the end of the video.
            HStack(spacing: 8) {
                Button { vm.showAddMedia = true } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                }
                .accessibilityLabel("Add media")
                Button { vm.addEnding() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "flag.checkered")
                        Text("Add ending").font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: 56, height: 44)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                .foregroundStyle(.primary)
            }
            .offset(x: x(layout.totalDuration, originX) + 12, y: (clipHeight - 44) / 2)
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
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: rowHeight)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        }
        .foregroundStyle(.secondary)
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
