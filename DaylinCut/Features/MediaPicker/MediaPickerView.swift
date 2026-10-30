import AVKit
import Photos
import SwiftUI

/// CapCut-style picker. New video: centered "Recents ⌄", All/Videos/Photos/Live
/// Photos tabs, numbered teal selection, "Pick for me" + Next, then a
/// "What do you want to create?" prompt and a selection tray. Add media:
/// "Camera roll ⌄ | Library" header and "Add (n)".
struct MediaPickerView: View {
    var mode: PickerMode = .videosAndPhotos
    var confirmTitle: String = "Next"
    var onCancel: () -> Void
    var onDone: ([PHAsset]) -> Void
    /// When set, the picker shows the prompt field and passes its text along.
    var onCreate: (([PHAsset], String) -> Void)?

    @Environment(MediaLibraryService.self) private var library
    @State private var filter: MediaFilter = .videos
    @State private var album: MediaAlbum?
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selection: [PHAsset] = []
    @State private var prompt = ""
    @State private var previewAsset: PHAssetBox?
    @State private var source: Source = .cameraRoll
    @FocusState private var promptFocused: Bool

    enum Source { case cameraRoll, library }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var allowsMultiple: Bool { mode == .videosAndPhotos }
    private var isAddMode: Bool { confirmTitle != "Next" }
    private var filters: [MediaFilter] {
        if mode == .photosOnly { return [.photos, .livePhotos] }
        return isAddMode ? [.videos, .photos, .livePhotos] : MediaFilter.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if source == .cameraRoll {
                filterTabs
                content
            } else {
                StockLibraryView { asset in
                    source = .cameraRoll
                    if !allowsMultiple { onDone([asset]); return }
                    if !selection.contains(asset) { selection.append(asset) }
                    reload()
                }
            }
            bottomBar
        }
        .background(Theme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            if mode == .photosOnly { filter = .photos }
            library.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if library.isAuthorized {
                library.loadAlbums()
            } else if UIScreenHarness.isScreenshotRun {
                // Screenshot runs must never raise the system Photos prompt.
                source = .library
            } else {
                await library.requestAccess()
            }
            album = library.albums.first
            reload()
        }
        .onChange(of: filter) { reload() }
        .onChange(of: album) { reload() }
        .fullScreenCover(item: $previewAsset) { box in
            AssetPreview(asset: box.asset)
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            if isAddMode {
                HStack(spacing: 22) {
                    closeButton
                    Button { source = .cameraRoll } label: {
                        albumLabel(title: "Camera roll", selected: source == .cameraRoll)
                    }
                    .overlay { if source == .cameraRoll { albumMenuOverlay } }
                    Button { source = .library } label: {
                        Text("Library")
                            .font(.system(size: 16, weight: source == .library ? .semibold : .regular))
                            .foregroundStyle(source == .library ? .white : Theme.mutedText)
                    }
                    Spacer()
                }
            } else {
                Menu { albumButtons } label: { albumLabel(title: album?.title ?? "Recents", selected: false, centered: true) }
                    .accessibilityLabel("Album: \(album?.title ?? "Recents")")
                HStack { closeButton; Spacer() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }

    private var closeButton: some View {
        Button { onCancel() } label: {
            Image(systemName: "xmark").font(.system(size: 20, weight: .regular)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private var albumButtons: some View {
        ForEach(library.albums) { a in
            Button { album = a } label: { Text("\(a.title) (\(a.count))") }
        }
    }

    private var albumMenuOverlay: some View {
        Menu { albumButtons } label: { Color.clear.contentShape(Rectangle()) }
            .accessibilityLabel("Album: \(album?.title ?? "Camera roll")")
    }

    private func albumLabel(title: String, selected: Bool, centered: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 16, weight: centered ? .regular : .semibold))
                .foregroundStyle(centered ? Theme.mutedText : (selected ? .white : Theme.mutedText))
            Image(systemName: centered ? "chevron.down" : "chevron.down.square.fill")
                .font(.system(size: centered ? 12 : 14, weight: .semibold))
                .foregroundStyle(centered ? Theme.mutedText : .white)
        }
    }

    private var filterTabs: some View {
        HStack(spacing: 0) {
            ForEach(filters) { f in
                Button { filter = f } label: {
                    VStack(spacing: 8) {
                        Text(f.rawValue)
                            .font(.system(size: 16, weight: filter == f ? .semibold : .regular))
                            .foregroundStyle(filter == f ? (isAddMode ? Theme.accent : .white) : Theme.mutedText)
                        Capsule().fill(filter == f ? (isAddMode ? Theme.accent : Color.white) : .clear)
                            .frame(width: isAddMode ? 30 : 80, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityAddTraits(filter == f ? .isSelected : [])
            }
        }
        .padding(.top, 14)
    }

    // MARK: Grid

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
            .frame(maxHeight: .infinity)
        } else if let assets, assets.count > 0 {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<assets.count, id: \.self) { index in
                        let asset = assets.object(at: index)
                        AssetCell(asset: asset,
                                  number: selection.firstIndex(of: asset).map { $0 + 1 },
                                  showsNumber: allowsMultiple,
                                  onExpand: { previewAsset = PHAssetBox(asset: asset) })
                            .onTapGesture { toggle(asset) }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        } else if assets == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Nothing here", systemImage: "photo.on.rectangle",
                                   description: Text("No \(filter.rawValue.lowercased()) in this album."))
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomBar: some View {
        if isAddMode {
            VStack(spacing: 0) {
                if !selection.isEmpty {
                    HStack(alignment: .bottom) {
                        trayItems
                        Spacer()
                        Button("\(confirmTitle) (\(selection.count))") { onDone(selection) }
                            .buttonStyle(TealButtonStyle())
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                Theme.hairline.frame(height: 0.5)
                VStack(spacing: 6) {
                    Label("Add media", systemImage: "photo.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                    Capsule().fill(Theme.accent).frame(width: 30, height: 2)
                }
                .foregroundStyle(.white)
                .padding(.top, 14).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            }
            .background(Theme.canvas)
        } else if !allowsMultiple {
            EmptyView()
        } else if selection.isEmpty {
            HStack(spacing: 14) {
                Spacer()
                Button("Pick for me") { pickForMe() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(assets == nil)
                Button("Next") {}
                    .buttonStyle(TealButtonStyle())
                    .disabled(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.canvas)
        } else {
            VStack(spacing: 14) {
                if onCreate != nil {
                    TextField("", text: $prompt, prompt: Text("What do you want to create?").foregroundStyle(Theme.mutedText), axis: .vertical)
                        .lineLimit(1...3)
                        .focused($promptFocused)
                        .font(.system(size: 17))
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.done)
                        .accessibilityLabel("What do you want to create?")
                }
                HStack(alignment: .bottom) {
                    trayItems
                    Spacer()
                    Button("\(confirmTitle) (\(selection.count))") { confirm() }
                        .buttonStyle(TealButtonStyle())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.panel)
        }
    }

    private var trayItems: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(selection.enumerated()), id: \.element.localIdentifier) { i, asset in
                    AssetThumb(asset: asset)
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomLeading) {
                            if asset.mediaType == .video {
                                Text(asset.duration.timecode)
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white).shadow(radius: 2).padding(4)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { selection.remove(at: i) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.black, .white)
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove item \(i + 1)")
                        }
                }
            }
            .padding(.top, 8).padding(.trailing, 8)
        }
        .frame(maxWidth: 240, alignment: .leading)
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

    private func confirm() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onCreate { onCreate(selection, text) } else { onDone(selection) }
    }

    /// Picks a varied, recent set (see `PickForMe.select`).
    private func pickForMe() {
        let all = library.fetchAssets(album: album, filter: .all)
        var byID: [String: PHAsset] = [:]
        var candidates: [PickForMe.Candidate] = []
        all.enumerateObjects { asset, index, stop in
            if index >= 400 { stop.pointee = true; return }
            byID[asset.localIdentifier] = asset
            candidates.append(.init(id: asset.localIdentifier, isVideo: asset.mediaType == .video,
                                    duration: asset.duration, date: asset.creationDate ?? .distantPast))
        }
        let ids = PickForMe.select(from: candidates)
        selection = ids.compactMap { byID[$0] }
        // Photos were topped up: show them in the grid too.
        if filter == .videos && selection.contains(where: { $0.mediaType != .video }) { filter = .all }
    }
}

/// Teal rounded button used for Next / Add / Export.
struct TealButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.35))
            .padding(.horizontal, 18)
            .frame(minWidth: 92, minHeight: 40)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Cells

private struct AssetCell: View {
    let asset: PHAsset
    let number: Int?
    let showsNumber: Bool
    var onExpand: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(0.8, contentMode: .fit)
            .overlay { AssetThumb(asset: asset) }
            .clipped()
            .overlay { if number != nil { Theme.accent.opacity(0.35) } }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(asset.duration.timecode)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Preview")
            }
            .overlay(alignment: .topTrailing) {
                if showsNumber {
                    ZStack {
                        Circle().fill(number != nil ? Theme.accent : Color.black.opacity(0.15))
                        if number == nil { Circle().stroke(.white, lineWidth: 1.5) }
                        if let number { Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
                    }
                    .frame(width: 22, height: 22)
                    .padding(7)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
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
            Rectangle().fill(Theme.chip)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: asset.localIdentifier) {
            image = await library.thumbnail(for: asset, size: CGSize(width: 300, height: 300))
        }
    }
}

// MARK: - Expanded preview

private struct AssetPreview: View {
    let asset: PHAsset
    @Environment(MediaLibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { player?.pause(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close preview")
            .padding(.leading, 8)
        }
        .task {
            if asset.mediaType == .video {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .automatic
                let item: AVPlayerItem? = await withCheckedContinuation { cont in
                    PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                        cont.resume(returning: item)
                    }
                }
                if let item {
                    let p = AVPlayer(playerItem: item)
                    player = p
                    p.play()
                }
            } else {
                image = await library.thumbnail(for: asset, size: CGSize(width: 1600, height: 1600))
            }
        }
    }
}

// MARK: - Library (stock clips)

/// "Library" tab in Add media: renders a stock clip from a prompt with the
/// on-device generator, saves it to Photos and adds it to the selection.
private struct StockLibraryView: View {
    var onAdd: (PHAsset) -> Void
    @State private var working: String?
    @State private var progress: Double = 0
    @State private var error: String?

