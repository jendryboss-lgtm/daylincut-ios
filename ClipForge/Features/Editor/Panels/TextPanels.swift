import SwiftUI

private let swatches = ["#FFFFFF", "#000000", "#FFD60A", "#FF375F", "#30D158", "#0A84FF", "#BF5AF2", "#FF9F0A"]
private let fonts = ["AvenirNext-Heavy", "AvenirNext-Regular", "Futura-Bold", "Georgia-Bold", "MarkerFelt-Wide", "Courier-Bold", "Didot-Bold"]

// MARK: - Text

struct TextPanel: View {
    @Bindable var vm: EditorViewModel
    @FocusState private var focused: Bool

    private var textID: UUID? {
        if case .text(let id) = vm.selection { return id }
        return nil
    }

    var body: some View {
        if let id = textID, let text = vm.timeline.texts.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Enter text", text: Binding(get: { text.text }, set: { v in vm.updateText(id: id) { $0.text = v } }), axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    .focused($focused)
                    .onAppear { if text.text == "Enter text" { focused = true } }

                section("Style") {
                    ForEach(TextStyle.allCases) { s in
                        Button { vm.updateText(id: id, coalesce: false) { $0.style = s } } label: { ChipView(title: s.title, isSelected: text.style == s) }
                    }
                }
                section("Font") {
                    ForEach(fonts, id: \.self) { f in
                        Button { vm.updateText(id: id, coalesce: false) { $0.fontName = f } } label: {
                            Text("Aa").font(.custom(f, size: 18))
                                .frame(width: 46, height: 36)
                                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(text.fontName == f ? Theme.accent : .clear, lineWidth: 2))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Font \(f)")
                    }
                }
                section("Color") {
                    ForEach(swatches, id: \.self) { hex in
                        Button { vm.updateText(id: id, coalesce: false) { $0.colorHex = hex } } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(text.colorHex == hex ? Theme.accent : .gray.opacity(0.4), lineWidth: 2))
                        }
                        .accessibilityLabel("Color \(hex)")
                    }
                }
                section("Animation") {
                    ForEach(TextAnimation.allCases) { a in
                        Button { vm.updateText(id: id, coalesce: false) { $0.animation = a } } label: { ChipView(title: a.title, isSelected: text.animation == a) }
                    }
                }
                LabeledSlider(title: "Size", value: Binding(get: { text.fontScale }, set: { v in vm.updateText(id: id) { $0.fontScale = v } }),
                              range: 0.02...0.16, format: { "\(Int($0 * 1000))" })
                LabeledSlider(title: "Horizontal", value: Binding(get: { text.centerX }, set: { v in vm.updateText(id: id) { $0.centerX = v } }),
                              range: 0.05...0.95, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Vertical", value: Binding(get: { text.centerY }, set: { v in vm.updateText(id: id) { $0.centerY = v } }),
                              range: 0.05...0.95, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Start", value: Binding(get: { text.start }, set: { v in vm.updateText(id: id) { $0.start = v } }),
                              range: 0...max(0.1, vm.duration - 0.1), format: { $0.timecode })
                LabeledSlider(title: "Duration", value: Binding(get: { text.duration }, set: { v in vm.updateText(id: id) { $0.duration = v } }),
                              range: 0.3...max(0.4, vm.duration - text.start), format: { String(format: "%.1fs", $0) })
            }
        } else {
            VStack(spacing: 12) {
                Button { _ = vm.addText() } label: { Label("Add text", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle())
                if !vm.timeline.texts.isEmpty {
                    ForEach(vm.timeline.texts) { t in
                        Button { vm.selection = .text(t.id); vm.seek(to: t.start) } label: {
                            HStack { Text(t.text).lineLimit(1); Spacer(); Text(t.start.timecode).foregroundStyle(.secondary) }
                                .padding(10).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { content() }
            }
        }
    }
}

// MARK: - Captions

struct CaptionsPanel: View {
    @Bindable var vm: EditorViewModel

    private var captionID: UUID? {
        if case .caption(let id) = vm.selection { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { vm.generateCaptions() } label: {
                Label(vm.timeline.captions.isEmpty ? "Generate auto captions" : "Regenerate captions", systemImage: "waveform.and.mic")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            Text("Speech recognition runs on-device when your iPhone supports it. \(vm.timeline.captions.count) captions.")
                .font(.footnote).foregroundStyle(.secondary)

            if let id = captionID, let caption = vm.timeline.captions.first(where: { $0.id == id }) {
                TextField("Caption", text: Binding(get: { caption.text }, set: { v in
                    vm.apply({ tl in if let i = tl.captions.firstIndex(where: { $0.id == id }) { tl.captions[i].text = v } }, coalesce: true)
                }), axis: .vertical)
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            }

            Text("Style").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(TextStyle.allCases) { s in
                        Button { vm.apply { $0.captionStyle.style = s } } label: { ChipView(title: s.title, isSelected: vm.timeline.captionStyle.style == s) }
                    }
                }
            }
            HStack {
                ForEach(swatches, id: \.self) { hex in
                    Button { vm.apply { $0.captionStyle.colorHex = hex } } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(vm.timeline.captionStyle.colorHex == hex ? Theme.accent : .gray.opacity(0.4), lineWidth: 2))
                    }
                    .accessibilityLabel("Caption color \(hex)")
                }
            }
            LabeledSlider(title: "Size", value: vm.timelineBinding(\.captionStyle.fontScale), range: 0.025...0.08, format: { "\(Int($0 * 1000))" })
            LabeledSlider(title: "Position", value: vm.timelineBinding(\.captionStyle.centerY), range: 0.1...0.92, format: { "\(Int($0 * 100))%" })
            Toggle("Uppercase", isOn: vm.timelineBinding(\.captionStyle.uppercase)).tint(Theme.accent)
            if !vm.timeline.captions.isEmpty {
                Button(role: .destructive) { vm.apply { $0.captions.removeAll() } } label: { Text("Remove all captions") }
            }
        }
    }
}

