import SwiftUI
import Combine

private extension FavoriteComicSortOrder {
    var title: String {
        switch self {
        case .added: "收藏时间（后收藏优先）"
        case .updated: "漫画更新时间（最新优先）"
        }
    }

    var systemImage: String {
        switch self {
        case .added: "clock.arrow.circlepath"
        case .updated: "sparkles"
        }
    }
}

struct FavoriteFoldersSnapshot {
    let accountID: String
    let folders: [FavoriteFolder]
}

actor FavoriteCacheStore {
    static let shared = FavoriteCacheStore()
    static let foldersDidChange = Notification.Name("JMComic.favoriteFoldersDidChange")
    private let suppliedDatabase: OfflineLibraryDatabase?
    private let notifications: NotificationCenter

    init(database: OfflineLibraryDatabase? = nil, notifications: NotificationCenter = .default) {
        suppliedDatabase = database
        self.notifications = notifications
    }

    private func publishFolders(accountID: String) throws {
        // Read only the small folder metadata after the database commit. The
        // resident sidebar must update even when its task/onAppear never reruns.
        let snapshot = FavoriteFoldersSnapshot(accountID: accountID,
                                               folders: try database.cachedFavoriteFolders(accountID: accountID))
        notifications.post(name: Self.foldersDidChange, object: snapshot)
    }

    private struct FirstPageEntry {
        let result: FavoritePage
        let storedAt: Date
    }

    /// 收藏夹列表与“全部收藏”内容共用同一个第一页请求。
    /// 只做极短时内存复用，不会影响 SQLite 作为真实缓存源。
    private var firstPages: [String: FirstPageEntry] = [:]
    private let firstPageLifetime: TimeInterval = 30

    private var database: OfflineLibraryDatabase {
        get throws {
            guard let database = suppliedDatabase ?? JMComicDatabase.shared else {
                throw OfflineLibraryDatabaseError.invalidData("收藏数据库未初始化")
            }
            return database
        }
    }

    func folders(accountID: String) throws -> [FavoriteFolder] {
        try database.cachedFavoriteFolders(accountID: accountID)
    }

    func replaceFolders(accountID: String, folders: [FavoriteFolder]) throws {
        try database.replaceFavoriteFolders(accountID: accountID, folders: folders, at: .now)
        try publishFolders(accountID: accountID)
    }

    func page(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        offset: Int,
        limit: Int
    ) throws -> CachedFavoritePage {
        try database.cachedFavoritePage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            offset: offset,
            limit: limit
        )
    }

    func cache(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        page: Int,
        pageSize: Int,
        result: FavoritePage,
        syncToken: String
    ) throws {
        try database.cacheFavoritePage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            page: page,
            pageSize: pageSize,
            result: result,
            syncToken: syncToken,
            at: .now
        )
        try publishFolders(accountID: accountID)
    }

    func finish(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        syncToken: String,
        total: Int
    ) throws {
        try database.finishFavoriteSync(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            syncToken: syncToken,
            total: total,
            at: .now
        )
        try publishFolders(accountID: accountID)
    }

    func lastSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder
    ) throws -> Date? {
        try database.lastFavoriteSync(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder
        )
    }

    func beginFullSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder
    ) throws {
        try database.beginFavoriteFullSync(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder
        )
    }

    func existingIDs(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        comicIDs: [String]
    ) throws -> Set<String> {
        try database.existingFavoriteComicIDs(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            comicIDs: comicIDs
        )
    }

    func prepend(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        comics: [ComicSummary]
    ) throws {
        try database.prependFavoriteComics(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            comics: comics,
            at: .now
        )
        try publishFolders(accountID: accountID)
    }

    func replaceLeadingPage(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        comics: [ComicSummary],
        remoteTotal: Int
    ) throws {
        try database.replaceFavoriteLeadingPage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            comics: comics,
            remoteTotal: remoteTotal,
            at: .now
        )
        try publishFolders(accountID: accountID)
    }

    func storeFirstPage(
        _ result: FavoritePage,
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added
    ) {
        removeExpiredFirstPages()
        firstPages[firstPageKey(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder
        )] = FirstPageEntry(
            result: result,
            storedAt: .now
        )
    }

    /// 只消费一次：从收藏夹列表进入“全部收藏”时复用刚拿到的第一页，
    /// 再次进入仍会重新请求，从而符合“每次进入检查新增”的语义。
    func firstPage(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder
    ) -> FavoritePage? {
        removeExpiredFirstPages()
        return firstPages.removeValue(
            forKey: firstPageKey(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder
            )
        )?.result
    }

    private func firstPageKey(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder
    ) -> String {
        "\(accountID):\(folderID):\(sortOrder.rawValue)"
    }

    private func removeExpiredFirstPages() {
        let cutoff = Date.now.addingTimeInterval(-firstPageLifetime)
        firstPages = firstPages.filter { $0.value.storedAt >= cutoff }
    }
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published var folders: [FavoriteFolder] = []
    @Published var isLoading = false
    @Published var error: String?
    private var activeAccountID = ""
    private var loadGeneration = UUID()
    private let cache: FavoriteCacheStore
    private var folderObservation: AnyCancellable?

    init(cache: FavoriteCacheStore = .shared, notifications: NotificationCenter = .default) {
        self.cache = cache
        folderObservation = notifications.publisher(for: FavoriteCacheStore.foldersDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let snapshot = notification.object as? FavoriteFoldersSnapshot,
                          !self.activeAccountID.isEmpty, snapshot.accountID == self.activeAccountID else { return }
                    if self.folders != snapshot.folders { self.folders = snapshot.folders }
                }
            }
    }

    func activateAccount(_ accountID: String) {
        guard activeAccountID != accountID else { return }
        activeAccountID = accountID
        loadGeneration = UUID()
        folders = []
        error = nil
        isLoading = false
    }

    func load(api: APIClient, sortOrder: FavoriteComicSortOrder) async {
        guard let accountID = api.profile?.id, !accountID.isEmpty else {
            activateAccount("")
            return
        }
        activateAccount(accountID)
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer {
            if loadGeneration == generation { isLoading = false }
        }

        // 先用本地 SQLite 立即展示，网络只负责后台更新元数据。
        if let cached = try? await cache.folders(accountID: accountID),
           !cached.isEmpty {
            guard activeAccountID == accountID, loadGeneration == generation else { return }
            folders = cached
        }
        do {
            // The same response carries folder metadata and the "全部收藏"
            // first page. Follow the persisted comic ordering so mp does not
            // pay for an unused mr page before loading its own first page.
            let result = try await api.favorites(order: sortOrder.rawValue)
            guard activeAccountID == accountID, loadGeneration == generation else { return }
            await cache.storeFirstPage(
                result,
                accountID: accountID,
                folderID: "0",
                sortOrder: sortOrder
            )
            try await cache.replaceFolders(accountID: accountID, folders: result.folders)
            let updated = try await cache.folders(accountID: accountID)
            guard activeAccountID == accountID, loadGeneration == generation else { return }
            folders = updated
            error = nil
        } catch {
            guard activeAccountID == accountID, loadGeneration == generation else { return }
            if folders.isEmpty { self.error = error.localizedDescription }
        }
    }

    func reportOperationError(_ error: Error, accountID: String) {
        guard activeAccountID == accountID else { return }
        self.error = error.localizedDescription
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.readerIsPresented) private var readerIsPresented
    @Environment(\.rootTabSelection) private var rootTabSelection
    @AppStorage(InterfacePreferences.showExplanatoryTextKey)
    private var showsExplanatoryText = false
    @AppStorage("favorites.comicSort")
    private var selectedComicSort = FavoriteComicSortOrder.added.rawValue
    @StateObject private var model = FavoritesViewModel()
    @State private var showCreate = false
    @State private var newFolderName = ""
    @State private var deletingFolder: FavoriteFolder?
    @State private var selectedFolderID: FavoriteFolder.ID?
    @State private var loggedOutNavigationPath: [AppNavigationRoute] = []
    @State private var folderNavigationPath = NavigationPath()
    @State private var regularColumnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var compactColumnVisibility: NavigationSplitViewVisibility = .automatic

    private var comicSort: FavoriteComicSortOrder {
        FavoriteComicSortOrder(rawValue: selectedComicSort) ?? .added
    }

    var body: some View {
        Group {
            if !api.isLoggedIn {
                NavigationStack(path: $loggedOutNavigationPath) {
                    ZStack {
                        themedBackground.ignoresSafeArea()
                        ContentUnavailableView {
                            Label("登录后查看收藏", systemImage: "heart")
                        } description: {
                            Text("支持多个收藏夹的创建、删除和漫画移动")
                        } actions: {
                            NavigationLink(value: AppNavigationRoute.login) {
                                Text("去登录")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .navigationTitle("收藏")
                    .appNavigationDestinations()
                    .rootTabSwipe(
                        selection: rootTabSelection,
                        from: .favorites,
                        isEnabled: RootNavigationPathPolicy.allowsRootTabSwipe(
                            path: loggedOutNavigationPath
                        )
                    )
                }
                .appPageBackground()
            } else {
                NavigationSplitView(columnVisibility: splitColumnVisibility) {
                    List(selection: $selectedFolderID) {
                        // The compact split-view sidebar did not reliably draw
                        // its own title. Keep iPad's native "收藏夹" sidebar
                        // title, while iPhone shares the exact content-title
                        // geometry used by Downloads.
                        if horizontalSizeClass != .regular {
                            RootPageLargeTitleRow(title: "收藏")
                        }

                        ForEach(model.folders) { folder in
                            if horizontalSizeClass == .regular {
                                NavigationLink(value: folder.id) {
                                    FavoriteFolderSidebarRow(
                                        folder: folder,
                                        isSelected: selectedFolderID == folder.id
                                    ) {
                                        deletingFolder = folder
                                    }
                                }
                                .listRowInsets(
                                    EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            } else {
                                NavigationLink(value: folder.id) {
                                    FavoriteFolderRow(folder: folder) { deletingFolder = folder }
                                }
                                .badge(Text(folder.count.formatted()))
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .contentMargins(
                        .top,
                        horizontalSizeClass == .regular ? nil : 0,
                        for: .scrollContent
                    )
                    // iPad 的系统 sidebar selection 会额外绘制一层蓝色矩形。
                    // 保留 List(selection:) 的键盘、指针和 split-view 导航语义，
                    // 只让系统层透明，真正的选中态由行内液态玻璃负责。
                    .tint(horizontalSizeClass == .regular ? .clear : .accentColor)
                    .scrollContentBackground(.hidden)
                    .background(themedBackground.ignoresSafeArea())
                    .appPageBackground()
                    .overlay {
                        if model.isLoading && model.folders.isEmpty {
                            if showsExplanatoryText {
                                ProgressView("读取收藏夹…")
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    .navigationTitle(horizontalSizeClass == .regular ? "收藏夹" : "收藏")
                    .navigationBarTitleDisplayMode(
                        horizontalSizeClass == .regular ? .automatic : .inline
                    )
                    // 详情栈已 push 后，即使 iPad 临时拉出侧栏，
                    // 侧栏也不应再触发根 Tab 切换。
                    .rootTabSwipe(
                        selection: rootTabSelection,
                        from: .favorites,
                        isEnabled: RootNavigationPathPolicy.allowsFavoritesSidebarRootTabSwipe(
                            isRegularWidth: horizontalSizeClass == .regular,
                            selectedFolderID: selectedFolderID,
                            detailDepth: folderNavigationPath.count
                        )
                    )
                    .toolbar {
                        if horizontalSizeClass != .regular {
                            // Keep the compact navigation bar's fixed inline
                            // height but suppress a duplicate centered title.
                            ToolbarItem(placement: .principal) {
                                Text("").accessibilityHidden(true)
                            }
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Menu {
                                Picker("收藏漫画排序", selection: $selectedComicSort) {
                                    ForEach(
                                        FavoriteComicSortOrder.allCases,
                                        id: \.rawValue
                                    ) { option in
                                        Label(option.title, systemImage: option.systemImage)
                                            .tag(option.rawValue)
                                    }
                                }
                            } label: {
                                Label("排序", systemImage: "arrow.up.arrow.down")
                            }
                            .tint(.blue)
                            .accessibilityLabel("收藏漫画排序：\(comicSort.title)")

                            Button { showCreate = true } label: {
                                Label("新建收藏夹", systemImage: "folder.badge.plus")
                            }
                            // Keep toolbar actions consistent with the app's
                            // other system-blue controls. The AccentColor asset
                            // is purple and made this one icon look unrelated.
                            .tint(.blue)
                        }
                    }
                } detail: {
                    // 详情列使用自己的导航栈：漫画详情是收藏夹内容的
                    // 下一层，不再替换折叠后的 NavigationSplitView 列。
                    NavigationStack(path: $folderNavigationPath) {
                        ZStack {
                            themedBackground.ignoresSafeArea()
                            if let selectedFolder {
                                FavoriteFolderContent(
                                    folder: selectedFolder,
                                    sortOrder: comicSort
                                )
                            } else {
                                ContentUnavailableView(
                                    "选择收藏夹",
                                    systemImage: "folder",
                                    description: Text("进入后可打开漫画详情并选择章节阅读")
                                )
                            }
                        }
                        // iPad 的默认收藏详情列就是一级内容，可以切换根标签；
                        // iPhone 进入单个收藏夹已是二级，必须禁用。手势只修饰根 ZStack，
                        // 再 push 漫画详情后不会被目标页继承，无需依赖 NavigationPath 计数。
                        .rootTabSwipe(
                            selection: rootTabSelection,
                            from: .favorites,
                            isEnabled: horizontalSizeClass == .regular
                                && folderNavigationPath.isEmpty
                        )
                        .appNavigationDestinations()
                    }
                    .id(selectedFolderID)
                    .appPageBackground()
                }
                // 平板窄栏按需覆盖在详情上，不再挤压漫画图片的宽度。
                .navigationSplitViewStyle(.prominentDetail)
                .background(themedBackground.ignoresSafeArea())
                .onAppear {
                    if horizontalSizeClass == .regular {
                        regularColumnVisibility = .detailOnly
                    }
                }
                .task(id: api.profile?.id) {
                    await model.load(api: api, sortOrder: comicSort)
                }
                .onChange(of: selectedFolderID) { oldValue, newValue in
                    if oldValue != newValue {
                        folderNavigationPath = NavigationPath()
                        if horizontalSizeClass == .regular {
                            regularColumnVisibility = .detailOnly
                        }
                    }
                }
                .onChange(of: folderNavigationPath.count) { _, depth in
                    if depth > 0, horizontalSizeClass == .regular {
                        regularColumnVisibility = .detailOnly
                    }
                }
                .onChange(of: readerIsPresented.wrappedValue) { _, isPresented in
                    if isPresented {
                        regularColumnVisibility = .detailOnly
                    }
                }
                .onChange(of: horizontalSizeClass) { _, sizeClass in
                    if sizeClass == .regular {
                        regularColumnVisibility = .detailOnly
                    } else {
                        compactColumnVisibility = .automatic
                    }
                }
                .onChange(of: model.folders.map(\.id)) { _, folderIDs in
                    if let selectedFolderID, folderIDs.contains(selectedFolderID) {
                        return
                    }
                    // 侧栏默认隐藏时仍直接展示“全部收藏”，避免
                    // iPad 首次进入只看到一个空的“选择收藏夹”详情列。
                    if horizontalSizeClass == .regular {
                        self.selectedFolderID = folderIDs.first
                        regularColumnVisibility = .detailOnly
                    } else {
                        // iPhone 仍从收藏夹列表开始，不自动推入“全部收藏”。
                        self.selectedFolderID = nil
                    }
                }
            }
        }
        .appPageBackground()
        .onChange(of: api.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn {
                // The login destination belongs to the logged-out stack. Do
                // not resurrect it if this account later signs out again.
                loggedOutNavigationPath.removeAll()
            } else {
                model.activateAccount("")
                selectedFolderID = nil
                folderNavigationPath = NavigationPath()
            }
        }
        .alert("新建收藏夹", isPresented: $showCreate) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") { createFolder() }
        }
        .confirmationDialog("删除“\(deletingFolder?.name ?? "")”？漫画会保留在全部收藏中。", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        ), titleVisibility: .visible) {
            Button("删除收藏夹", role: .destructive) { deleteFolder() }
            Button("取消", role: .cancel) {}
        }
        .alert("收藏操作失败", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("重试") {
                Task { await model.load(api: api, sortOrder: comicSort) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.error ?? "未知错误")
        }
    }

    private var selectedFolder: FavoriteFolder? {
        guard let selectedFolderID else { return nil }
        return model.folders.first { $0.id == selectedFolderID }
    }

    private var themedBackground: Color {
        appearance.background(for: colorScheme)
    }

    /// iPhone 保持原有的紧凑栈导航；iPad 则默认只显示详情列。
    private var splitColumnVisibility: Binding<NavigationSplitViewVisibility> {
        horizontalSizeClass == .regular
            ? $regularColumnVisibility
            : $compactColumnVisibility
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let accountID = api.profile?.id else { return }
        Task {
            do {
                _ = try await api.createFavoriteFolder(name: name)
                newFolderName = ""
                await model.load(api: api, sortOrder: comicSort)
            } catch { model.reportOperationError(error, accountID: accountID) }
        }
    }

    private func deleteFolder() {
        guard let folder = deletingFolder, let accountID = api.profile?.id else { return }
        deletingFolder = nil
        Task {
            do {
                _ = try await api.deleteFavoriteFolder(id: folder.id)
                await model.load(api: api, sortOrder: comicSort)
            } catch { model.reportOperationError(error, accountID: accountID) }
        }
    }
}

@MainActor
private final class FavoriteFolderContentModel: ObservableObject {
    private static let displayBatchSize = 60
    private static let concurrentFullSyncRequests = 2

    private enum SyncMode: Equatable {
        case initialFull
        case manualFull
        case incremental

        var isFull: Bool {
            switch self {
            case .initialFull, .manualFull: true
            case .incremental: false
            }
        }
    }

    @Published var comics: [ComicSummary] = []
    @Published var coverRelativePaths: [String: String] = [:]
    @Published var total = 0
    @Published var isLoadingCache = false
    @Published var isLoadingMore = false
    @Published var isSyncing = false
    @Published var syncedItems = 0
    @Published var isFullSync = false
    @Published var syncStatus = ""
    @Published var syncResult: String?
    @Published var lastSync: Date?
    @Published var error: String?

    private var displayLimit = displayBatchSize
    private var activeKey = ""
    /// A key alone cannot distinguish mr -> mp -> mr (ABA). Every new root
    /// operation receives a generation so a delayed response can never mutate
    /// the newer operation, even when both end on the same ordering key.
    private var activeGeneration = UUID()

    func start(
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient
    ) async {
        guard let accountID = api.profile?.id, !accountID.isEmpty else { return }
        let key = cacheKey(accountID: accountID, folderID: folderID, sortOrder: sortOrder)
        let generation = UUID()
        let changedNamespace = activeKey != key
        activeKey = key
        activeGeneration = generation
        // Invalidate any same-key retry that is still returning from the
        // network. Its defer block also carries the old generation.
        isSyncing = false
        isLoadingMore = false
        if changedNamespace {
            displayLimit = Self.displayBatchSize
            comics = []
            coverRelativePaths = [:]
            total = 0
            syncedItems = 0
            isFullSync = false
            syncStatus = ""
            syncResult = nil
            lastSync = nil
            error = nil
        }
        isLoadingCache = true
        await reloadCache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            generation: generation
        )
        guard isActive(key, generation: generation) else { return }
        let storedLastSync: Date?
        do {
            storedLastSync = try await FavoriteCacheStore.shared.lastSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder
            )
        } catch {
            guard isActive(key, generation: generation) else { return }
            self.error = error.localizedDescription
            isLoadingCache = false
            return
        }
        guard isActive(key, generation: generation) else { return }
        lastSync = storedLastSync
        isLoadingCache = false
        await synchronize(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            api: api,
            mode: storedLastSync == nil ? .initialFull : .incremental,
            generation: generation
        )
    }

    func loadMore(
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient
    ) async {
        guard let accountID = api.profile?.id, !isLoadingMore else { return }
        let key = cacheKey(accountID: accountID, folderID: folderID, sortOrder: sortOrder)
        let generation = activeGeneration
        guard isActive(key, generation: generation) else { return }
        isLoadingMore = true
        displayLimit += Self.displayBatchSize
        await reloadCache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            generation: generation
        )
        if isActive(key, generation: generation) { isLoadingMore = false }
    }

    func refresh(
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient
    ) async {
        guard let accountID = api.profile?.id, !isSyncing else { return }
        let key = cacheKey(accountID: accountID, folderID: folderID, sortOrder: sortOrder)
        guard activeKey == key else { return }
        let generation = UUID()
        activeGeneration = generation
        // Invalidate a concurrent local pagination read. Its old generation
        // will not mutate the refreshed list, and the button must not remain
        // disabled after that old task returns.
        isLoadingMore = false
        let storedLastSync: Date?
        do {
            storedLastSync = try await FavoriteCacheStore.shared.lastSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder
            )
        } catch {
            guard isActive(key, generation: generation) else { return }
            self.error = error.localizedDescription
            return
        }
        guard isActive(key, generation: generation) else { return }
        await synchronize(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            api: api,
            mode: storedLastSync == nil ? .initialFull : .incremental,
            generation: generation
        )
    }

    func fullRefresh(
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient
    ) async {
        guard let accountID = api.profile?.id, !isSyncing else { return }
        let key = cacheKey(accountID: accountID, folderID: folderID, sortOrder: sortOrder)
        guard activeKey == key else { return }
        let generation = UUID()
        activeGeneration = generation
        isLoadingMore = false
        await synchronize(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            api: api,
            mode: .manualFull,
            generation: generation
        )
    }

    private func synchronize(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient,
        mode: SyncMode,
        generation: UUID
    ) async {
        guard !isSyncing else { return }
        let key = cacheKey(accountID: accountID, folderID: folderID, sortOrder: sortOrder)
        guard isActive(key, generation: generation) else { return }
        isSyncing = true
        syncedItems = 0
        isFullSync = mode.isFull
        syncStatus = switch mode {
        case .initialFull: "首次建立本地收藏库"
        case .manualFull: "手动全量更新"
        case .incremental:
            sortOrder == .added ? "正在检查新收藏" : "正在刷新最近更新"
        }
        syncResult = nil
        error = nil
        defer {
            if isActive(key, generation: generation) { isSyncing = false }
        }

        do {
            if mode.isFull {
                try await performFullSync(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    api: api,
                    key: key,
                    mode: mode,
                    generation: generation
                )
            } else {
                if sortOrder == .added {
                    try await performIncrementalSync(
                        accountID: accountID,
                        folderID: folderID,
                        sortOrder: sortOrder,
                        api: api,
                        key: key,
                        generation: generation
                    )
                } else {
                    try await performUpdatedLeadingPageRefresh(
                        accountID: accountID,
                        folderID: folderID,
                        sortOrder: sortOrder,
                        api: api,
                        key: key,
                        generation: generation
                    )
                }
            }
        } catch is CancellationError {
            // 页面离开时不收尾，旧 token 数据仍保留，下次可继续安全更新。
        } catch {
            guard isActive(key, generation: generation) else { return }
            self.error = error.localizedDescription
        }
    }

    private func performFullSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient,
        key: String,
        mode: SyncMode,
        generation: UUID
    ) async throws {
        let usePrefetchedPage: Bool
        switch mode {
        case .initialFull: usePrefetchedPage = true
        case .manualFull, .incremental: usePrefetchedPage = false
        }

        try Task.checkCancellation()
        try ensureActive(key, generation: generation)
        // Mark the namespace incomplete before touching any page. An app exit,
        // cancellation or API failure then forces a repair full sync next time,
        // while the previously committed rows remain readable.
        try await FavoriteCacheStore.shared.beginFullSync(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder
        )
        try ensureActive(key, generation: generation)
        lastSync = nil

        let first = try await loadFirstPage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            api: api,
            usePrefetch: usePrefetchedPage
        )
        try ensureActive(key, generation: generation)

        let pageSize = max(1, first.count > 0 ? first.count : first.comics.count)
        if first.total > 0, first.comics.isEmpty {
            throw APIError.invalidResponse
        }

        let syncToken = UUID().uuidString
        try await FavoriteCacheStore.shared.cache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            page: 1,
            pageSize: pageSize,
            result: first,
            syncToken: syncToken
        )
        try ensureActive(key, generation: generation)
        total = first.total
        syncedItems = first.comics.count
        syncStatus = switch mode {
        case .initialFull: "首次建立本地收藏库"
        case .manualFull: "手动全量更新"
        case .incremental: "全量更新"
        }
        await reloadCache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            generation: generation
        )
        try ensureActive(key, generation: generation)
        // 内容列表的 total 是本地已落库条数；全量进度仍显示服务器总数。
        total = first.total

        let pageCount = first.total == 0
            ? 1
            : Int(ceil(Double(first.total) / Double(pageSize)))
        var nextPage = 2
        while nextPage <= pageCount {
            try Task.checkCancellation()
            try ensureActive(key, generation: generation)
            let endPage = min(
                pageCount,
                nextPage + Self.concurrentFullSyncRequests - 1
            )
            let pages = Array(nextPage...endPage)
            let results = try await withThrowingTaskGroup(of: (Int, FavoritePage).self) { group in
                for page in pages {
                    group.addTask {
                        (
                            page,
                            try await api.favorites(
                                folderID: folderID,
                                page: page,
                                order: sortOrder.rawValue
                            )
                        )
                    }
                }
                var values: [(Int, FavoritePage)] = []
                for try await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }
            }

            for (page, result) in results {
                try Task.checkCancellation()
                try ensureActive(key, generation: generation)
                try await FavoriteCacheStore.shared.cache(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    page: page,
                    pageSize: pageSize,
                    result: result,
                    syncToken: syncToken
                )
                try ensureActive(key, generation: generation)
                syncedItems += result.comics.count
            }
            // 全量更新最多只保持2路请求，并分批刷新本地首屏。
            await reloadCache(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder,
                generation: generation
            )
            try ensureActive(key, generation: generation)
            total = first.total
            nextPage = endPage + 1
        }

        try Task.checkCancellation()
        try ensureActive(key, generation: generation)
        try await FavoriteCacheStore.shared.finish(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            syncToken: syncToken,
            total: first.total
        )
        try ensureActive(key, generation: generation)
        lastSync = .now
        syncStatus = "全量更新完成"
        syncResult = "全量更新完成"
        error = nil
        await reloadCache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            generation: generation
        )
        try ensureActive(key, generation: generation)
        total = first.total
    }

    private func performIncrementalSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient,
        key: String,
        generation: UUID
    ) async throws {
        var page = 1
        var pageSize = 0
        var newComics: [ComicSummary] = []
        var collectedIDs = Set<String>()

        while true {
            try Task.checkCancellation()
            try ensureActive(key, generation: generation)
            syncStatus = "正在检查新收藏（第 \(page) 页）"

            let result: FavoritePage
            if page == 1 {
                result = try await loadFirstPage(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    api: api,
                    usePrefetch: true
                )
                pageSize = max(1, result.count > 0 ? result.count : result.comics.count)
            } else {
                // 增量模式严格串行：只有上一页全部为新记录才请求下一页。
                result = try await api.favorites(
                    folderID: folderID,
                    page: page,
                    order: sortOrder.rawValue
                )
            }
            try ensureActive(key, generation: generation)

            let pageIDs = result.comics.map(\.id)
            let existing = pageIDs.isEmpty
                ? Set<String>()
                : try await FavoriteCacheStore.shared.existingIDs(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    comicIDs: pageIDs
                )
            try ensureActive(key, generation: generation)

            var additionsOnPage = 0
            for comic in result.comics {
                guard !existing.contains(comic.id), collectedIDs.insert(comic.id).inserted else {
                    continue
                }
                newComics.append(comic)
                additionsOnPage += 1
            }
            syncedItems = newComics.count
            syncStatus = newComics.isEmpty
                ? "未发现新收藏"
                : "已发现 \(newComics.count) 本新收藏"

            let entirePageIsNew = existing.isEmpty
                && additionsOnPage == result.comics.count
                && !result.comics.isEmpty
            let isFullPage = result.comics.count >= pageSize
            let reachedServerEnd = page * pageSize >= result.total
            guard entirePageIsNew, isFullPage, !reachedServerEnd else { break }
            page += 1
        }

        try Task.checkCancellation()
        try ensureActive(key, generation: generation)
        if !newComics.isEmpty {
            // 跨页结果按服务器顺序一次性前插，避免反复移动几千条 position。
            try await FavoriteCacheStore.shared.prepend(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder,
                comics: newComics
            )
        }
        try ensureActive(key, generation: generation)
        await reloadCache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            generation: generation
        )
        try ensureActive(key, generation: generation)
        syncStatus = newComics.isEmpty ? "已是最新" : "新增 \(newComics.count) 本收藏"
        syncResult = newComics.isEmpty ? "已检查，没有新收藏" : "已增量加入 \(newComics.count) 本收藏"
        error = nil
    }

    /// `mp` 是服务器的「更新时间」顺序，旧漫画可能因新章节重新回到首页。
    /// 因此不能像 `mr` 一样遇到已有 ID 就停止；初次会全量建库，
    /// 之后每次进入至少用服务器首页重排本地的头部。
    private func performUpdatedLeadingPageRefresh(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient,
        key: String,
        generation: UUID
    ) async throws {
        try Task.checkCancellation()
        try ensureActive(key, generation: generation)
        syncStatus = "正在刷新最近更新首页"
        let first = try await loadFirstPage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            api: api,
            usePrefetch: false
        )
        try ensureActive(key, generation: generation)
        if first.total > 0, first.comics.isEmpty {
            throw APIError.invalidResponse
        }

        try await FavoriteCacheStore.shared.replaceLeadingPage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            comics: first.comics,
            remoteTotal: first.total
        )
        try ensureActive(key, generation: generation)
        syncedItems = first.comics.count
        await reloadCache(
            accountID: accountID,
            folderID: folderID,
            sortOrder: sortOrder,
            generation: generation
        )
        try ensureActive(key, generation: generation)
        syncStatus = "最近更新顺序已刷新"
        syncResult = "已按服务器最近更新顺序刷新首页"
        error = nil
    }

    private func loadFirstPage(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        api: APIClient,
        usePrefetch: Bool
    ) async throws -> FavoritePage {
        if usePrefetch, sortOrder == .added,
           let prefetched = await FavoriteCacheStore.shared.firstPage(
               accountID: accountID,
               folderID: folderID,
               sortOrder: sortOrder
           ) {
            return prefetched
        }
        return try await api.favorites(
            folderID: folderID,
            page: 1,
            order: sortOrder.rawValue
        )
    }

    private func isActive(_ key: String, generation: UUID) -> Bool {
        activeKey == key && activeGeneration == generation
    }

    private func ensureActive(_ key: String, generation: UUID) throws {
        guard isActive(key, generation: generation) else { throw CancellationError() }
    }

    private func reloadCache(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        generation: UUID
    ) async {
        do {
            let cached = try await FavoriteCacheStore.shared.page(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder,
                offset: 0,
                limit: displayLimit
            )
            guard isActive(cacheKey(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder
            ), generation: generation) else { return }
            comics = cached.comics
            coverRelativePaths = cached.coverRelativePaths
            total = cached.total
        } catch {
            guard isActive(cacheKey(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder
            ), generation: generation) else { return }
            if comics.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func cacheKey(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder
    ) -> String {
        "\(accountID):\(folderID):\(sortOrder.rawValue)"
    }
}

private struct FavoriteFolderContent: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(InterfacePreferences.showExplanatoryTextKey)
    private var showsExplanatoryText = false
    let folder: FavoriteFolder
    let sortOrder: FavoriteComicSortOrder
    @StateObject private var model = FavoriteFolderContentModel()
    @State private var showFullSyncConfirmation = false

    var body: some View {
        ZStack {
            appearance.background(for: colorScheme).ignoresSafeArea()
            Group {
                if (model.isLoadingCache || model.isSyncing) && model.comics.isEmpty {
                    if showsExplanatoryText {
                        ProgressView(model.isSyncing ? "正在同步收藏…" : "读取本地收藏…")
                    } else {
                        ProgressView()
                    }
                } else if let error = model.error, model.comics.isEmpty {
                    RetryView(title: "无法载入收藏", message: error) {
                        Task {
                            await model.start(
                                folderID: folder.id,
                                sortOrder: sortOrder,
                                api: api
                            )
                        }
                    }
                } else if model.comics.isEmpty {
                    ContentUnavailableView("这个收藏夹是空的", systemImage: "heart.slash")
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            if model.isSyncing {
                                VStack(alignment: .leading, spacing: 6) {
                                    if model.isFullSync {
                                        ProgressView(
                                            value: Double(model.syncedItems),
                                            total: Double(max(model.total, 1))
                                        )
                                    } else {
                                        ProgressView()
                                    }
                                    if showsExplanatoryText {
                                        Text(model.isFullSync
                                            ? "\(model.syncStatus) \(min(model.syncedItems, model.total)) / \(model.total)"
                                            : model.syncStatus)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else if showsExplanatoryText && (model.syncResult != nil || model.lastSync != nil) {
                                VStack(alignment: .leading, spacing: 3) {
                                    if let syncResult = model.syncResult {
                                        Text(syncResult)
                                    }
                                    if let lastSync = model.lastSync {
                                        Text("上次全量更新 · \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ComicGrid(
                                comics: model.comics,
                                coverSource: .favorite(
                                    accountID: api.profile?.id ?? "",
                                    relativePaths: model.coverRelativePaths
                                )
                            )

                            if let error = model.error {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if model.comics.count < model.total {
                                Button {
                                    Task {
                                        await model.loadMore(
                                            folderID: folder.id,
                                            sortOrder: sortOrder,
                                            api: api
                                        )
                                    }
                                } label: {
                                    if model.isLoadingMore { ProgressView() }
                                    else if showsExplanatoryText {
                                        Text("从数据库加载更多（\(model.comics.count) / \(model.total)）")
                                    } else {
                                        Text("加载更多")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isLoadingMore)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        await model.refresh(
                            folderID: folder.id,
                            sortOrder: sortOrder,
                            api: api
                        )
                    }
                }
            }
        }
        .appPageBackground()
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFullSyncConfirmation = true
                } label: {
                    Label("全量更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isSyncing)
            }
        }
        .confirmationDialog(
            showsExplanatoryText
                ? "全量更新会请求这个收藏夹的全部分页，收藏较多时可能需要较长时间。"
                : "确认全量更新？",
            isPresented: $showFullSyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("继续全量更新") {
                Task {
                    await model.fullRefresh(
                        folderID: folder.id,
                        sortOrder: sortOrder,
                        api: api
                    )
                }
            }
            Button("取消", role: .cancel) {}
        }
        .task(id: "\(api.profile?.id ?? ""):\(folder.id):\(sortOrder.rawValue)") {
            await model.start(folderID: folder.id, sortOrder: sortOrder, api: api)
        }
    }
}

private struct FavoriteFolderRow: View {
    let folder: FavoriteFolder
    let delete: () -> Void

    var body: some View {
        Label(folder.name, systemImage: folder.id == "0" ? "heart" : "folder")
            .contextMenu {
                if folder.id != "0" {
                    Button(role: .destructive, action: delete) {
                        Label("删除收藏夹", systemImage: "trash")
                    }
                }
            }
    }
}

/// iPad 收藏夹侧栏仍由 `List(selection:)` 管理选择，这个行只接管视觉。
/// 因此鼠标/触控板点击、硬件键盘选择和 NavigationSplitView 联动不会改变。
private struct FavoriteFolderSidebarRow: View {
    let folder: FavoriteFolder
    let isSelected: Bool
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.id == "0" ? "heart" : "folder")
                .frame(width: 24)
                .foregroundStyle(Color.primary)

            Text(folder.name)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(folder.count.formatted())
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            FavoriteFolderSelectionBackground(isSelected: isSelected)
        }
        .animation(.snappy(duration: 0.22), value: isSelected)
        .accessibilityValue(isSelected ? "已选择，\(folder.count) 本" : "\(folder.count) 本")
        .contextMenu {
            if folder.id != "0" {
                Button(role: .destructive, action: delete) {
                    Label("删除收藏夹", systemImage: "trash")
                }
            }
        }
    }
}

private struct FavoriteFolderSelectionBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    @ViewBuilder
    var body: some View {
        if isSelected {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(
                        .regular
                            .tint(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                            .interactive(),
                        in: .rect(cornerRadius: 16)
                    )
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                    }
            }
        }
    }
}