    static let presets: [(title: String, symbol: String)] = [
        ("Sunset gradient", "sun.horizon"), ("Ocean waves", "water.waves"), ("City lights", "building.2"),
        ("Neon glow", "sparkles"), ("Forest calm", "leaf"), ("Snowfall", "snowflake"),
        ("Fireworks", "fireworks"), ("Countdown 3 2 1", "timer"), ("Clouds drifting", "cloud")
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Self.presets, id: \.title) { preset in
                    Button { Task { await make(preset.title) } } label: {
                        VStack(spacing: 8) {
                            Image(systemName: preset.symbol).font(.system(size: 26))
                            Text(preset.title).font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(2)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            if working == preset.title {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.6))
                                    Text("\(Int(progress * 100))%").font(.headline.monospacedDigit())
                                }
                            }
                        }
                    }
                    .disabled(working != nil)
                }
            }
            .padding(14)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            Text("Stock clips are rendered on-device (4 s, 9:16) and saved to your Photos.")
                .font(.footnote).foregroundStyle(Theme.mutedText).padding(.horizontal, 14)
        }
        .frame(maxHeight: .infinity)
    }

    private func make(_ title: String) async {
        working = title
        progress = 0
        error = nil
        defer { working = nil }
        do {
            let clip = try await AIServiceProvider.current.generateVideo(prompt: title, duration: 4, aspect: .portrait9x16) { p in
                Task { @MainActor in progress = p }
            }
            let id = try await MediaLibraryService.saveVideoToPhotosReturningIdentifier(MediaStore.url(for: clip.fileName))
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                onAdd(asset)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
