import SwiftData
import SwiftUI

enum AILabTool: String, CaseIterable, Identifiable, Hashable {
    case generateVideo, storyMaker, avatar, extendVideo, photoEditor, removeBackground

    var id: String { rawValue }
    var title: String {
        switch self {
        case .generateVideo: return "Text to video"
        case .storyMaker: return "AI story maker"
        case .avatar: return "AI avatar"
        case .extendVideo: return "Extend video"
        case .photoEditor: return "AI photo editor"
        case .removeBackground: return "Remove background"
        }
    }
    var subtitle: String {
        switch self {
        case .generateVideo: return "Describe a scene and get a clip"
        case .storyMaker: return "Turn an idea into a narrated story"
        case .avatar: return "A presenter that reads your script"
        case .extendVideo: return "Add seconds to the end of a clip"
        case .photoEditor: return "Styles, retouch and enhance"
        case .removeBackground: return "Cut out people with Vision"
        }
    }
    var symbol: String {
        switch self {
        case .generateVideo: return "sparkles.tv"
        case .storyMaker: return "book.pages"
        case .avatar: return "person.crop.circle.badge.checkmark"
        case .extendVideo: return "arrow.right.to.line.compact"
        case .photoEditor: return "photo.badge.plus"
        case .removeBackground: return "person.crop.rectangle.badge.minus"
        }
    }
    var colors: [String] {
        switch self {
        case .generateVideo: return ["#8E54E9", "#4776E6"]
        case .storyMaker: return ["#FF512F", "#DD2476"]
        case .avatar: return ["#11998E", "#38EF7D"]
        case .extendVideo: return ["#0F2027", "#2C5364"]
        case .photoEditor: return ["#F7971E", "#FFD200"]
        case .removeBackground: return ["#C33764", "#1D2671"]
        }
    }
    var isPro: Bool { self == .avatar || self == .storyMaker }
    /// Tools that produce a project from a prompt inside AI Lab.
    var isGenerator: Bool { self == .generateVideo || self == .storyMaker || self == .avatar }
}

struct AILabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases
    @State private var active: AILabTool?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Create with AI").font(.title3.weight(.bold))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AILabTool.allCases) { tool in
                            Button { open(tool) } label: { AILabCard(tool: tool, showPro: tool.isPro && !purchases.isPro) }
                                .buttonStyle(.plain)
                        }
                    }
                    AIDisclosure()
                }
                .padding(16)
            }
            .navigationTitle("AI Lab")
            .sheet(item: $active) { tool in
                AIGeneratorSheet(tool: tool)
            }
            .onAppear(perform: consumeRequest)
            .onChange(of: router.aiLabRequest) { _, _ in consumeRequest() }
        }
    }

    private func consumeRequest() {
        guard let request = router.aiLabRequest else { return }
        router.aiLabRequest = nil
        open(request)
    }

    private func open(_ tool: AILabTool) {
        if tool.isPro && !purchases.require(.advancedAI) { return }
        switch tool {
        case .extendVideo: router.start(.extendVideo)
        case .photoEditor: router.start(.editPhoto(nil))
        case .removeBackground: router.start(.tool(.remove))
        default: active = tool
        }
    }
}

private struct AILabCard: View {
    let tool: AILabTool
    let showPro: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: tool.symbol).font(.title2).foregroundStyle(.white)
                Spacer()
                if showPro { ProBadge() }
            }
            Spacer(minLength: 12)
            Text(tool.title).font(.headline).foregroundStyle(.white)
            Text(tool.subtitle).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .background(LinearGradient(colors: tool.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Prompt form + progress for the generator tools. On success the result is
/// saved as a new project and opened in the editor.
struct AIGeneratorSheet: View {
    let tool: AILabTool
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var duration: Double = 5
    @State private var aspect: AspectRatio = .portrait9x16
    @State private var narrate = true
    @State private var look: AvatarLook = .nova
    @State private var scenes: [StoryScene] = []
    @State private var running = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section(tool == .avatar ? "Script" : "Prompt") {
                    TextField(placeholder, text: $prompt, axis: .vertical).lineLimit(3...8)
                }
                Section("Format") {
                    Picker("Aspect ratio", selection: $aspect) {
                        ForEach([AspectRatio.portrait9x16, .landscape16x9, .square1x1, .portrait4x5]) { Text($0.title).tag($0) }
                    }
                    if tool == .generateVideo {
                        Picker("Length", selection: $duration) {
                            ForEach([3.0, 5, 8, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
                        }
                    }
                    if tool == .storyMaker { Toggle("Narration voice", isOn: $narrate) }
                    if tool == .avatar {
                        Picker("Look", selection: $look) {
                            ForEach(AvatarLook.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                if tool == .storyMaker && !scenes.isEmpty {
                    Section("Storyboard") {
                        ForEach(Array(scenes.enumerated()), id: \.element.id) { i, scene in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(i + 1). \(scene.title)").font(.subheadline.weight(.semibold))
                                Text(scene.narration).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    if running {
                        ProgressView(value: progress) { Text("Generating \(Int(progress * 100))%") }
                        Button("Cancel", role: .destructive) { job?.cancel(); running = false }
                    } else {
                        if tool == .storyMaker {
                            Button("Preview storyboard") { previewStoryboard() }.disabled(trimmed.isEmpty)
                        }
                        Button { generate() } label: { Label("Generate", systemImage: "sparkles") }
                            .disabled(trimmed.isEmpty)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                } footer: { AIDisclosure() }
            }
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { job?.cancel(); dismiss() } }
            }
            .interactiveDismissDisabled(running)
        }
    }

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placeholder: String {
        switch tool {
        case .avatar: return "Hi! Today I'll show you three quick editing tips…"
        case .storyMaker: return "A fox who learns to fly. Or paste a few sentences."
        default: return "A neon city at night with rain"
        }
    }

    private func previewStoryboard() {
        let text = trimmed
        Task {
            scenes = (try? await AIServiceProvider.current.storyboard(prompt: text, sceneCount: 4)) ?? []
        }
    }

    private func generate() {
        running = true
        progress = 0
        error = nil
        let service = AIServiceProvider.current
        let text = trimmed, aspect = aspect, duration = duration, narrate = narrate, look = look, tool = tool
        let report: @Sendable (Double) -> Void = { p in Task { @MainActor in progress = p } }
        job = Task {
            do {
                var timeline: Timeline
                switch tool {
                case .storyMaker:
                    timeline = try await service.makeStory(prompt: text, aspect: aspect, narrate: narrate, progress: report)
                case .avatar:
                    let clip = try await service.makeAvatar(script: text, look: look, aspect: aspect, progress: report)
                    timeline = Timeline(clips: [clip])
                default:
                    let clip = try await service.generateVideo(prompt: text, duration: duration, aspect: aspect, progress: report)
                    timeline = Timeline(clips: [clip])
                }
                try Task.checkCancellation()
                timeline.aspectRatio = aspect
                let project = ProjectStore.create(timeline, name: String(text.prefix(32)), in: context)
                running = false
                dismiss()
                await ProjectStore.updateThumbnail(project, context: context)
                // Let the sheet finish dismissing before presenting the editor.
                try? await Task.sleep(for: .milliseconds(450))
                router.open(project)
            } catch is CancellationError {
                running = false
            } catch {
                self.error = error.localizedDescription
                running = false
            }
        }
    }
}
