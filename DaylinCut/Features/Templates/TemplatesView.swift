import SwiftUI

struct TemplatesView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases
    @State private var category: TemplatePreset.Category?
    @State private var search = ""

    private var filtered: [TemplatePreset] {
        TemplatePreset.all.filter { t in
            (category == nil || t.category == category) &&
            (search.isEmpty || t.title.localizedCaseInsensitiveContains(search) || t.subtitle.localizedCaseInsensitiveContains(search))
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button { category = nil } label: { ChipView(title: "For you", isSelected: category == nil) }
                            ForEach(TemplatePreset.Category.allCases) { c in
                                Button { category = c } label: { ChipView(title: c.rawValue, isSelected: category == c) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered) { template in
                            Button { use(template) } label: { TemplateCard(template: template) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Templates")
            .searchable(text: $search, prompt: "Search templates")
        }
    }

    private func use(_ template: TemplatePreset) {
        if template.isPro && !purchases.require(.advancedAI) { return }
        router.start(.template(template))
    }
}

struct TemplateCard: View {
    let template: TemplatePreset
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                LinearGradient(colors: template.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: template.symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                VStack {
                    HStack {
                        Text(template.aspect.title)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                        Spacer()
                        if template.isPro { ProBadge().padding(5).background(.black.opacity(0.35), in: Circle()) }
                    }
                    Spacer()
                    HStack {
                        Text(template.duration.timecode)
                        Spacer()
                        Label(template.uses.formatted(.number.notation(.compactName)), systemImage: "person.2.fill")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(8)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(template.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(template.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(template.title) template, \(template.subtitle)\(template.isPro ? ", Pro" : "")")
    }
}
