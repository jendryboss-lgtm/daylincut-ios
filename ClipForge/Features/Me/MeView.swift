import StoreKit
import SwiftData
import SwiftUI

struct MeView: View {
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]
    @AppStorage("appearance") private var appearance: Appearance = .dark
    @State private var storageBytes: Int64 = 0
    @State private var showManage = false
    @State private var cleaned = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 52)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Creator").font(.title3.weight(.bold))
                            Text("\(projects.count) project\(projects.count == 1 ? "" : "s") · \(totalDuration.timecode) edited")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }

                Section("ClipForge Pro") {
                    if purchases.isPro {
                        Label("Pro is active", systemImage: "diamond.fill").foregroundStyle(Theme.pro)
                        Button("Manage subscription") { showManage = true }
                    } else {
                        Button { purchases.presentPaywall() } label: {
                            HStack {
                                Label("Start Pro for only \(purchases.startPriceText)", systemImage: "diamond.fill")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(Theme.pro)
                    }
                    Button("Restore purchases") { Task { await purchases.restore() } }
                    if let error = purchases.lastError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Preferences") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    LabeledContent("Media in ClipForge", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                    Button(cleaned ? "Unused media removed" : "Remove unused media") {
                        ProjectStore.collectGarbage(context: context)
                        cleaned = true
                        refreshStorage()
                    }
                    .disabled(cleaned)
                } header: { Text("Storage") } footer: {
                    Text("Imported clips are copied into ClipForge so projects keep working if you delete them from Photos.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("AI engine", value: AIServiceProvider.current.name)
                    Text("ClipForge processes your media on this iPhone. Speech recognition may use Apple's servers when on-device recognition isn't available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Me")
            .manageSubscriptionsSheet(isPresented: $showManage)
            .task { refreshStorage() }
        }
    }

    private var totalDuration: Double { projects.reduce(0) { $0 + $1.duration } }

    private func refreshStorage() {
        let dir = MediaStore.directory
        Task.detached(priority: .utility) {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let total = urls.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            await MainActor.run { storageBytes = total }
        }
    }
}
