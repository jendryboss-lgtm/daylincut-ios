import SwiftUI

// MARK: - Speed

struct SpeedPanel: View {
    @Bindable var vm: EditorViewModel
    private let presets: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 5]

    var body: some View {
        if let clip = vm.targetClip {
            VStack(alignment: .leading, spacing: 16) {
                // Log scale slider so 0.1x...10x is usable.
                LabeledSlider(title: "Speed", value: Binding(
                    get: { log10(clip.speed) },
                    set: { v in vm.apply({ $0.setSpeed(pow(10, v), clipID: clip.id) }, coalesce: true) }
                ), range: log10(Clip.minSpeed)...log10(Clip.maxSpeed), format: { String(format: "%.2fx", pow(10, $0)) })
                HStack {
                    ForEach(presets, id: \.self) { s in
                        Button { vm.apply { $0.setSpeed(s, clipID: clip.id) } } label: {
                            ChipView(title: s == floor(s) ? "\(Int(s))x" : "\(s)x", isSelected: abs(clip.speed - s) < 0.01)
                        }
                    }
                }
                Text("Duration \(clip.trimmedDuration.timecode) → \(clip.timelineDuration.timecode). Audio pitch is preserved.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else { NoClipView() }
    }
}

// MARK: - Volume

struct VolumePanel: View {
    @Bindable var vm: EditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.targetClip != nil {
                LabeledSlider(title: "Clip volume", value: Binding(
                    get: { Double(vm.targetClip?.volume ?? 1) },
                    set: { v in vm.updateTargetClip(coalesce: true) { $0.volume = Float(v) } }
                ), range: 0...2, format: { "\(Int($0 * 100))%" })
            }
            Toggle("Mute all original audio", isOn: vm.timelineBinding(\.muteOriginalAudio))
                .tint(Theme.accent)
        }
    }
}

// MARK: - Transition

struct TransitionPanel: View {
    @Bindable var vm: EditorViewModel
    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 10)]

    var body: some View {
        if let clip = vm.targetClip, let index = vm.timeline.clips.firstIndex(where: { $0.id == clip.id }) {
            VStack(alignment: .leading, spacing: 14) {
                if index == vm.timeline.clips.count - 1 {
                    Text("Transitions play between this clip and the next one. Add another clip to use them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TransitionType.allCases) { type in
                        Button {
                            vm.updateTargetClip { $0.transition.type = type }
                            vm.seek(to: max(0, vm.layout.placements[index].end - clip.transition.duration - 0.4))
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: type.symbol).font(.title3)
                                    .frame(width: 56, height: 44)
                                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(clip.transition.type == type ? Theme.accent : .clear, lineWidth: 2))
                                Text(type.title).font(.caption2).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(clip.transition.type == type ? .isSelected : [])
                    }
                }
                LabeledSlider(title: "Duration", value: vm.clipBinding(\.transition.duration, default: 0.5),
                              range: 0.1...1.5, format: { String(format: "%.1fs", $0) })
                Button("Apply to all clips") {
                    let t = clip.transition
                    vm.apply { tl in for i in tl.clips.indices.dropLast() { tl.clips[i].transition = t } }
                }
                .buttonStyle(PillButtonStyle(filled: false))
            }
        } else { NoClipView() }
    }
}

// MARK: - Filters

