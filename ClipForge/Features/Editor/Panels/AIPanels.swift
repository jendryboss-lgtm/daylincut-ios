import SwiftUI

// MARK: - Overlay

struct OverlayPanel: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    private var overlayID: UUID? {
        if case .overlay(let id) = vm.selection { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                dismiss()
                vm.showOverlayPicker = true
            } label: { Label("Add overlay", systemImage: "plus").frame(maxWidth: .infinity) }
            .buttonStyle(PillButtonStyle())

            if let id = overlayID, let o = vm.timeline.overlays.first(where: { $0.id == id }) {
                LabeledSlider(title: "Size", value: binding(id, \.widthScale, o.widthScale), range: 0.1...1, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Horizontal", value: binding(id, \.centerX, o.centerX), range: 0...1, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Vertical", value: binding(id, \.centerY, o.centerY), range: 0...1, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Opacity", value: binding(id, \.opacity, o.opacity), range: 0.1...1, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Volume", value: Binding(get: { Double(o.volume) }, set: { v in vm.updateOverlay(id: id) { $0.volume = Float(v) } }),
                              range: 0...2, format: { "\(Int($0 * 100))%" })
                Toggle("Remove background (Vision)", isOn: Binding(get: { o.removeBackground }, set: { v in vm.updateOverlay(id: id, coalesce: false) { $0.removeBackground = v } }))
                    .tint(Theme.accent)
            } else if !vm.timeline.overlays.isEmpty {
                Text("Tap an overlay on the timeline to adjust it.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Overlays play picture-in-picture above your main video. Cut out the person with Remove background for a green-screen effect.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<OverlayItem, Double>, _ value: Double) -> Binding<Double> {
        Binding(get: { value }, set: { v in vm.updateOverlay(id: id) { $0[keyPath: keyPath] = v } })
    }
}

// MARK: - AI avatar

struct AvatarPanel: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var script = "Hey everyone! Here's what we're making today."
    @State private var look: AvatarLook = .nova
    @State private var asOverlay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write a script and your avatar presents it with a synthesized voice and lip-sync.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("Script", text: $script, axis: .vertical)
                .lineLimit(3...6)
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                ForEach(AvatarLook.allCases) { l in
                    Button { look = l } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                LinearGradient(colors: l.backgroundHex.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
                                Circle().fill(Color(hex: l.skinHex)).frame(width: 30, height: 30)
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(look == l ? Theme.accent : .clear, lineWidth: 2))
                            Text(l.title).font(.caption2)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Avatar \(l.title)")
                    .accessibilityAddTraits(look == l ? .isSelected : [])
                }
            }
            Toggle("Place as picture-in-picture", isOn: $asOverlay).tint(Theme.accent)
            Button {
                vm.addAvatar(script: script, look: look, asOverlay: asOverlay)
                dismiss()
            } label: { Label("Create avatar", systemImage: "person.crop.circle.badge.plus").frame(maxWidth: .infinity) }
            .buttonStyle(PillButtonStyle())
            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            AIDisclosure()
        }
    }
}

// MARK: - Generate media

struct GenerateMediaPanel: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var duration: Double = 4
    private let ideas = ["Neon city at night", "Sunset over the ocean", "Abstract purple waves", "Snowy mountain morning"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Describe a scene", text: $prompt, axis: .vertical)
                .lineLimit(2...4)
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ideas, id: \.self) { idea in
                        Button { prompt = idea } label: { ChipView(title: idea, symbol: "lightbulb", isSelected: prompt == idea) }
                    }
                }
            }
            HStack {
                Text("Length").font(.subheadline)
                Spacer()
                Picker("Length", selection: $duration) {
                    ForEach([3.0, 4, 6, 8], id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Button {
                vm.generateMedia(prompt: prompt, duration: duration)
                dismiss()
            } label: { Label("Generate and insert", systemImage: "sparkles").frame(maxWidth: .infinity) }
            .buttonStyle(PillButtonStyle())
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            AIDisclosure()
        }
    }
}

/// Honest note about which AI backend produced the media.
struct AIDisclosure: View {
    var body: some View {
        let service = AIServiceProvider.current
        Label(service.isGenerative ? "Generated by \(service.name)" : "Created on-device by \(service.name). Connect a cloud model in AIService for photoreal results.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - AI clipper

struct ClipperPanel: View {
    @Bindable var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var highlights: [AIClipper.Highlight] = []
    @State private var chosen: Set<UUID> = []
    @State private var window: Double = 4
    @State private var analyzing = false
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finds the moments with people and motion and turns them into a highlight reel.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text("Clip length").font(.subheadline)
                Spacer()
                Picker("Clip length", selection: $window) {
                    ForEach([2.0, 4, 6, 10], id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 200)
            }
            if analyzing {
                ProgressView(value: progress) { Text("Analyzing \(Int(progress * 100))%") }.tint(Theme.accent)
            } else {
                Button(highlights.isEmpty ? "Find highlights" : "Analyze again") { analyze() }
                    .buttonStyle(PillButtonStyle(filled: highlights.isEmpty))
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            ForEach(highlights) { h in
                let clip = vm.timeline.clips.first { $0.id == h.clipID }
                Button {
                    if chosen.contains(h.id) { chosen.remove(h.id) } else { chosen.insert(h.id) }
                } label: {
                    HStack(spacing: 12) {
                        if let clip {
                            FilmTile(fileName: clip.fileName, time: (h.start + h.end) / 2, height: 48)
                                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading) {
                            Text("\(h.start.timecode) – \(h.end.timecode)").font(.subheadline.monospacedDigit())
                            Text("Score \(Int(h.score * 100))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: chosen.contains(h.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen.contains(h.id) ? Theme.accent : .secondary)
                            .font(.title3)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityAddTraits(chosen.contains(h.id) ? .isSelected : [])
            }
            if !highlights.isEmpty {
                Button {
                    vm.applyHighlights(highlights.filter { chosen.contains($0.id) })
                    dismiss()
                } label: { Text("Make highlight reel (\(chosen.count))").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle())
                .disabled(chosen.isEmpty)
            }
        }
    }

    private func analyze() {
        analyzing = true
        progress = 0
        error = nil
        let clips = vm.timeline.clips
        let window = window
        Task {
            do {
                let result = try await AIClipper.highlights(in: clips, window: window) { p in
                    Task { @MainActor in progress = p }
                }
                highlights = result
                chosen = Set(result.map(\.id))
                if result.isEmpty { error = "No video clips long enough to clip." }
            } catch {
                self.error = error.localizedDescription
            }
            analyzing = false
        }
    }
}
