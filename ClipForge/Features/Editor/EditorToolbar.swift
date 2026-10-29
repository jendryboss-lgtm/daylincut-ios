import SwiftUI

struct ToolItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var isOn: Bool = false
    var isPro: Bool = false
    var isNew: Bool = false
    let action: () -> Void

    init(_ title: String, _ symbol: String, isOn: Bool = false, isPro: Bool = false, isNew: Bool = false, action: @escaping () -> Void) {
        self.id = title
        self.title = title
        self.symbol = symbol
        self.isOn = isOn
        self.isPro = isPro
        self.isNew = isNew
        self.action = action
    }
}

/// Bottom toolbar that changes with the selection, like CapCut.
struct EditorToolbar: View {
    @Bindable var vm: EditorViewModel
    @Environment(PurchaseManager.self) private var purchases

    var body: some View {
        HStack(spacing: 0) {
            if vm.selection != nil {
                Button { vm.selection = nil } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .frame(width: 44, height: 64)
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Close selection tools")
                Divider().frame(height: 36)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        Button(action: item.action) {
                            VStack(spacing: 5) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 20))
                                    .frame(height: 24)
                                    .overlay(alignment: .topTrailing) {
                                        if item.isPro && !purchases.isPro {
                                            ProBadge().scaleEffect(0.7).offset(x: 10, y: -8)
                                        } else if item.isNew {
                                            Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: 6, y: -2)
                                        }
                                    }
                                Text(item.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(minWidth: 62, minHeight: 64)
                            .foregroundStyle(item.isOn ? Theme.accent : .primary)
                        }
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(item.isOn ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 4)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
    }

    private var items: [ToolItem] {
        switch vm.selection {
        case .clip: return clipItems
        case .text(let id): return [
            ToolItem("Edit", "character.cursor.ibeam") { vm.panel = .text },
            ToolItem("Duplicate", "plus.square.on.square") { vm.duplicateSelection() },
            ToolItem("Delete", "trash") { vm.deleteSelection() },
            ToolItem("To playhead", "arrow.right.to.line") { vm.updateText(id: id, coalesce: false) { $0.start = vm.currentTime } }
        ]
        case .audio(let id): return [
            ToolItem("Volume", "speaker.wave.2") { vm.panel = .audio },
            ToolItem("To playhead", "arrow.right.to.line") { vm.updateAudio(id: id, coalesce: false) { $0.start = vm.currentTime } },
            ToolItem("Delete", "trash") { vm.deleteSelection() }
        ]
        case .overlay(let id):
            let on = vm.timeline.overlays.first { $0.id == id }?.removeBackground ?? false
            return [
                ToolItem("Adjust", "slider.horizontal.3") { vm.panel = .overlay },
                ToolItem("Remove BG", "person.crop.rectangle", isOn: on) { vm.updateOverlay(id: id, coalesce: false) { $0.removeBackground.toggle() } },
                ToolItem("Delete", "trash") { vm.deleteSelection() }
            ]
        case .caption: return [
            ToolItem("Edit", "captions.bubble") { vm.panel = .captions },
            ToolItem("Transcript", "doc.text") { vm.panel = .transcript },
            ToolItem("Delete", "trash") { vm.deleteSelection() }
        ]
        case nil: return mainItems
        }
    }

    private var mainItems: [ToolItem] {
        [
            ToolItem("Edit", "scissors") {
                if let id = vm.targetClipID { vm.selection = .clip(id) }
            },
            ToolItem("AutoCut", "wand.and.stars", isNew: true) { vm.panel = .autoCut },
            ToolItem("Audio", "music.note") { vm.panel = .audio },
            ToolItem("Text", "textformat") { _ = vm.addText(); vm.panel = .text },
            ToolItem("Effects", "sparkles") { vm.panel = .effects },
            ToolItem("Overlay", "square.on.square") { vm.panel = .overlay },
            ToolItem("Captions", "captions.bubble") { vm.panel = .captions },
            ToolItem("Filters", "camera.filters") { vm.panel = .filters },
            ToolItem("AI avatar", "person.crop.circle.badge.plus", isPro: true, isNew: true) {
                if purchases.require(.advancedAI) { vm.panel = .avatar }
            },
            ToolItem("Transcript", "doc.text") { vm.panel = .transcript },
            ToolItem("Generate media", "photo.badge.plus") { vm.panel = .generate },
            ToolItem("Aspect ratio", "aspectratio") { vm.panel = .aspect },
            ToolItem("AI clipper", "rectangle.stack.badge.play") { vm.panel = .clipper },
            ToolItem("Enhance", "wand.and.rays") { vm.autoEnhanceAll(!(vm.timeline.clips.allSatisfy(\.autoEnhance))) },
            ToolItem("Adjust", "slider.horizontal.3") { vm.panel = .adjust }
        ]
    }

    private var clipItems: [ToolItem] {
        let clip = vm.selectedClip
        return [
            ToolItem("Split", "square.split.2x1") { vm.splitAtPlayhead() },
            ToolItem("Speed", "speedometer") { vm.panel = .speed },
            ToolItem("Volume", "speaker.wave.2") { vm.panel = .volume },
            ToolItem("Filters", "camera.filters", isOn: clip?.filter != FilterPreset.none) { vm.panel = .filters },
            ToolItem("Adjust", "slider.horizontal.3", isOn: clip?.adjustments.isIdentity == false) { vm.panel = .adjust },
            ToolItem("Effects", "sparkles", isOn: clip?.effect != VisualEffect.none) { vm.panel = .effects },
            ToolItem("Transition", "square.split.diagonal.2x2") { vm.panel = .transition },
            ToolItem("Remove BG", "person.crop.rectangle", isOn: clip?.removeBackground == true) {
                vm.removeBackground(!(clip?.removeBackground ?? false))
            },
            ToolItem("Enhance", "wand.and.rays", isOn: clip?.autoEnhance == true) {
                vm.updateTargetClip { $0.autoEnhance.toggle() }
            },
            ToolItem("AI ultra HD", "4k.tv", isOn: clip?.aiUltraHD == true, isPro: true) {
                if purchases.require(.ultraHD) { vm.updateTargetClip { $0.aiUltraHD.toggle() } }
            },
            ToolItem("Extend", "arrow.right.to.line.compact", isNew: true) { vm.panel = .extend },
            ToolItem("Extract audio", "waveform.badge.minus") { vm.extractAudio() },
            ToolItem("Crop", "crop") { vm.panel = .crop },
            ToolItem("Duplicate", "plus.square.on.square") { vm.duplicateSelection() },
            ToolItem("Move left", "arrow.left.square") { vm.moveSelectedClip(by: -1) },
            ToolItem("Move right", "arrow.right.square") { vm.moveSelectedClip(by: 1) },
            ToolItem("Delete", "trash") { vm.deleteSelection() }
        ]
    }
}
