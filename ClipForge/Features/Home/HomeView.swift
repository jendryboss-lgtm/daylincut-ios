import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    hero
                    createCards
                    if !projects.isEmpty { recentProjects }
                    toolsGrid
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("ClipForge")
                .font(.title2.weight(.heavy))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !purchases.isPro {
                Button {
                    purchases.presentPaywall()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond.fill")
                        Text("Start Pro for only \(purchases.startPriceText)")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.proGradient, in: Capsule())
                    .foregroundStyle(.white)
                }
                .accessibilityHint("Opens ClipForge Pro subscription options")
            } else {
                Label("Pro", systemImage: "diamond.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.pro)
            }
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        Button {
            router.start(.extendVideo)
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.heroGradient)
                    .frame(height: 150)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "arrow.right.to.line.compact")
                            .font(.system(size: 64, weight: .thin))
                            .foregroundStyle(.white.opacity(0.18))
                            .padding(.trailing, 24)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extend video")
                        .font(.title3.weight(.bold))
                    Text("Seamlessly extend any clip")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 4) {
                        Text("Try now")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.2), in: Capsule())
                    .padding(.top, 6)
                }
                .foregroundStyle(.white)
                .padding(16)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Extend video. Seamlessly extend any clip")
    }

    private var createCards: some View {
        HStack(spacing: 12) {
            CreateCard(title: "New video", symbol: "plus", gradient: [Theme.accent, Theme.accentDark]) {
                router.start(.newVideo)
            }
            CreateCard(title: "Edit photo", symbol: "photo", gradient: [Color(red: 0.98, green: 0.45, blue: 0.55), Color(red: 0.6, green: 0.3, blue: 0.9)]) {
                router.start(.editPhoto(nil))
            }
        }
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent projects").font(.headline)
                Spacer()
                Button("See all") { router.selectedTab = .projects }
                    .font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(projects.prefix(10)) { project in
                        Button { router.open(project) } label: {
                            ProjectThumbnail(project: project)
                                .frame(width: 110)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var toolsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(HomeTool.allCases) { tool in
                    Button { router.start(.tool(tool)) } label: {
                        ToolTile(tool: tool)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Components

struct CreateCard: View {
    var title: String
    var symbol: String
    var gradient: [Color]
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.headline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct ToolTile: View {
    var tool: HomeTool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: tool.symbol)
                .font(.title2)
                .frame(height: 30)
                .foregroundStyle(.primary)
            Text(tool.title)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            if tool.isNew {
                Text("New")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct ProjectThumbnail: View {
    let project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let data = project.thumbnailData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.surface)
                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(project.duration.timecode)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
            }
            Text(project.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(project.updatedAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), \(project.duration.timecode) long")
    }
}
