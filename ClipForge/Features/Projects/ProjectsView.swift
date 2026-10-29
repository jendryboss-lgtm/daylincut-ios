import SwiftData
import SwiftUI

/// All SwiftData projects: search, sort, open, rename, duplicate, delete.
struct ProjectsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Last edited", name = "Name", duration = "Duration"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var sort: Sort = .recent
    @State private var renaming: Project?
    @State private var newName = ""
    @State private var deleting: Project?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var visible: [Project] {
        let filtered = search.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .recent: return filtered
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration: return filtered.sorted { $0.duration > $1.duration }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "film.stack")
                    } description: {
                        Text("Videos you edit are saved here automatically.")
                    } actions: {
                        Button("New video") { router.start(.newVideo) }.buttonStyle(PillButtonStyle())
                    }
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ScrollView {
                        Text("\(projects.count) project\(projects.count == 1 ? "" : "s")")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(visible) { project in
                                Button { router.open(project) } label: { ProjectThumbnail(project: project) }
                                    .buttonStyle(.plain)
                                    .contextMenu { menu(for: project) }
                                    .accessibilityAction(named: "Rename") { beginRename(project) }
                                    .accessibilityAction(named: "Duplicate") { ProjectStore.duplicate(project, in: context) }
                                    .accessibilityAction(named: "Delete") { deleting = project }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Projects")
            .searchable(text: $search, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel("Sort projects")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.start(.newVideo) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New video")
                }
            }
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let project = renaming, !trimmed.isEmpty {
                        project.name = trimmed
                        project.updatedAt = .now
                        try? context.save()
                    }
                    renaming = nil
                }
            }
            .confirmationDialog("Delete this project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let project = deleting { ProjectStore.delete(project, in: context) }
                    deleting = nil
                }
            } message: {
                Text("Media that no other project uses will be removed from ClipForge. Your Photos library is not affected.")
            }
        }
    }

    @ViewBuilder
    private func menu(for project: Project) -> some View {
        Button { router.open(project) } label: { Label("Open", systemImage: "play.rectangle") }
        Button { beginRename(project) } label: { Label("Rename", systemImage: "pencil") }
        Button { ProjectStore.duplicate(project, in: context) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { deleting = project } label: { Label("Delete", systemImage: "trash") }
    }

    private func beginRename(_ project: Project) {
        newName = project.name
        renaming = project
    }
}
