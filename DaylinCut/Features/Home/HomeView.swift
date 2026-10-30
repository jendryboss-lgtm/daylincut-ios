import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PurchaseManager.self) private var purchases
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @State private var showSearch = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        heroBackground
                        VStack(alignment: .leading, spacing: 0) {
                            topRow
                            Spacer(minLength: 0).frame(height: 96)
                            extendBanner
                            createCards.padding(.top, 14)
                            recents.padding(.top, 18)
                        }
                        .padding(.horizontal, 18)
                    }
                    toolsGrid
                        .padding(.top, 22)
                        .padding(.bottom, 24)
                }
            }
            .ignoresSafeArea(edges: .top)
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSearch) { HomeSearchView() }
        }
    }

    // MARK: Hero

    /// Full-bleed artwork behind the top of Home: the latest project's cover,
    /// fading into the page like CapCut's featured banner.
    private var heroBackground: some View {
        GeometryReader { geo in
            ZStack {
                if let data = projects.first?.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    LinearGradient(colors: [Color(red: 0.42, green: 0.52, blue: 0.62),
                                            Color(red: 0.72, green: 0.80, blue: 0.88),
                                            Color(red: 0.86, green: 0.90, blue: 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "car.side.rear.open")
                        .font(.system(size: 120, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.35))
                        .offset(y: -40)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0),
                                       .init(color: .clear, location: 0.3),
                                       .init(color: .black.opacity(0.25), location: 0.5),
                                       .init(color: Color(uiColor: .systemBackground).opacity(0.6), location: 0.82),
                                       .init(color: Color(uiColor: .systemBackground), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
    }

    private var topRow: some View {
        HStack {
            if !purchases.isPro {
                Button { purchases.presentPaywall() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond.fill")
                            .foregroundStyle(Color(red: 0.72, green: 0.55, blue: 1))
                        Text("Start Pro for only \(purchases.startPriceText)")
                            .lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
                }
                .accessibilityHint("Opens Daylin Cut Pro subscription options")
            } else {
                Label("Pro", systemImage: "diamond.fill")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.35), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Search")
        }
        .padding(.top, 62)
    }

    private var extendBanner: some View {
        Button { router.start(.extendVideo) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extend video")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 8) {
                    Text("Seamlessly extend any clip")
                        .font(.system(size: 20, weight: .bold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 18, height: 20)
                        .background(.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Extend video. Seamlessly extend any clip")
    }

    private var createCards: some View {
        HStack(spacing: 12) {
            HomeCreateCard(title: "New video", symbol: "plus") { router.start(.newVideo) }
                .frame(maxWidth: .infinity)
                .layoutPriority(1.6)
            HomeCreateCard(title: "Edit photo", symbol: "photo", badge: "AI photo editor") { router.start(.editPhoto(nil)) }
                .frame(width: 136)
        }
        .frame(height: 128)
    }

    /// Recent projects as compact covers, newest first; the last tile opens Projects.
    private var recents: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(projects.prefix(10)) { project in
                    Button { router.open(project) } label: { RecentTile(project: project) }
                        .buttonStyle(.plain)
                }
                Button { router.selectedTab = .projects } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 60, height: 76)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("All projects")
            }
        }
        .scrollClipDisabled()
    }

    private var toolsGrid: some View {
        LazyVGrid(columns: columns, spacing: 26) {
            ForEach(HomeTool.allCases) { tool in
                Button { router.start(.tool(tool)) } label: {
                    VStack(spacing: 10) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 22, weight: .regular))
                            .frame(height: 26)
                        Text(tool.title)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
            }
        }
        .padding(.horizontal, 8)
    }
}

struct HomeCreateCard: View {
    var title: String
    var symbol: String
    var badge: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Small cover in Home's recents row with the project name over a scissors glyph.
struct RecentTile: View {
    let project: Project
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let data = project.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.5))
                        .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.7)))
                }
            }
            .frame(width: 76, height: 76)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 3) {
                Image(systemName: "scissors").font(.system(size: 9))
                Text(project.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(5)
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), \(project.duration.timecode) long")
    }
}

/// Searches tools and projects from Home.
struct HomeSearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                let tools = HomeTool.allCases.filter { q.isEmpty || $0.title.lowercased().contains(q) }
                let matches = projects.filter { q.isEmpty || $0.name.lowercased().contains(q) }
                if !tools.isEmpty {
                    Section("Tools") {
                        ForEach(tools) { tool in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.start(.tool(tool)) }
                            } label: { Label(tool.title, systemImage: tool.symbol) }
                        }
                    }
                }
                if !matches.isEmpty {
                    Section("Projects") {
                        ForEach(matches.prefix(30)) { project in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.open(project) }
                            } label: { Label(project.name, systemImage: "film") }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tools and projects")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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
