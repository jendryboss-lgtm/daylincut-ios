import Observation
import Photos
import SwiftUI

// MARK: - Navigation model

enum AppTab: Hashable { case edit, templates, aiLab, projects, me }

/// What the editor should do right after it opens.
enum EditorLaunchAction: Hashable {
    case none, autoCut, captions, clipper, remove, enhance, text, extend
    /// Opens the export options panel (used by the review screen and UI screenshots).
    case exportOptions
    /// Opens the full export sheet without starting the export.
    case exportSheet
}

/// Which media the picker allows.
enum PickerMode: Hashable {
    case videosAndPhotos, photosOnly, single
}

enum CreationIntent: Hashable {
    case newVideo
    case extendVideo
    case editPhoto(PhotoOperation?)
    case tool(HomeTool)
    case template(TemplatePreset)
}

/// One full-screen creation flow: pick → compile → edit (or photo edit).
struct CreationFlow: Identifiable {
    enum Stage {
        case picking
        /// Assets plus the "What do you want to create?" prompt (may be empty).
        case compiling([PHAssetBox], String)
        /// CapCut's result screen: preview, looks tray, Export; `Timeline` is the
        /// footage as compiled, so looks can be re-applied from scratch.
        case review(Project, Timeline)
        case editing(Project, EditorLaunchAction)
        case photo(UIImage, PhotoOperation?)
        case camera
    }
    let id = UUID()
    var intent: CreationIntent
    var stage: Stage
}

/// Boxes PHAsset (a class) so stage enums stay simple.
struct PHAssetBox: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .edit
    var flow: CreationFlow?
    /// Badge shown on the AI Lab tab until it is visited.
    var aiLabBadge = true
    /// Set by Home tools that live in AI Lab (generator, story maker).
    var aiLabRequest: AILabTool?

    func start(_ intent: CreationIntent) {
        switch intent {
        case .tool(.shootAndRecord):
            flow = CreationFlow(intent: intent, stage: .camera)
        case .tool(.aiGenerator):
            aiLabRequest = .generateVideo
            selectedTab = .aiLab
        case .tool(.storyMaker):
            aiLabRequest = .storyMaker
            selectedTab = .aiLab
        default:
            flow = CreationFlow(intent: intent, stage: .picking)
        }
    }

    func open(_ project: Project, action: EditorLaunchAction = .none) {
        flow = CreationFlow(intent: .newVideo, stage: .editing(project, action))
    }

    func openGenerated(_ project: Project) {
        open(project)
    }

    func dismissFlow() { flow = nil }

    var pickerMode: PickerMode {
        guard let flow else { return .videosAndPhotos }
        switch flow.intent {
        case .editPhoto: return .photosOnly
        case .tool(let tool): return tool.pickerMode
        default: return .videosAndPhotos
        }
    }

    var launchAction: EditorLaunchAction {
        guard let flow else { return .none }
        switch flow.intent {
        case .tool(let tool): return tool.launchAction
        case .template: return .autoCut
        case .extendVideo: return .extend
        default: return .none
        }
    }
}

// MARK: - Home tools

enum HomeTool: String, CaseIterable, Identifiable, Hashable {
    case autoCut, retouch, aiGenerator, photoTools, storyMaker, shootAndRecord
    case autoEnhance, coverMaker, autoCaptions, aiClipper, remove, aiPhotoEditor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoCut: return "AutoCut"
        case .retouch: return "Retouch"
        case .aiGenerator: return "AI generator"
        case .photoTools: return "Photo tools"
        case .storyMaker: return "AI story maker"
        case .shootAndRecord: return "Shoot and record"
        case .autoEnhance: return "Auto enhance"
        case .coverMaker: return "Cover maker"
        case .autoCaptions: return "Auto captions"
        case .aiClipper: return "AI clipper"
        case .remove: return "Remove"
        case .aiPhotoEditor: return "AI photo editor"
        }
    }

    var symbol: String {
        switch self {
        case .autoCut: return "play.rectangle"
        case .retouch: return "face.dashed"
        case .aiGenerator: return "sparkles.rectangle.stack"
        case .photoTools: return "photo.badge.plus"
        case .storyMaker: return "book"
        case .shootAndRecord: return "record.circle"
        case .autoEnhance: return "wand.and.stars"
        case .coverMaker: return "rectangle.portrait.and.arrow.forward"
        case .autoCaptions: return "captions.bubble"
        case .aiClipper: return "scissors.badge.ellipsis"
        case .remove: return "person.and.background.dotted"
        case .aiPhotoEditor: return "photo.on.rectangle.angled"
        }
    }

    var isNew: Bool { self == .aiClipper || self == .storyMaker }

    var pickerMode: PickerMode {
        switch self {
        case .retouch, .photoTools, .coverMaker, .aiPhotoEditor: return .photosOnly
        default: return .videosAndPhotos
        }
    }

    var launchAction: EditorLaunchAction {
        switch self {
        case .autoCut: return .autoCut
        case .autoEnhance: return .enhance
        case .autoCaptions: return .captions
        case .aiClipper: return .clipper
        case .remove: return .remove
        default: return .none
        }
    }

    /// Photo operation when the tool goes to the photo editor.
    var photoOperation: PhotoOperation? {
        switch self {
        case .retouch: return .retouch
        case .aiPhotoEditor: return .cartoon
        case .photoTools: return .autoEnhance
        case .coverMaker: return nil
        default: return nil
        }
    }
}