// MARK: - Transcript

/// Transcript-based editing: read along, fix text, jump to a line, or cut the
/// sentence out of the video entirely.
struct TranscriptPanel: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vm.timeline.captions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Transcribe the speech in your video to edit it like a document.")
                        .multilineTextAlignment(.center).font(.subheadline).foregroundStyle(.secondary)
                    Button("Transcribe video") { vm.generateCaptions() }.buttonStyle(PillButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                Text("Tap a line to jump to it. Cut removes that part of the video.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(vm.timeline.captions) { c in
                    let active = c.isVisible(at: vm.currentTime)
                    HStack(alignment: .top, spacing: 10) {
                        Button { vm.seek(to: c.start) } label: {
                            Text(c.start.timecode).font(.caption.monospacedDigit())
                                .foregroundStyle(active ? Theme.accent : .secondary)
                        }
                        TextField("", text: Binding(get: { c.text }, set: { v in
                            vm.apply({ tl in if let i = tl.captions.firstIndex(where: { $0.id == c.id }) { tl.captions[i].text = v } }, coalesce: true)
                        }), axis: .vertical)
                        .font(.body.weight(active ? .semibold : .regular))
                        Menu {
                            Button { vm.seek(to: c.start) } label: { Label("Play from here", systemImage: "play") }
                            Button(role: .destructive) { vm.cutRange(start: c.start, end: c.end) } label: {
                                Label("Cut from video", systemImage: "scissors")
                            }
                            Button(role: .destructive) { vm.apply { $0.captions.removeAll { $0.id == c.id } } } label: {
                                Label("Delete caption only", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 30, height: 30)
                        }
                        .accessibilityLabel("Line actions")
                    }
                    .padding(8)
                    .background(active ? Theme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
