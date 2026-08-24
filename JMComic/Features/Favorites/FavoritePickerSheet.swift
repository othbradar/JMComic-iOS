import SwiftUI

struct FavoritePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    let detail: ComicDetail
    let completion: () async -> Void
    @State private var page: FavoritePage?
    @State private var newFolder = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if detail.isFavorite {
                    Section {
                        Button(role: .destructive) { removeFavorite() } label: {
                            Label("取消收藏", systemImage: "heart.slash")
                        }
                    }
                }
                Section("选择收藏夹") {
                    ForEach(page?.folders.filter { $0.id != "0" } ?? []) { folder in
                        Button { choose(folder) } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(isWorking)
                    }
                }
                Section("新建收藏夹") {
                    TextField("收藏夹名称", text: $newFolder)
                    Button("创建并放入") { createAndChoose() }
                        .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
            .appPageBackground()
            .overlay { if page == nil { ProgressView() } }
            .navigationTitle(detail.isFavorite ? "管理收藏" : "加入收藏")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await load() }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do { page = try await api.favorites() }
        catch { self.error = error.localizedDescription }
    }

    private func choose(_ folder: FavoriteFolder) {
        isWorking = true
        Task {
            do {
                if !detail.isFavorite { _ = try await api.toggleFavorite(comicID: detail.id) }
                _ = try await api.moveFavorite(comicID: detail.id, folderID: folder.id)
                await completion()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func createAndChoose() {
        let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task {
            do {
                _ = try await api.createFavoriteFolder(name: name)
                let updated = try await api.favorites()
                guard let folder = updated.folders.first(where: { $0.name == name }) else {
                    throw APIError.server("收藏夹已创建，但未能取得其 ID，请重新打开后选择")
                }
                page = updated
                choose(folder)
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func removeFavorite() {
        isWorking = true
        Task {
            do {
                _ = try await api.toggleFavorite(comicID: detail.id)
                await completion()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}
