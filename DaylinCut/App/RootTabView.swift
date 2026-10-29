import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases

    var body: some View {
        @Bindable var router = router
        @Bindable var purchases = purchases
        TabView(selection: $router.selectedTab) {
            HomeView()
                .tabItem { Label("Edit", systemImage: "scissors") }
                .tag(AppTab.edit)
            TemplatesView()
                .tabItem { Label("Templates", systemImage: "square.grid.2x2") }
                .tag(AppTab.templates)
            AILabView()
                .tabItem { Label("AI Lab", systemImage: "sparkles") }
                .tag(AppTab.aiLab)
                .badge(router.aiLabBadge ? Text("New") : nil)
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(AppTab.projects)
            MeView()
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
                .tag(AppTab.me)
        }
        .onChange(of: router.selectedTab) { _, tab in
            if tab == .aiLab { router.aiLabBadge = false }
        }
        .fullScreenCover(isPresented: Binding(get: { router.flow != nil }, set: { if !$0 { router.dismissFlow() } })) {
            CreationFlowView()
                .environment(router)
                .environment(purchases)
        }
        // The paywall can be requested from any depth (editor, export sheet,
        // panels), so it is presented from the top-most view controller.
        .onChange(of: purchases.isPaywallPresented) { _, shown in
            if shown { PaywallPresenter.shared.present(purchases: purchases) } else { PaywallPresenter.shared.dismiss() }
        }
    }
}

// MARK: - Creation flow

struct CreationFlowView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if let flow = router.flow {
                switch flow.stage {
                case .picking:
                    MediaPickerView(mode: router.pickerMode,
                                    onCancel: { router.dismissFlow() },
                                    onDone: { assets in
                                        router.flow?.stage = .compiling(assets.map { PHAssetBox(asset: $0) })
                                    })
                case .compiling(let boxes):
                    CompilingView(assets: boxes.map(\.asset), intent: flow.intent) { outcome in
                        switch outcome {
                        case .project(let project):
                            router.flow?.stage = .editing(project, router.launchAction == .autoCut && isTemplate(flow.intent) ? .none : router.launchAction)
                        case .photo(let image):
                            router.flow?.stage = .photo(image, photoOperation(for: flow.intent))
                        case .cancelled:
                            router.flow?.stage = .picking
                        }
                    }
                case .editing(let project, let action):
                    EditorView(project: project, launchAction: action)
                        .id(project.id)
                case .photo(let image, let op):
                    PhotoEditorView(image: image, initialOperation: op, isCoverMaker: flow.intent == .tool(.coverMaker))
                case .camera:
                    CameraCaptureView { url in
                        guard let url else { router.dismissFlow(); return }
                        Task { await importRecording(url) }
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    private func isTemplate(_ intent: CreationIntent) -> Bool {
        if case .template = intent { return true }
        return false
    }

    private func photoOperation(for intent: CreationIntent) -> PhotoOperation? {
        switch intent {
        case .editPhoto(let op): return op
        case .tool(let tool): return tool.photoOperation
        default: return nil
        }
    }

    private func importRecording(_ url: URL) async {
        do {
            let name = try MediaStore.importFile(at: url)
            let clip = try await MediaProbe.clip(fileName: name, kind: .video)
            let project = ProjectStore.create(Timeline(clips: [clip]), in: context)
            router.flow?.stage = .editing(project, .none)
        } catch {
            router.dismissFlow()
        }
    }
}
