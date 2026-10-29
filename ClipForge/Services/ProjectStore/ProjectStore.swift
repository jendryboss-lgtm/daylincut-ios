import Foundation
import SwiftData
import UIKit

// MARK: - ProjectStore

/// Thin helper around SwiftData for saving projects and their thumbnails.
@MainActor
enum ProjectStore {

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: Project.self, configurations: config)
        } catch {
            // A corrupt store should never brick the app: fall back to memory.
            return try! ModelContainer(for: Project.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    @discardableResult
    static func create(_ timeline: Timeline, name: String? = nil, in context: ModelContext) -> Project {
        let project = Project(name: name ?? Project.defaultName(), timeline: timeline)
        context.insert(project)
        try? context.save()
        Task { await updateThumbnail(project, context: context) }
        return project
    }

    static func save(_ timeline: Timeline, to project: Project, in context: ModelContext) {
        project.timeline = timeline
        project.updatedAt = .now
        try? context.save()
    }

    static func updateThumbnail(_ project: Project, context: ModelContext) async {
        let timeline = project.timeline
        guard let first = timeline.clips.first else { return }
        let time = first.sourceStart + min(0.5, first.trimmedDuration / 2)
        if let cg = await VideoEngine.thumbnail(fileName: first.fileName, at: time, maxSize: CGSize(width: 480, height: 480)) {
            project.thumbnailData = UIImage(cgImage: cg).jpegData(compressionQuality: 0.75)
            try? context.save()
        }
    }

    static func duplicate(_ project: Project, in context: ModelContext) {
        let copy = Project(name: project.name + " copy", timeline: project.timeline)
        copy.thumbnailData = project.thumbnailData
        context.insert(copy)
        try? context.save()
    }

    static func delete(_ project: Project, in context: ModelContext) {
        context.delete(project)
        try? context.save()
        collectGarbage(context: context)
    }

    /// Deletes media files that no project references any more.
    static func collectGarbage(context: ModelContext) {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        var referenced = Set<String>()
        for p in projects { referenced.formUnion(p.timeline.referencedFiles) }
        MediaStore.garbageCollect(keeping: referenced)
    }
}
