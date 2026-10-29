import Photos
import SwiftData
import SwiftUI

/// "Compiling your footage... X%" — real progress of importing assets (iCloud
/// download, Live Photo extraction, still-to-video conversion) and template AutoCut.
struct CompilingView: View {
    enum Outcome {
        case project(Project)
        case photo(UIImage)
        case cancelled
    }

    let assets: [PHAsset]
    let intent: CreationIntent
    var onFinish: (Outcome) -> Void

    @Environment(MediaLibraryService.self) private var library
    @Environment(\.modelContext) private var context
    @State private var progress: Double = 0
    @State private var stage = "Compiling your footage..."
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var isPhotoIntent: Bool {
        switch intent {
        case .editPhoto: return true
        case .tool(let tool): return tool.pickerMode == .photosOnly
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.surface, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.title2.monospacedDigit().weight(.bold))
            }
            .frame(width: 120, height: 120)
            .accessibilityElement()
            .accessibilityLabel(stage)
            .accessibilityValue("\(Int(progress * 100)) percent")

            Text("\(stage) \(Int(progress * 100))%")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Keep ClipForge open while we prepare your media.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                HStack {
                    Button("Back") { onFinish(.cancelled) }.buttonStyle(PillButtonStyle(filled: false))
                    Button("Try again") { start() }.buttonStyle(PillButtonStyle())
                }
            }
            Spacer()
            Button("Cancel") {
                task?.cancel()
                onFinish(.cancelled)
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        error = nil
        progress = 0
        task?.cancel()
        task = Task { await run() }
    }

    private func run() async {
        do {
            if isPhotoIntent, let asset = assets.first {
                stage = "Loading photo..."
                let image = try await MediaLibraryService.loadImage(asset) { p in
                    Task { @MainActor in progress = p }
                }
                progress = 1
                onFinish(.photo(image))
                return
            }
            let importShare = isTemplate ? 0.6 : 1.0
            stage = "Compiling your footage..."
            let clips = try await library.importAssets(assets) { p in progress = p * importShare }
            var timeline = Timeline(clips: clips)
            if let first = clips.first, first.displayWidth > first.displayHeight * 1.2 { timeline.aspectRatio = .landscape16x9 }
            var name: String?
            if case .template(let template) = intent {
                stage = "Applying \(template.title)..."
                let outcome = try await AutoCutEngine.run(on: timeline, settings: template.settings) { p, _ in
                    Task { @MainActor in progress = importShare + (1 - importShare) * p }
                }
                timeline = template.decorate(outcome.timeline)
                name = template.title
            }
            try Task.checkCancellation()
            progress = 1
            let project = ProjectStore.create(timeline, name: name, in: context)
            onFinish(.project(project))
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var isTemplate: Bool {
        if case .template = intent { return true }
        return false
    }
}
