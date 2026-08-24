import SwiftUI

private actor SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private var database: OfflineLibraryDatabase {
        get throws {
            guard let database = JMComicDatabase.shared else {
                throw OfflineLibraryDatabaseError.invalidData("搜索历史数据库未初始化")
            }
            return database
        }
    }

    func entries() throws -> [SearchHistoryEntry] {
        try database.searchHistory(limit: 20)
    }

    func record(_ query: String) throws -> [SearchHistoryEntry] {
        try database.recordSearchQuery(query, maximumEntries: 50)
        return try entries()
    }

    func delete(_ query: String) throws -> [SearchHistoryEntry] {
        try database.deleteSearchQuery(query)
        return try entries()
    }

    func clear() throws {
        try database.clearSearchHistory()
    }
}

@MainActor
private final class SearchViewModel: ObservableObject {
    @Published var comics: [ComicSummary] = []
    @Published var total = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var order = "mr"
    private var requestGeneration = 0

    func search(_ text: String, api: APIClient) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearResults()
            return
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        error = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        do {
            let result = try await api.search(query, order: order)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            total = result.0
            comics = result.1
            error = nil
            if comics.isEmpty, let id = Int(query.filter(\.isNumber)), id > 0,
               let detail = try? await api.comic(id: String(id)) {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                comics = [detail.summaryModel]
                total = 1
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func clearResults() {
        requestGeneration &+= 1
        comics = []
        total = 0
        error = nil
        isLoading = false
    }
}

@MainActor
private final class SearchHistoryViewModel: ObservableObject {
    @Published var entries: [SearchHistoryEntry] = []
    @Published var error: String?

    func load() async {
        do {
            entries = try await SearchHistoryStore.shared.entries()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func record(_ query: String) async {
        do {
            entries = try await SearchHistoryStore.shared.record(query)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ query: String) async {
        do {
            entries = try await SearchHistoryStore.shared.delete(query)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear() async {
        do {
            try await SearchHistoryStore.shared.clear()
            entries = []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SearchView: View {
    @Environment(\.dismissSearch) private var dismissSearch
    @EnvironmentObject private var api: APIClient
    @StateObject private var model = SearchViewModel()
    @StateObject private var history = SearchHistoryViewModel()
    let initialQuery: String
    @State private var query: String
    @State private var showClearHistoryConfirmation = false

    init(initialQuery: String = "") {
        let normalized = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialQuery = normalized
        _query = State(initialValue: normalized)
    }

    var body: some View {
        Group {
            if model.isLoading && model.comics.isEmpty {
                AppLoadingView(accessibilityText: "正在搜索")
            } else if let error = model.error, model.comics.isEmpty {
                RetryView(title: "搜索失败", message: error) {
                    Task { await model.search(query, api: api) }
                }
            } else if model.comics.isEmpty {
                if SearchHistoryNormalization.value(from: query) == nil,
                   !history.entries.isEmpty {
                    ScrollView {
                        SearchHistoryCard(
                            entries: history.entries,
                            error: history.error,
                            select: { entry in
                                query = entry.query
                                Task { await performSearch(recordHistory: true) }
                            },
                            delete: { entry in
                                Task { await history.delete(entry.query) }
                            },
                            clear: { showClearHistoryConfirmation = true }
                        )
                        .frame(maxWidth: 720)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView(
                        SearchHistoryNormalization.value(from: query) == nil
                            ? "搜索漫画"
                            : "没有搜索结果",
                        systemImage: "books.vertical",
                        description: Text("输入名称、作者、标签或 JM 号")
                    )
                }
            } else {
                ScrollView {
                    ComicGrid(comics: model.comics)
                        .padding()
                }
            }
        }
        .navigationTitle(model.total > 0 ? "搜索 · \(model.total)" : "搜索")
        .appPageBackground()
        .searchable(text: $query, prompt: "名称、作者、标签或 JM 号")
        .onSubmit(of: .search) {
            Task { await performSearch(recordHistory: true) }
        }
        .task(id: initialQuery) {
            await history.load()
            guard !initialQuery.isEmpty, model.comics.isEmpty, !model.isLoading else { return }
            await performSearch(recordHistory: true)
        }
        .onChange(of: query) { _, newValue in
            if SearchHistoryNormalization.value(from: newValue) == nil {
                model.clearResults()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $model.order) {
                        Text("最新").tag("mr")
                        Text("最多点击").tag("mv")
                        Text("最多图片").tag("mp")
                        Text("最多收藏").tag("tf")
                    }
                    .onChange(of: model.order) { _, _ in
                        Task { await performSearch(recordHistory: false) }
                    }
                } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
            }
        }
        .confirmationDialog(
            "清空全部搜索历史？",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                Task { await history.clear() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func performSearch(recordHistory: Bool) async {
        guard let normalized = SearchHistoryNormalization.value(from: query) else {
            model.clearResults()
            return
        }
        query = normalized.display
        if recordHistory { await history.record(normalized.display) }
        dismissSearch()
        await model.search(normalized.display, api: api)
    }
}

private struct SearchHistoryCard: View {
    let entries: [SearchHistoryEntry]
    let error: String?
    let select: (SearchHistoryEntry) -> Void
    let delete: (SearchHistoryEntry) -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label("搜索历史", systemImage: "clock.arrow.circlepath")
                    .font(.title3.bold())
                Spacer()
                Button(action: clear) {
                    Label("清空", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 8)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Button { select(entry) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text(entry.query)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    Button { delete(entry) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除搜索历史 \(entry.query)")
                }
                .padding(.vertical, 8)
            }

            if let error, !error.isEmpty {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 10)
            }
        }
        .padding(18)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}
