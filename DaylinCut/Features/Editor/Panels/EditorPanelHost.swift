import SwiftUI

extension EditorPanel {
    var title: String {
        switch self {
        case .speed: return "Speed"
        case .volume: return "Volume"
        case .transition: return "Transitions"
        case .filters: return "Filters"
        case .adjust: return "Adjust"
        case .effects: return "Effects"
        case .text: return "Text"
        case .audio: return "Audio"
        case .overlay: return "Overlay"
        case .captions: return "Captions"
        case .transcript: return "Transcript"
        case .avatar: return "AI avatar"
        case .generate: return "Generate media"
        case .aspect: return "Aspect ratio"
        case .autoCut: return "AutoCut"
        case .clipper: return "AI clipper"
        case .extend: return "Extend video"
        case .crop: return "Crop & zoom"
        case .stickers: return "Stickers"
        }
    }

    var detents: Set<PresentationDetent> {
        switch self {
        case .autoCut, .transcript, .avatar, .clipper: return [.medium, .large]
        case .text, .audio, .captions, .generate, .overlay, .stickers: return [.height(340), .large]
        default: return [.height(300), .medium]
        }
    }
}

/// Hosts each editor panel in a bottom sheet with a shared header.
struct EditorPanelHost: View {
    let panel: EditorPanel
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel.title).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "checkmark").font(.headline)
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .accessibilityLabel("Done")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .speed: SpeedPanel(vm: vm)
        case .volume: VolumePanel(vm: vm)
        case .transition: TransitionPanel(vm: vm)
        case .filters: FiltersPanel(vm: vm)
        case .adjust: AdjustPanel(vm: vm)
        case .effects: EffectsPanel(vm: vm)
        case .text: TextPanel(vm: vm)
        case .audio: AudioPanel(vm: vm)
        case .overlay: OverlayPanel(vm: vm)
        case .captions: CaptionsPanel(vm: vm)
        case .transcript: TranscriptPanel(vm: vm)
        case .avatar: AvatarPanel(vm: vm)
        case .generate: GenerateMediaPanel(vm: vm)
        case .aspect: AspectRatioPanel(vm: vm)
        case .autoCut: AutoCutPanel(vm: vm)
        case .clipper: ClipperPanel(vm: vm)
        case .extend: ExtendPanel(vm: vm)
        case .crop: CropPanel(vm: vm)
        case .stickers: StickersPanel(vm: vm)
        }
    }
}

/// Labelled slider row used throughout the panels.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step).tint(Theme.accent)
            } else {
                Slider(value: $value, in: range).tint(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
}

struct NoClipView: View {
    var body: some View {
        Text("Select a clip on the timeline first.")
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// A binding into a field of the target clip, recorded as a coalesced undo step.
extension EditorViewModel {
    func clipBinding<T>(_ keyPath: WritableKeyPath<Clip, T>, default value: T) -> Binding<T> {
        Binding(
            get: { self.targetClip?[keyPath: keyPath] ?? value },
            set: { newValue in self.updateTargetClip(coalesce: true) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func timelineBinding<T>(_ keyPath: WritableKeyPath<Timeline, T>) -> Binding<T> {
        Binding(
            get: { self.timeline[keyPath: keyPath] },
            set: { newValue in self.apply({ $0[keyPath: keyPath] = newValue }, coalesce: true) }
        )
    }
}
