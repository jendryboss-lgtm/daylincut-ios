import AVFoundation
import Photos
import SwiftUI
import UIKit

// MARK: - Filters / albums

enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", videos = "Videos", photos = "Photos", livePhotos = "Live Photos"
    var id: String { rawValue }
}

struct MediaAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let collection: PHAssetCollection?
}

// MARK: - MediaLibraryService

/// Wraps PhotoKit: authorisation, albums, fetching, thumbnails and importing assets
/// into the app's `MediaStore` as edit-ready video files.
@MainActor
@Observable
final class MediaLibraryService {

    var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var albums: [MediaAlbum] = []

    let imageManager = PHCachingImageManager()

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { loadAlbums() }
    }

    func loadAlbums() {
        var result: [MediaAlbum] = []
        let recents = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject
        result.append(MediaAlbum(id: "recents", title: "Recents", count: PHAsset.fetchAssets(with: nil).count, collection: recents))
        let smart: [PHAssetCollectionSubtype] = [.smartAlbumFavorites, .smartAlbumVideos, .smartAlbumLivePhotos, .smartAlbumSelfPortraits, .smartAlbumSlomoVideos, .smartAlbumScreenshots]
        for subtype in smart {
            if let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject {
                let count = PHAsset.fetchAssets(in: c, options: nil).count
                if count > 0 { result.append(MediaAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: count, collection: c)) }
            }
        }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { c, _, _ in
            let count = PHAsset.fetchAssets(in: c, options: nil).count
            if count > 0 { result.append(MediaAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: count, collection: c)) }
        }
        albums = result
    }

    func fetchAssets(album: MediaAlbum?, filter: MediaFilter) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch filter {
        case .all:
            options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .livePhotos:
            options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
        }
        if let collection = album?.collection, album?.id != "recents" {
            return PHAsset.fetchAssets(in: collection, options: options)
        }
        return PHAsset.fetchAssets(with: options)
    }

    func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || image == nil {
                    if !resumed { resumed = true; continuation.resume(returning: image) }
                }
            }
        }
    }

    // MARK: Import

    struct ImportedMedia: Sendable {
        var fileName: String
        var kind: MediaKind
        var info: MediaInfo
    }

    /// Imports a set of assets in order, reporting overall progress 0...1.
    func importAssets(_ assets: [PHAsset], progress: @escaping @MainActor (Double) -> Void) async throws -> [Clip] {
        var clips: [Clip] = []
        for (i, asset) in assets.enumerated() {
            try Task.checkCancellation()
            let base = Double(i) / Double(assets.count)
            let span = 1.0 / Double(assets.count)
            let imported = try await Self.importAsset(asset) { p in
                Task { @MainActor in progress(base + span * p) }
            }
            var clip = Clip(mediaKind: imported.kind,
                            fileName: imported.fileName,
                            sourceDuration: imported.info.duration,
                            hasAudio: imported.info.hasAudio,
                            displayWidth: Double(imported.info.displaySize.width),
                            displayHeight: Double(imported.info.displaySize.height))
            if imported.kind == .photo {
                // Photos default to 3 s like CapCut; the full 10 s still is available via trim.
                clip.sourceEnd = min(3, clip.sourceDuration)
            }
            clips.append(clip)
            progress(base + span)
        }
        progress(1)
        return clips
    }

    nonisolated static func importAsset(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedMedia {
        switch asset.mediaType {
        case .video:
            let name = try await importVideo(asset, progress: progress)
            let info = try await MediaProbe.probe(MediaStore.url(for: name))
            return ImportedMedia(fileName: name, kind: .video, info: info)
        case .image:
            if asset.mediaSubtypes.contains(.photoLive), let name = try? await importLivePhotoVideo(asset) {
                let info = try await MediaProbe.probe(MediaStore.url(for: name))
                progress(1)
                return ImportedMedia(fileName: name, kind: .video, info: info)
            }
            let image = try await loadImage(asset, progress: progress)
            let still = try await FrameVideoWriter.stillVideo(from: image)
            let info = try await MediaProbe.probe(MediaStore.url(for: still.fileName))
            return ImportedMedia(fileName: still.fileName, kind: .photo, info: info)
        default:
            throw VideoEngineError.unreadableMedia("Unsupported asset")
        }
    }

    nonisolated private static func importVideo(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { p, _, _, _ in progress(p * 0.8) }
        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let error = info?[PHImageErrorKey] as? Error ?? VideoEngineError.unreadableMedia("iCloud video")
                    continuation.resume(throwing: error)
                }
            }
        }
        if let urlAsset = avAsset as? AVURLAsset {
            let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension.lowercased()
            let target = MediaStore.newFile(extension: ext)
            try FileManager.default.copyItem(at: urlAsset.url, to: target.url)
            progress(1)
            return target.name
        }
        // Slow-mo and edited videos arrive as compositions: render them to a file.
        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoEngineError.unreadableMedia("Export session")
        }
        let target = MediaStore.newFile(extension: "mov")
        session.outputURL = target.url
        session.outputFileType = .mov
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error ?? VideoEngineError.writerFailed("Export"))
                }
            }
        }
        progress(1)
        return target.name
    }

    nonisolated private static func importLivePhotoVideo(_ asset: PHAsset) async throws -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let paired = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
            throw VideoEngineError.unreadableMedia("Live Photo video")
        }
        let target = MediaStore.newFile(extension: "mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: paired, toFile: target.url, options: options)
        return target.name
    }

    nonisolated static func loadImage(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> UIImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { p, _, _, _ in progress(p * 0.6) }
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data, let image = UIImage(data: data) {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? VideoEngineError.unreadableMedia("Photo"))
                }
            }
        }
    }

    // MARK: Saving

    nonisolated static func saveVideoToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw VideoEngineError.writerFailed("Photo library access was denied. Enable it in Settings to save videos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    nonisolated static func saveImageToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw VideoEngineError.writerFailed("Photo library access was denied.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}
