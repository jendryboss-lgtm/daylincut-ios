import SwiftData
import SwiftUI

@main
struct ClipForgeApp: App {
    @State private var purchases = PurchaseManager()
    @State private var router = AppRouter()
    @State private var library = MediaLibraryService()
    @AppStorage("appearance") private var appearance: Appearance = .dark
    private let container = ProjectStore.makeContainer(inMemory: ProcessInfo.processInfo.arguments.contains("-uiTesting"))

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(purchases)
                .environment(router)
                .environment(library)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
