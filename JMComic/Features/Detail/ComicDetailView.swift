import SwiftUI

@MainActor
private final class ComicDetailViewModel: ObservableObject {
    @Published var detail: ComicDetail?
    @Published var isLoading = false
    @Published var error: String?
    @Published var notice: String?

    func load(id: String, api: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await api.comic(id: id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ComicDetailView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @EnvironmentObject private var api: APIClient
    let comicID: String
    let initialComic: ComicSummary
    @StateObject private var model = ComicDetailViewModel()
    @State private var showFavorites = false
    @State private var showDownloads = false
    @State private var showComments = false

    var body: some View {
        Group {
            if let detail = model.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(detail)
                        actionBar(detail)
                        metadata(detail)
                        chapters(detail)
                        recommendations(detail)
                    }
                    .padding()
                    .frame(maxWidth: 1_100)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await model.load(id: comicID, api: api) }
            } else if model.isLoading {
                AppLoadingView(accessibilityText: "载入漫画详情")
            } else {
                RetryView(title: "无法载入详情", message: model.error ?? "未知错误") {
                    Task { await model.load(id: comicID, api: api) }
                }
            }
        }
        .navigationTitle(model.detail?.name ?? initialComic.name)
        .appPageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.detail == nil { await model.load(id: comicID, api: api) } }
        .sheet(isPresented: $showFavorites) {
            if let detail = model.detail {
                FavoritePickerSheet(detail: detail) {
                    await model.load(id: comicID, api: api)
                }
            }
        }
        .sheet(isPresented: $showDownloads) {
            if let detail = model.detail { ChapterDownloadSheet(detail: detail) }
        }
        .sheet(isPresented: $showComments) {
            NavigationStack { CommentsView(comicID: comicID) }
        }
        .alert("提示", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) { Button("好") {} } message: { Text(model.notice ?? "") }
    }

    private func header(_ detail: ComicDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                cover(detail).frame(width: 240)
                description(detail)
            }
            VStack(alignment: .leading, spacing: 18) {
                cover(detail).frame(maxWidth: 280).frame(maxWidth: .infinity)
                description(detail)
            }
        }
    }

    private func cover(_ detail: ComicDetail) -> some View {
        ComicCoverView(comic: detail.summaryModel)
    }

    private func description(_ detail: ComicDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detail.name).font(.largeTitle.bold()).textSelection(.enabled)
            if detail.authors.isEmpty {
                Text("未知作者")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(detail.authors, id: \.self) { author in
                            searchLink(author, systemImage: "person")
                                .font(.headline)
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                Label(detail.views.isEmpty ? "—" : detail.views, systemImage: "eye")
                Label(detail.likes.isEmpty ? "—" : detail.likes, systemImage: "hand.thumbsup")
                Label("\(detail.commentCount)", systemImage: "bubble.left")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if !detail.summary.isEmpty {
                Text(detail.summary).font(.body).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionBar(_ detail: ComicDetail) -> some View {
        ViewThatFits {
            HStack(spacing: 12) { actionButtons(detail) }
            VStack(spacing: 10) { actionButtons(detail) }
        }
    }

    @ViewBuilder
    private func actionButtons(_ detail: ComicDetail) -> some View {
        Button {
            if api.isLoggedIn { showFavorites = true }
            else { model.notice = "请先在“我的”页面登录" }
        } label: {
            Label(detail.isFavorite ? "管理收藏" : "加入收藏", systemImage: detail.isFavorite ? "heart.fill" : "heart")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button { showDownloads = true } label: {
            Label("下载", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button { showComments = true } label: {
            Label("评论", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func metadata(_ detail: ComicDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !detail.tags.isEmpty {
                metadataRow(title: "标签", values: detail.tags)
            }
            if !detail.works.isEmpty {
                metadataRow(title: "作品", values: detail.works)
            }
            if !detail.actors.isEmpty {
                metadataRow(title: "角色", values: detail.actors)
            }
        }
    }

    private func metadataRow(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        searchLink(value)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private func searchLink(_ query: String, systemImage: String? = nil) -> some View {
        NavigationLink(value: AppNavigationRoute.search(query)) {
            if let systemImage {
                Label(query, systemImage: systemImage)
            } else {
                Text(query)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityHint("搜索“\(query)”的漫画")
    }

    private func chapters(_ detail: ComicDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("章节（\(detail.chapters.count)）").font(.title2.bold())
            LazyVStack(spacing: 0) {
                ForEach(detail.chapters) { chapter in
                    ReaderPresentationLink(
                        comic: detail.summaryModel,
                        chapter: chapter
                    ) {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 13)
                    }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func recommendations(_ detail: ComicDetail) -> some View {
        if !detail.relatedComics.filter(blocked.allows).isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("相关推荐")
                    .font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(detail.relatedComics.filter(blocked.allows)) { comic in
                            NavigationLink(value: AppNavigationRoute.comic(comic)) {
                                VStack(alignment: .leading, spacing: 7) {
                                    ComicCoverView(comic: comic)
                                        .frame(width: 150, height: 208)
                                    Text(comic.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(comic.authorText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct ChapterDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var downloads: DownloadManager
    let detail: ComicDetail
    @State private var selection: Set<String> = []
    @State private var error: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            List(detail.chapters) { chapter in
                let isSelected = selection.contains(chapter.id)
                Button {
                    if isSelected { selection.remove(chapter.id) }
                    else { selection.insert(chapter.id) }
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(chapter.title)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chapter.title)
                .accessibilityValue(isSelected ? "已选择" : "未选择")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .appPageBackground()
            .navigationTitle("选择下载章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button(selection.count == detail.chapters.count ? "清空" : "全选") {
                        selection = selection.count == detail.chapters.count ? [] : Set(detail.chapters.map(\.id))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") { submit() }.disabled(selection.isEmpty || isSubmitting)
                }
            }
            .alert("下载失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        isSubmitting = true
        let chapters = detail.chapters.filter { selection.contains($0.id) }
        Task {
            do {
                try await downloads.enqueue(comic: detail.summaryModel, chapters: chapters, api: api)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
