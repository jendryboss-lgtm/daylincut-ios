import SwiftUI

// MARK: - Stickers

/// Emoji stickers: each tap drops a sticker (a large emoji text overlay with
/// a pop animation) at the playhead; it can then be moved, timed and styled
/// like any text item.
struct StickersPanel: View {
    @Bindable var vm: EditorViewModel
    @State private var category = 0

    static let categories: [(title: String, symbol: String, stickers: [String])] = [
        ("Trending", "flame", ["🔥", "😂", "😍", "🥹", "💯", "✨", "🎉", "❤️", "👀", "🙌", "😎", "🤯", "🥳", "💥", "⭐️", "👑"]),
        ("Reactions", "face.smiling", ["😀", "😅", "🤣", "😭", "😡", "🥺", "😱", "🤔", "🙄", "😴", "🤩", "😇", "🫶", "👍", "👏", "🙏"]),
        ("Travel", "airplane", ["✈️", "🌴", "🏖️", "🗺️", "📍", "🏔️", "🌅", "🚗", "🧳", "📸", "🌊", "🗽", "🏝️", "⛺️", "🚆", "🌍"]),
        ("Food", "fork.knife", ["🍕", "🍔", "🌮", "🍣", "🍩", "☕️", "🍰", "🥑", "🍜", "🍓", "🥤", "🍪", "🍦", "🥗", "🍿", "🍷"]),
        ("Sports", "figure.run", ["⚽️", "🏀", "🏈", "⚾️", "🎾", "🏋️", "🚴", "🏃", "🥊", "🏆", "🥇", "⛹️", "🧘", "🏄", "⛳️", "🎯"])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.categories.indices, id: \.self) { i in
                        Button { category = i } label: {
                            Label(Self.categories[i].title, systemImage: Self.categories[i].symbol)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(category == i ? Theme.chipHighlight : Theme.chip, in: Capsule())
                                .foregroundStyle(category == i ? .white : Theme.mutedText)
                        }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.categories[category].stickers, id: \.self) { sticker in
                    Button { vm.addSticker(sticker) } label: {
                        Text(sticker).font(.system(size: 30))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Add sticker \(sticker)")
                }
            }
            Text("Stickers appear at the playhead. Select one on the text track to move, retime or delete it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
