import Photos
import SwiftUI

/// CapCut-style picker: album dropdown, media-type tabs, numbered multi-select,
/// selected tray, "Pick for me", Next (n) / Add (n).
struct MediaPickerView: View {
    var mode: PickerMode = .videosAndPhotos
    var confirmTitle: String = "Next"
    var onCancel: () -> Void
    var onDone: ([PHAsset]) -> Void

    @Environment(MediaLibraryService.self) private var library
    @State private var filter: MediaFilter = .all
    @State private var album: MediaAlbum?
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selection: [PHAsset] = []
    @State private var showAlbums = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    private var allowsMultiple: Bool { mode == .videosAndPhotos }
    private var filters: [MediaFilter] { mode == .photosOnly ? [.photos, .livePhotos] : MediaFilter.allCases }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterTabs
                content
                if allowsMultiple && !selection.isEmpty { tray }
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onCancel() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .principal) { albumMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    if allowsMultiple {
                        Button("Pick for me") { pickForMe() }
                            .font(.subheadline.weight(.semibold))
                            .disabled(assets == nil)
                    }
                }
            }
        }
        .task {
            if mode == .photosOnly { filter = .photos }
            if !library.isAuthorized { await library.requestAccess() } else { library.loadAlbums() }
            album = library.albums.first
            reload()
        }
        .onChange(of: filter) { reload() }
        .onChange(of: album) { reload() }
    }

    // MARK: Pieces

    private var albumMenu: some View {
        Menu {
            ForEach(library.albums) { a in
                Button { album = a } label: {
                    Text("\(a.title) (\(a.count))")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(album?.title ?? "Recents").font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Album: \(album?.title ?? "Recents")")
    }

    private var filterTabs: some View {
        HStack(spacing: 22) {
            ForEach(filters) { f in
                Button { filter = f } label: {
                    VStack(spacing: 6) {
                        Text(f.rawValue)
                            .font(.subheadline.weight(filter == f ? .bold : .regular))
                            .foregroundStyle(filter == f ? .primary : .secondary)
                        Capsule().fill(filter == f ? Color.primary : .clear).frame(width: 18, height: 3)
                    }
                }
                .accessibilityAddTraits(filter == f ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if library.authorization == .denied || library.authorization == .restricted {
            ContentUnavailableView {
                Label("No access to Photos", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Allow Daylin Cut to access your photos and videos in Settings to start editing.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(PillButtonStyle())
            }
        } else if let assets, assets.count > 0 {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<assets.count, id: \.self) { index in
                        let asset = assets.object(at: index)
                        AssetCell(asset: asset,
                                  number: selection.firstIndex(of: asset).map { $0 + 1 },
                                  showsNumber: allowsMultiple)
                            .onTapGesture { toggle(asset) }
                    }
                }
            }
        } else if assets == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Nothing here", systemImage: "photo.on.rectangle",
                                   description: Text("No \(filter.rawValue.lowercased()) in this album."))
        }
    }

    private var tray: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(selection.enumerated()), id: \.element.localIdentifier) { i, asset in
                        AssetThumb(asset: asset)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topTrailing) {
                                Button { selection.remove(at: i) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 6, y: -6)
                                .accessibilityLabel("Remove item \(i + 1)")
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            HStack {
                Text(selectionSummary).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("\(confirmTitle) (\(selection.count))") { onDone(selection) }
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var selectionSummary: String {
        let seconds = selection.reduce(0.0) { $0 + ($1.mediaType == .video ? $1.duration : 3) }
        return "\(selection.count) selected · \(seconds.timecode)"
    }

    // MARK: Actions

    private func reload() {
        guard library.isAuthorized else { return }
        assets = library.fetchAssets(album: album, filter: filter)
    }

    private func toggle(_ asset: PHAsset) {
        if !allowsMultiple {
            onDone([asset])
            return
        }
        if let i = selection.firstIndex(of: asset) {
            selection.remove(at: i)
        } else {
            selection.append(asset)
        }
    }

    /// Picks a varied set of recent, usable media: prefers 2–60 s videos and
    /// spreads picks across the library instead of the first N.
    private func pickForMe() {
        let all = library.fetchAssets(album: album, filter: .all)
        var candidates: [PHAsset] = []
        all.enumerateObjects { asset, index, stop in
            if index > 300 { stop.pointee = true; return }
            if asset.mediaType == .video ? (asset.duration >= 2 && asset.duration <= 60) : true {
                candidates.append(asset)
            }
        }
        guard !candidates.isEmpty else { return }
        let videos = candidates.filter { $0.mediaType == .video }
        let photos = candidates.filter { $0.mediaType == .image }
        var picks = Array(videos.prefix(40).shuffled().prefix(6))
        picks += photos.prefix(40).shuffled().prefix(max(2, 8 - picks.count))
        selection = picks.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }
}

// MARK: - Cells

private struct AssetCell: View {
    let asset: PHAsset
    let number: Int?
    let showsNumber: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { AssetThumb(asset: asset) }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(asset.duration.timecode)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.mediaSubtypes.contains(.photoLive) {
                    Image(systemName: "livephoto").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsNumber {
                    ZStack {
                        Circle().fill(number != nil ? Theme.accent : Color.black.opacity(0.25))
                        Circle().stroke(.white, lineWidth: 1.5)
                        if let number { Text("\(number)").font(.caption2.weight(.bold)).foregroundStyle(.black) }
                    }
                    .frame(width: 22, height: 22)
                    .padding(5)
                }
            }
            .overlay {
                if number != nil { Rectangle().stroke(Theme.accent, lineWidth: 2) }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(number != nil ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        let kind = asset.mediaType == .video ? "Video, \(asset.duration.timecode)" : (asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "Photo")
        if let number { return "\(kind), selected number \(number)" }
        return kind
    }
}

struct AssetThumb: View {
    let asset: PHAsset
    @Environment(MediaLibraryService.self) private var library
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.surface)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: asset.localIdentifier) {
            image = await library.thumbnail(for: asset, size: CGSize(width: 240, height: 240))
        }
    }
}