struct FiltersPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var previews: [FilterPreset: UIImage] = [:]

    var body: some View {
        if let clip = vm.targetClip {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(FilterPreset.allCases) { preset in
                            Button { vm.updateTargetClip { $0.filter = preset } } label: {
                                VStack(spacing: 4) {
                                    ZStack {
                                        if let img = previews[preset] {
                                            Image(uiImage: img).resizable().scaledToFill()
                                        } else {
                                            Theme.surfaceRaised
                                        }
                                    }
                                    .frame(width: 62, height: 62)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(clip.filter == preset ? Theme.accent : .clear, lineWidth: 2))
                                    Text(preset.title).font(.caption2)
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Filter \(preset.title)")
                            .accessibilityAddTraits(clip.filter == preset ? .isSelected : [])
                        }
                    }
                }
                if clip.filter != .none {
                    LabeledSlider(title: "Intensity", value: vm.clipBinding(\.filterIntensity, default: 1), range: 0...1,
                                  format: { "\(Int($0 * 100))" })
                }
                Button("Apply to all clips") {
                    vm.apply { tl in for i in tl.clips.indices { tl.clips[i].filter = clip.filter; tl.clips[i].filterIntensity = clip.filterIntensity } }
                }
                .buttonStyle(PillButtonStyle(filled: false))
            }
            .task(id: clip.fileName) { await loadPreviews(clip) }
        } else { NoClipView() }
    }

    private func loadPreviews(_ clip: Clip) async {
        guard let cg = await VideoEngine.thumbnail(fileName: clip.fileName, at: clip.sourceStart + clip.trimmedDuration / 2,
                                                   maxSize: CGSize(width: 140, height: 140)) else { return }
        for preset in FilterPreset.allCases {
            if Task.isCancelled { return }
            previews[preset] = FilterRenderer.previewImage(preset, from: cg)
        }
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @Bindable var vm: EditorViewModel
    var body: some View {
        if vm.targetClip != nil {
            VStack(spacing: 12) {
                LabeledSlider(title: "Brightness", value: vm.clipBinding(\.adjustments.brightness, default: 0), range: -0.5...0.5)
                LabeledSlider(title: "Contrast", value: vm.clipBinding(\.adjustments.contrast, default: 1), range: 0.5...1.5)
                LabeledSlider(title: "Saturation", value: vm.clipBinding(\.adjustments.saturation, default: 1), range: 0...2)
                LabeledSlider(title: "Exposure", value: vm.clipBinding(\.adjustments.exposure, default: 0), range: -2...2)
                LabeledSlider(title: "Temperature", value: vm.clipBinding(\.adjustments.temperature, default: 6500), range: 3000...10000,
                              format: { "\(Int($0))K" })
                LabeledSlider(title: "Sharpen", value: vm.clipBinding(\.adjustments.sharpness, default: 0), range: 0...1)
                LabeledSlider(title: "Vignette", value: vm.clipBinding(\.adjustments.vignette, default: 0), range: 0...2)
                HStack {
                    Button("Reset") { vm.updateTargetClip { $0.adjustments = Adjustments() } }
                        .buttonStyle(PillButtonStyle(filled: false))
                    Toggle("Auto enhance", isOn: vm.clipBinding(\.autoEnhance, default: false)).tint(Theme.accent)
                }
            }
        } else { NoClipView() }
    }
}

// MARK: - Crop

struct CropPanel: View {
    @Bindable var vm: EditorViewModel
    var body: some View {
        if vm.targetClip != nil {
            VStack(alignment: .leading, spacing: 12) {
                LabeledSlider(title: "Zoom", value: vm.clipBinding(\.adjustments.zoom, default: 1), range: 1...3,
                              format: { String(format: "%.1fx", $0) })
                Text("Zoom crops into the centre of the clip. Change the canvas in Aspect ratio.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else { NoClipView() }
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @Bindable var vm: EditorViewModel
    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 10)]
    var body: some View {
        if let clip = vm.targetClip {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(VisualEffect.allCases) { effect in
                    Button { vm.updateTargetClip { $0.effect = effect } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: effect.symbol).font(.title3)
                                .frame(width: 56, height: 48)
                                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(clip.effect == effect ? Theme.accent : .clear, lineWidth: 2))
                            Text(effect.title).font(.caption2).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(clip.effect == effect ? .isSelected : [])
                }
            }
        } else { NoClipView() }
    }
}

// MARK: - Extend

struct ExtendPanel: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds: Double = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seamlessly extend the selected clip. Daylin Cut continues its last frame with a slow push-in and motion so the cut feels natural.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                ForEach([2.0, 3, 5, 8], id: \.self) { s in
                    Button { seconds = s } label: { ChipView(title: "+\(Int(s))s", isSelected: seconds == s) }
                }
            }
            Button {
                vm.extendTargetClip(by: seconds)
                dismiss()
            } label: {
                Label("Extend video", systemImage: "arrow.right.to.line.compact").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(vm.targetClip == nil)
        }
    }
}

// MARK: - Aspect ratio

struct AspectRatioPanel: View {
    @Bindable var vm: EditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Button { vm.apply { $0.aspectRatio = ratio } } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(vm.timeline.aspectRatio == ratio ? Theme.accent : .secondary, lineWidth: 2)
                                    .frame(width: 40 * min(1, CGFloat(ratio.value)), height: 40 / max(1, CGFloat(ratio.value)))
                                    .frame(width: 48, height: 48)
                                Text(ratio.title).font(.caption)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Aspect ratio \(ratio.title)")
                        .accessibilityAddTraits(vm.timeline.aspectRatio == ratio ? .isSelected : [])
                    }
                }
            }
            Text("Background").font(.subheadline.weight(.semibold))
            HStack {
                ForEach(CanvasBackground.allCases) { bg in
                    Button { vm.apply { $0.background = bg } } label: { ChipView(title: bg.title, isSelected: vm.timeline.background == bg) }
                }
            }
        }
    }
}
