import SwiftUI

/// AutoCut: style, mode, duration, aspect, sensitivity and pacing, then a real
/// scene + beat analysis that rebuilds the timeline.
struct AutoCutPanel: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autocut.settings") private var stored: Data = Data()
    @State private var settings = AutoCutSettings()
    @State private var customSeconds: Double = 45
    @State private var loaded = false

    private let styleColumns = [GridItem(.adaptive(minimum: 80), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Style") {
                LazyVGrid(columns: styleColumns, spacing: 10) {
                    ForEach(AutoCutStyle.allCases) { style in
                        Button { settings.style = style } label: {
                            VStack(spacing: 6) {
                                Image(systemName: style.symbol).font(.title3)
                                Text(style.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(settings.style == style ? Theme.accent.opacity(0.2) : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.style == style ? Theme.accent : .clear, lineWidth: 2))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("\(style.title) style")
                        .accessibilityAddTraits(settings.style == style ? .isSelected : [])
                    }
                }
            }

            group("Mode") {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(AutoCutMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(modeHint).font(.caption).foregroundStyle(.secondary)
            }

            group("Duration") {
                HStack {
                    ForEach(AutoCutSettings.presetDurations, id: \.self) { d in
                        Button {
                            settings.targetDuration = d
                            settings.isCustomDuration = false
                        } label: { ChipView(title: "\(Int(d))s", isSelected: !settings.isCustomDuration && settings.targetDuration == d) }
                    }
                    Button {
                        settings.isCustomDuration = true
                        settings.targetDuration = customSeconds
                    } label: { ChipView(title: "Custom", isSelected: settings.isCustomDuration) }
                }
                if settings.isCustomDuration {
                    LabeledSlider(title: "Length", value: Binding(get: { customSeconds }, set: { customSeconds = $0; settings.targetDuration = $0 }),
                                  range: 5...180, step: 1, format: { "\(Int($0))s" })
                }
            }

            group("Aspect ratio") {
                HStack {
                    ForEach([AspectRatio.portrait9x16, .landscape16x9, .square1x1, .portrait4x5]) { r in
                        Button { settings.aspectRatio = r } label: { ChipView(title: r.title, isSelected: settings.aspectRatio == r) }
                    }
                }
            }

            group("Cut sensitivity") {
                LabeledSlider(title: "Sensitivity", value: $settings.sensitivity, range: 0...1, format: { $0 < 0.34 ? "Low" : $0 < 0.67 ? "Medium" : "High" })
            }

            group("Pacing") {
                Picker("Pacing", selection: $settings.pacing) {
                    ForEach(AutoCutPacing.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Apply style look (filters, transitions, effects)", isOn: $settings.applyStyleLook).tint(Theme.accent)

            Button {
                persist()
                vm.runAutoCut(settings)
                dismiss()
            } label: {
                Label("Generate AutoCut", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(vm.timeline.clips.isEmpty)
            Text("Your current edit is kept in undo history.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
    }

    private var modeHint: String {
        switch settings.mode {
        case .music: return "Cuts land on the beats of your music (or a generated beat)."
        case .scene: return "Keeps the most interesting scenes, cut where the shot changes."
        case .hybrid: return "Picks the best scenes and snaps every cut to the beat."
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = try? JSONDecoder().decode(AutoCutSettings.self, from: stored) { settings = s }
        settings.aspectRatio = vm.timeline.aspectRatio == .portrait3x4 ? .portrait4x5 : vm.timeline.aspectRatio
        if settings.isCustomDuration { customSeconds = settings.targetDuration }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { stored = data }
    }
}
