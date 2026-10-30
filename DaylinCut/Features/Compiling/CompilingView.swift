import Photos
import SwiftData
import SwiftUI

/// "Compiling your footage... X%" — real progress of importing assets (iCloud
/// download, Live Photo extraction, still-to-video conversion) and template AutoCut.
struct CompilingView: View {
    enum Outcome {
        /// The saved project and the footage as imported (before any AutoCut).
        case project(Project, Timeline)
        case photo(UIImage)
        case cancelled
    }

    let assets: [PHAsset]
    let intent: CreationIntent
    /// "What do you want to create?" text; when non-empty AutoCut runs with
    /// settings parsed from it (`AutoCutPromptParser`).
    var prompt: String = ""
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
        VStack(spacing: 0) {
            if intent == .newVideo {
                ReviewHeader(musicTitle: "", resolutionTitle: "1080P", enabled: false,
                             onBack: { task?.cancel(); onFinish(.cancelled) },
                             onMusic: {}, onResolution: {}, onExport: {})
            } else {
                HStack {
                    Button { task?.cancel(); onFinish(.cancelled) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 50)
            }
            Spacer()
            CompilingBadge()
            Text("\(stage) \(Int(progress * 100))%")
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .padding(.top, 22)
                .accessibilityLabel(stage)
                .accessibilityValue("\(Int(progress * 100)) percent")
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    .padding(.top, 10)
                HStack {
                    Button("Back") { onFinish(.cancelled) }.buttonStyle(PillButtonStyle(filled: false))
                    Button("Try again") { start() }.buttonStyle(PillButtonStyle())
                }
                .padding(.top, 8)
            }
            Spacer()
            if intent == .newVideo {
                LooksTray(tab: .constant(.forYou), selected: nil, editThumbnail: nil, editDuration: nil,
                          isLoading: true, isBookmarked: false, onBookmark: {}, onEdit: {}, onSelect: { _ in }, onRemix: {})
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let importShare = (isTemplate || !trimmedPrompt.isEmpty) ? 0.6 : 1.0
            stage = "Compiling your footage..."
            let clips = try await library.importAssets(assets) { p in progress = p * importShare }
            var timeline = Timeline(clips: clips)
            if let first = clips.first, first.displayWidth > first.displayHeight * 1.2 { timeline.aspectRatio = .landscape16x9 }
            let base = timeline
            var name: String?
            if !trimmedPrompt.isEmpty && !isTemplate {
                var defaults = AutoCutSettings()
                defaults.aspectRatio = timeline.aspectRatio
                let settings = AutoCutPromptParser.settings(for: trimmedPrompt, base: defaults)
                stage = "Creating \(settings.style.title.lowercased()) edit..."
                let outcome = try await AutoCutEngine.run(on: timeline, settings: settings) { p, _ in
                    Task { @MainActor in progress = importShare + (1 - importShare) * p }
                }
                timeline = outcome.timeline
                name = String(trimmedPrompt.prefix(40))
            }
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
            onFinish(.project(project, base))
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

/// Stacked-cards play icon with a sparkle, shown while compiling.
struct CompilingBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18))
                .frame(width: 52, height: 38).offset(x: 4, y: -7)
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.0, green: 0.82, blue: 0.95)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 62, height: 42)
                .overlay(Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.55)))
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 30, y: -24)
        }
        .frame(width: 80, height: 64)
        .accessibilityHidden(true)
    }
}
