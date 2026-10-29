import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Records a voice-over into the media store with AVAudioRecorder.
@MainActor
@Observable
final class VoiceoverRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    var error: String?
    private var recorder: AVAudioRecorder?
    private var file: (name: String, url: URL)?
    private var timer: Timer?

    func start() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { error = "Allow microphone access in Settings to record a voice-over."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let file = MediaStore.newFile(extension: "m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: file.url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw VideoEngineError.writerFailed("Recording could not start") }
            self.recorder = recorder
            self.file = file
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let r = self.recorder else { return }
                    r.updateMeters()
                    self.elapsed = r.currentTime
                    self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stops and returns the recorded file.
    func stop() -> (name: String, duration: Double)? {
        timer?.invalidate()
        timer = nil
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        guard let file, duration > 0.2 else { return nil }
        self.file = nil
        return (file.name, duration)
    }
}

struct AudioPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var showImporter = false
    @State private var recorder = VoiceoverRecorder()
    @State private var ttsText = ""
    @State private var showTTS = false
    @State private var recordStart: Double = 0

    private var audioID: UUID? {
        if case .audio(let id) = vm.selection { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let id = audioID, let item = vm.timeline.audio.first(where: { $0.id == id }) {
                selectedItem(item)
                Divider()
            }
            Text("Add audio").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                tile("Import file", "folder") { showImporter = true }
                tile(recorder.isRecording ? "Stop \(recorder.elapsed.shortSeconds)" : "Voice-over",
                     recorder.isRecording ? "stop.circle.fill" : "mic.fill") { toggleRecording() }
                tile("Text to speech", "text.bubble") { showTTS.toggle() }
                tile("Extract audio", "waveform.badge.minus") { vm.extractAudio() }
            }
            if recorder.isRecording {
                ProgressView(value: Double(recorder.level)).tint(.red)
                    .accessibilityLabel("Recording level")
            }
            if let error = recorder.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if showTTS {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Type what the narrator should say", text: $ttsText, axis: .vertical)
                        .padding(10).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    Button("Add narration") { addSpeech() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(ttsText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Beats").font(.subheadline.weight(.semibold))
            Text("Royalty-free beats composed on your device, with beat markers AutoCut can sync to.")
                .font(.footnote).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AutoCutStyle.allCases) { style in
                        Button { vm.addBeat(style: style) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: style.symbol).font(.title3)
                                Text(style.title).font(.caption.weight(.semibold))
                                Text("\(Int(style.bpm)) BPM").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: 96, alignment: .leading)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Add \(style.title) beat, \(Int(style.bpm)) BPM")
                    }
                }
            }
            Toggle("Mute original clip audio", isOn: vm.timelineBinding(\.muteOriginalAudio)).tint(Theme.accent)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff]) { result in
            if case .success(let url) = result { vm.importAudioFile(url) }
        }
    }

    private func selectedItem(_ item: AudioItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: item.kind == .voiceover ? "mic.fill" : "music.note")
                Text(item.title).font(.headline).lineLimit(1)
                Spacer()
                Button(role: .destructive) { vm.deleteSelection() } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete audio")
            }
            LabeledSlider(title: "Volume", value: Binding(get: { Double(item.volume) }, set: { v in vm.updateAudio(id: item.id) { $0.volume = Float(v) } }),
                          range: 0...2, format: { "\(Int($0 * 100))%" })
            LabeledSlider(title: "Fade in", value: Binding(get: { item.fadeIn }, set: { v in vm.updateAudio(id: item.id) { $0.fadeIn = v } }),
                          range: 0...5, format: { String(format: "%.1fs", $0) })
            LabeledSlider(title: "Fade out", value: Binding(get: { item.fadeOut }, set: { v in vm.updateAudio(id: item.id) { $0.fadeOut = v } }),
                          range: 0...5, format: { String(format: "%.1fs", $0) })
            LabeledSlider(title: "Start in song", value: Binding(get: { item.sourceStart }, set: { v in
                vm.updateAudio(id: item.id) { $0.sourceStart = v; $0.duration = min(vm.duration - $0.start, $0.sourceDuration - v) }
            }), range: 0...max(0.1, item.sourceDuration - 1), format: { $0.timecode })
        }
    }

    private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.primary)
    }

    private func toggleRecording() {
        if recorder.isRecording {
            vm.pause()
            if let file = recorder.stop() {
                let item = AudioItem(kind: .voiceover, title: "Voice-over", fileName: file.name, sourceDuration: file.duration,
                                     duration: file.duration)
                vm.addAudio(item, at: recordStart)
            }
        } else {
            recordStart = vm.currentTime
            vm.togglePlay()
            Task { await recorder.start() }
        }
    }

    private func addSpeech() {
        let text = ttsText
        vm.runWork("Synthesizing speech") { vm, progress in
            let result = try await SpeechSynth().synthesize(text)
            progress(1)
            vm.addAudio(AudioItem(kind: .voiceover, title: "Narration", fileName: result.fileName,
                                  sourceDuration: result.duration, duration: result.duration))
        }
        ttsText = ""
        showTTS = false
    }
}
