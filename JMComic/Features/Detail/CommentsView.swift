import SwiftUI

@MainActor
private final class CommentsViewModel: ObservableObject {
    @Published var comments: [ComicComment] = []
    @Published var total = 0
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var hasMore = true
    @Published var error: String?
    private var nextPage = 1
    private var activeComicID: String?
    private var requestGeneration = 0

    func load(comicID: String, api: APIClient, reset: Bool = false) async {
        let normalizedComicID = comicID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedComicID.isEmpty else { return }
        if activeComicID != normalizedComicID {
            activeComicID = normalizedComicID
            requestGeneration &+= 1
            comments = []
            total = 0
            nextPage = 1
            hasMore = true
            hasLoaded = false
            error = nil
            isLoading = false
        }
        if reset {
            // A successful submission or pull-to-refresh must supersede an
            // older pagination request rather than silently doing nothing.
            requestGeneration &+= 1
            nextPage = 1
            hasMore = true
            error = nil
            isLoading = false
        }
        guard !isLoading, reset || hasMore else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        defer {
            if activeComicID == normalizedComicID,
               requestGeneration == generation {
                isLoading = false
                hasLoaded = true
            }
        }
        let requestedPage = reset ? 1 : nextPage
        do {
            let result = try await api.comments(
                comicID: normalizedComicID,
                page: requestedPage
            )
            guard activeComicID == normalizedComicID,
                  requestGeneration == generation,
                  !Task.isCancelled else { return }
            let base = reset ? [] : comments
            var seen = Set(base.map(\.id))
            let additions = result.comments.filter { seen.insert($0.id).inserted }
            comments = base + additions
            total = max(result.total, comments.count)
            nextPage = requestedPage + 1
            hasMore = !result.comments.isEmpty
                && !additions.isEmpty
                && (result.total <= 0 || comments.count < result.total)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard activeComicID == normalizedComicID,
                  requestGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

private actor CommentComicTitleStore {
    static let shared = CommentComicTitleStore()

    private var database: OfflineLibraryDatabase {
        get throws {
            guard let database = JMComicDatabase.shared else {
                throw OfflineLibraryDatabaseError.invalidData("漫画名称缓存数据库未初始化")
            }
            return database
        }
    }

    func cachedTitles(for comicIDs: [String]) throws -> [String: String] {
        try database.cachedComicTitles(comicIDs: comicIDs)
    }

    func cache(_ titles: [String: String]) throws {
        try database.cacheComicTitles(titles)
    }
}

/// A small global gate keeps title repair from turning a comment page into a
/// burst of album requests. It is deliberately separate from image/download
/// concurrency settings because these are lightweight metadata requests.
private actor CommentComicTitleRequestGate {
    private var permits = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            permits = min(3, permits + 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
private final class CommentComicTitleResolver {
    static let shared = CommentComicTitleResolver()

    private let gate = CommentComicTitleRequestGate()

    func resolve(
        comments: [ComicComment],
        api: APIClient
    ) async -> [String: String] {
        let comicIDs = Array(Set(comments.compactMap { comment in
            let id = comment.comicID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        })).sorted()
        guard !comicIDs.isEmpty else { return [:] }

        var titles: [String: String] = [:]
        for comment in comments {
            let id = comment.comicID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title = CommentComicTitleNormalization.value(
                from: comment.comicName,
                comicID: id
            ) {
                titles[id] = title
            }
        }
        if !titles.isEmpty {
            try? await CommentComicTitleStore.shared.cache(titles)
        }

        if let cached = try? await CommentComicTitleStore.shared.cachedTitles(for: comicIDs) {
            for (id, rawTitle) in cached
            where titles[id] == nil {
                if let title = CommentComicTitleNormalization.value(
                    from: rawTitle,
                    comicID: id
                ) {
                    titles[id] = title
                }
            }
        }

        let missingIDs = comicIDs.filter { titles[$0] == nil }
        let fetched = await withTaskGroup(
            of: (String, String)?.self,
            returning: [String: String].self
        ) { group in
            for id in missingIDs {
                group.addTask { @MainActor [gate] in
                    guard !Task.isCancelled else { return nil }
                    await gate.acquire()
                    guard !Task.isCancelled else {
                        await gate.release()
                        return nil
                    }
                    do {
                        let detail = try await api.comic(id: id)
                        await gate.release()
                        guard !Task.isCancelled,
                              let title = CommentComicTitleNormalization.value(
                                from: detail.name,
                                comicID: id
                              ) else { return nil }
                        return (id, title)
                    } catch {
                        await gate.release()
                        return nil
                    }
                }
            }
            var values: [String: String] = [:]
            for await result in group {
                if let (id, title) = result { values[id] = title }
                if Task.isCancelled { group.cancelAll() }
            }
            return values
        }
        for (id, title) in fetched {
            titles[id] = title
        }
        if !fetched.isEmpty {
            try? await CommentComicTitleStore.shared.cache(fetched)
        }
        return titles
    }
}

enum MyCommentsInitialLoadPolicy {
    static func shouldLoad(
        requestedUserID: String,
        activeUserID: String?,
        hasLoaded: Bool
    ) -> Bool {
        let requested = requestedUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return false }
        let active = activeUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return active != requested || !hasLoaded
    }
}

@MainActor
private final class MyCommentsViewModel: ObservableObject {
    @Published var comments: [ComicComment] = []
    @Published var total = 0
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var hasMore = true
    @Published var error: String?
    @Published var resolvingComicIDs: Set<String> = []
    private var nextPage = 1
    private var activeUserID: String?
    private var requestGeneration = 0
    private var titleResolutionGeneration = 0
    private var titleResolutionTask: Task<Void, Never>?

    deinit {
        titleResolutionTask?.cancel()
    }

    /// SwiftUI restarts a view-bound `.task` after returning from a pushed
    /// detail page. Keep the existing rows in that case so `List` can retain
    /// its exact scroll position; first entry and account changes still load
    /// page one normally.
    func loadInitialIfNeeded(userID: String, api: APIClient) async {
        guard MyCommentsInitialLoadPolicy.shouldLoad(
            requestedUserID: userID,
            activeUserID: activeUserID,
            hasLoaded: hasLoaded
        ) else { return }
        await load(userID: userID, api: api)
    }

    func load(userID: String, api: APIClient, reset: Bool = false) async {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty else { return }
        if activeUserID != normalizedUserID {
            activeUserID = normalizedUserID
            requestGeneration &+= 1
            comments = []
            total = 0
            nextPage = 1
            hasMore = true
            hasLoaded = false
            error = nil
            invalidateTitleResolution()
            // Invalidate an old account's request even if its network task has
            // not observed Swift cancellation yet.
            isLoading = false
        }
        if reset {
            // Pull-to-refresh must replace an in-flight pagination request,
            // not silently return while the older page is still loading.
            requestGeneration &+= 1
            nextPage = 1
            hasMore = true
            error = nil
            invalidateTitleResolution()
            isLoading = false
        }
        guard !isLoading, reset || hasMore else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        defer {
            if activeUserID == normalizedUserID,
               requestGeneration == generation {
                isLoading = false
            }
        }
        let requestedPage = reset ? 1 : nextPage
        do {
            let result = try await api.userComments(
                userID: normalizedUserID,
                page: requestedPage
            )
            guard activeUserID == normalizedUserID,
                  requestGeneration == generation,
                  !Task.isCancelled else { return }
            let base = reset ? [] : comments
            var seen = Set(base.map(\.id))
            let additions = result.comments.filter { seen.insert($0.id).inserted }
            comments = base + additions
            total = max(result.total, comments.count)
            nextPage = requestedPage + 1
            // A repeated or empty page must terminate pagination even when the
            // server reports a stale total; otherwise the last row loops forever.
            hasMore = !result.comments.isEmpty
                && !additions.isEmpty
                && (result.total <= 0 || comments.count < result.total)
            error = nil
            hasLoaded = true
            scheduleTitleResolution(
                userID: normalizedUserID,
                api: api
            )
        } catch is CancellationError {
            return
        } catch {
            guard activeUserID == normalizedUserID,
                  requestGeneration == generation else { return }
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }

    private func scheduleTitleResolution(
        userID: String,
        api: APIClient
    ) {
        let snapshot = comments
        let missingIDs = Set(snapshot.compactMap { comment -> String? in
            let id = comment.comicID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CommentComicTitleNormalization.value(
                from: comment.comicName,
                comicID: id
            ) == nil else {
                return nil
            }
            return id.isEmpty ? nil : id
        })
        resolvingComicIDs = missingIDs
        titleResolutionGeneration &+= 1
        let titleGeneration = titleResolutionGeneration
        titleResolutionTask?.cancel()
        titleResolutionTask = Task { [weak self] in
            let titles = await CommentComicTitleResolver.shared.resolve(
                comments: snapshot,
                api: api
            )
            guard let self,
                  !Task.isCancelled,
                  self.activeUserID == userID,
                  self.titleResolutionGeneration == titleGeneration else { return }
            self.comments = self.comments.map { comment in
                var updated = comment
                let id = comment.comicID.trimmingCharacters(in: .whitespacesAndNewlines)
                if CommentComicTitleNormalization.value(
                    from: comment.comicName,
                    comicID: id
                ) == nil,
                   let title = titles[id] {
                    updated.comicName = title
                }
                return updated
            }
            self.resolvingComicIDs = []
        }
    }

    private func invalidateTitleResolution() {
        titleResolutionGeneration &+= 1
        titleResolutionTask?.cancel()
        titleResolutionTask = nil
        resolvingComicIDs = []
    }
}

struct CommentsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    let comicID: String
    @StateObject private var model = CommentsViewModel()
    @State private var composer: CommentComposerTarget?

    var body: some View {
        Group {
            if !model.hasLoaded && model.comments.isEmpty {
                AppLoadingView(accessibilityText: "正在载入评论")
            } else {
                List {
                    ForEach(model.comments) { comment in
                        CommentRow(comment: comment) {
                            composer = CommentComposerTarget(
                                parentID: comment.id,
                                username: comment.username
                            )
                        }
                        .commentCardListRow()
                        .onAppear {
                            if comment.id == model.comments.last?.id, model.hasMore {
                                Task {
                                    await model.load(
                                        comicID: comicID,
                                        api: api
                                    )
                                }
                            }
                        }
                    }
                    if model.isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else if let error = model.error, !model.comments.isEmpty {
                        Button {
                            Task {
                                await model.load(
                                    comicID: comicID,
                                    api: api
                                )
                            }
                        } label: {
                            Label(error, systemImage: "arrow.clockwise")
                                .font(.footnote)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .commentCardListRow(contentPadding: 12, cornerRadius: 16)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.vertical, 8, for: .scrollContent)
                .overlay {
                    if model.comments.isEmpty && !model.isLoading {
                        if let error = model.error {
                            RetryView(title: "无法载入评论", message: error) {
                                Task {
                                    await model.load(
                                        comicID: comicID,
                                        api: api,
                                        reset: true
                                    )
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "还没有评论",
                                systemImage: "bubble.left"
                            )
                        }
                    }
                }
                .refreshable {
                    await model.load(comicID: comicID, api: api, reset: true)
                }
            }
        }
        .navigationTitle("评论 · \(model.total)")
        .appPageBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { composer = CommentComposerTarget(parentID: nil, username: nil) } label: {
                    Label("发表评论", systemImage: "square.and.pencil")
                }
            }
        }
        .task(id: comicID) {
            await model.load(comicID: comicID, api: api, reset: true)
        }
        .sheet(item: $composer) { target in
            CommentComposer(comicID: comicID, target: target) {
                await model.load(comicID: comicID, api: api, reset: true)
            }
        }
    }
}

struct MyCommentsView: View {
    @EnvironmentObject private var api: APIClient
    @StateObject private var model = MyCommentsViewModel()

    var body: some View {
        Group {
            if let profile = api.profile {
                content(userID: profile.id)
            } else {
                ContentUnavailableView("请先登录", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        }
        .navigationTitle("我的评论")
        .appPageBackground()
        .task(id: api.profile?.id) {
            guard let userID = api.profile?.id else { return }
            await model.loadInitialIfNeeded(userID: userID, api: api)
        }
    }

    @ViewBuilder
    private func content(userID: String) -> some View {
        if !model.hasLoaded && model.comments.isEmpty {
            AppLoadingView(accessibilityText: "正在载入我的评论")
        } else {
            List {
                ForEach(model.comments) { comment in
                    MyCommentRow(
                        comment: comment,
                        isResolvingTitle: model.resolvingComicIDs.contains(
                            comment.comicID.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                        .commentCardListRow()
                        .onAppear {
                            if comment.id == model.comments.last?.id, model.hasMore {
                                Task { await model.load(userID: userID, api: api) }
                            }
                        }
                }
                if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if let error = model.error, !model.comments.isEmpty {
                    Button {
                        Task { await model.load(userID: userID, api: api) }
                    } label: {
                        Label(error, systemImage: "arrow.clockwise")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .commentCardListRow(contentPadding: 12, cornerRadius: 16)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 8, for: .scrollContent)
            .overlay {
                if model.comments.isEmpty && !model.isLoading {
                    if let error = model.error {
                        RetryView(title: "无法载入我的评论", message: error) {
                            Task { await model.load(userID: userID, api: api, reset: true) }
                        }
                    } else {
                        ContentUnavailableView(
                            "还没有发表过评论",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                    }
                }
            }
            .refreshable {
                await model.load(userID: userID, api: api, reset: true)
            }
        }
    }
}

private struct CommentCardListRowModifier: ViewModifier {
    let contentPadding: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .listRowInsets(
                EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private extension View {
    func commentCardListRow(
        contentPadding: CGFloat = 16,
        cornerRadius: CGFloat = 20
    ) -> some View {
        modifier(
            CommentCardListRowModifier(
                contentPadding: contentPadding,
                cornerRadius: cornerRadius
            )
        )
    }
}

private struct MyCommentRow: View {
    let comment: ComicComment
    let isResolvingTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let comic = destinationComic {
                NavigationLink(value: AppNavigationRoute.comic(comic)) {
                    HStack(spacing: 8) {
                        Label(displayTitle, systemImage: "book.closed")
                            .font(.headline)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isResolvingTitle {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在读取漫画名称")
                        }
                    }
                }
                .buttonStyle(.plain)
            } else if !comment.comicName.isEmpty {
                Label(comment.comicName, systemImage: "book.closed")
                    .font(.headline)
                    .lineLimit(2)
            }
            CommentRow(comment: comment, reply: nil)
        }
        .padding(.vertical, 4)
    }

    private var normalizedComicID: String {
        comment.comicID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedComicName: String {
        CommentComicTitleNormalization.value(
            from: comment.comicName,
            comicID: normalizedComicID
        ) ?? ""
    }

    private var displayTitle: String {
        if !normalizedComicName.isEmpty { return normalizedComicName }
        return isResolvingTitle ? "正在读取漫画名称…" : "漫画名称暂时不可用"
    }

    private var destinationComic: ComicSummary? {
        guard !normalizedComicID.isEmpty else { return nil }
        return ComicSummary(
            id: normalizedComicID,
            name: normalizedComicName.isEmpty ? "漫画详情" : normalizedComicName
        )
    }
}

private struct CommentRow: View {
    let comment: ComicComment
    let reply: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let avatar = comment.avatarPath {
                    RemoteComicImage(path: avatar).frame(width: 36, height: 36).clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text(comment.username).font(.headline)
                    Text([comment.levelName, comment.date].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let reply {
                    Button("回复", action: reply).font(.caption)
                }
            }
            Text(comment.content).textSelection(.enabled)
            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(comment.replies) { item in
                        Text("\(item.username)：\(item.content)")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if comment.likes > 0 { Label("\(comment.likes)", systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 6)
    }
}

private struct CommentComposerTarget: Identifiable {
    let id = UUID()
    let parentID: String?
    let username: String?
}

private struct CommentComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    let comicID: String
    let target: CommentComposerTarget
    let completion: () async -> Void
    @State private var content = ""
    @State private var isSending = false
    @State private var resultAlert: CommentSubmissionAlert?

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .padding()
                .appPageBackground()
                .navigationTitle(target.username.map { "回复 \($0)" } ?? "发表评论")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") { send() }
                            .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    }
                }
                .alert(item: $resultAlert) { result in
                    switch result {
                    case .success(let message):
                        Alert(
                            title: Text("评论已提交"),
                            message: Text(message),
                            dismissButton: .default(Text("好")) { dismiss() }
                        )
                    case .failure(let message):
                        Alert(
                            title: Text("发送失败"),
                            message: Text(message),
                            dismissButton: .default(Text("好"))
                        )
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        guard api.isLoggedIn else {
            resultAlert = .failure("请先登录")
            return
        }
        isSending = true
        Task {
            do {
                let message = try await api.sendComment(
                    comicID: comicID,
                    content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                    replyingTo: target.parentID
                )
                await completion()
                isSending = false
                resultAlert = .success(message)
            } catch {
                isSending = false
                resultAlert = .failure(error.localizedDescription)
            }
        }
    }
}

private enum CommentSubmissionAlert: Identifiable {
    case success(String)
    case failure(String)

    var id: String {
        switch self {
        case .success(let message): "success:\(message)"
        case .failure(let message): "failure:\(message)"
        }
    }
}
