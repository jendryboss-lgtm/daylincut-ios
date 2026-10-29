import AVFoundation
import Foundation

// MARK: - MediaStore

/// App-owned media files referenced by projects (imported clips, generated media,
/// voice-overs). Lives in Application Support so it is backed up but not user-visible.
enum MediaStore {

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }()

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// A unique, not-yet-existing file in the store.
    static func newFile(extension ext: String) -> (name: String, url: URL) {
        let name = "\(UUID().uuidString).\(ext)"
        return (name, url(for: name))
    }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    /// Copies an external file into the store and returns its new name.
    static func importFile(at source: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let target = newFile(extension: ext)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: target.url)
        return target.name
    }

    /// Deletes files not referenced by any project.
    static func garbageCollect(keeping referenced: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: url(for: file))
        }
    }

    static var temporaryDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func temporaryFile(extension ext: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
}

// MARK: - MediaProbe

struct MediaInfo: Hashable, Sendable {
    var duration: Double
    var hasVideo: Bool
    var hasAudio: Bool
    var displaySize: CGSize
    var nominalFrameRate: Float
}

enum MediaProbe {
    static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize(width: 1080, height: 1920)
        var fps: Float = 30
        if let track = videoTracks.first {
            let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(rect.width), height: abs(rect.height))
            fps = rate > 0 ? rate : 30
        }
        return MediaInfo(duration: duration.isFinite ? duration : 0,
                         hasVideo: !videoTracks.isEmpty,
                         hasAudio: !audioTracks.isEmpty,
                         displaySize: size,
                         nominalFrameRate: fps)
    }

    /// Builds a clip for a file already in the `MediaStore`.
    static func clip(fileName: String, kind: MediaKind) async throws -> Clip {
        let info = try await probe(MediaStore.url(for: fileName))
        guard info.hasVideo, info.duration > 0 else { throw VideoEngineError.unreadableMedia(fileName) }
        return Clip(mediaKind: kind, fileName: fileName, sourceDuration: info.duration,
                    hasAudio: info.hasAudio,
                    displayWidth: Double(info.displaySize.width), displayHeight: Double(info.displaySize.height))
    }
}
