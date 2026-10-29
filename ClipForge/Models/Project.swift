import Foundation
import SwiftData

// MARK: - Project (SwiftData)

/// Persistent project. The editable document lives in `timelineData` as JSON so
/// the timeline schema can evolve without SwiftData migrations.
@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var duration: Double
    var aspectRawValue: String
    var timelineData: Data
    @Attribute(.externalStorage) var thumbnailData: Data?

    init(name: String, timeline: Timeline = Timeline()) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.duration = timeline.duration
        self.aspectRawValue = timeline.aspectRatio.rawValue
        self.timelineData = (try? JSONEncoder().encode(timeline)) ?? Data()
        self.thumbnailData = nil
    }

    /// Decoded timeline. Setting it re-encodes and bumps `updatedAt`.
    var timeline: Timeline {
        get { (try? JSONDecoder().decode(Timeline.self, from: timelineData)) ?? Timeline() }
        set {
            timelineData = (try? JSONEncoder().encode(newValue)) ?? timelineData
            duration = newValue.duration
            aspectRawValue = newValue.aspectRatio.rawValue
            updatedAt = .now
        }
    }

    static func defaultName(date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd"
        return "Project \(f.string(from: date))-\(Int(date.timeIntervalSince1970) % 1000)"
    }
}
