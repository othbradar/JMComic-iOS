import SwiftUI

/// 发现页的可选栏目。使用与服务端 UUID 无关的稳定 id，避免刷新时菜单选中状态跳动。
struct ExploreContentSection: Identifiable, Hashable {
    let id: String
    let title: String
    let comics: [ComicSummary]

    /// `/latest` 是一个独立栏目，`/promote` 则返回多个栏目。这里只组合栏目数据，
    /// 界面每次仅显示当前选中的一项，不再把它们纵向混排在同一页。
    static func make(latest: [ComicSummary], promoted: [HomeSection]) -> [ExploreContentSection] {
        var candidates: [(title: String, comics: [ComicSummary])] = []
        // 即使服务端当前页暂无数据，也保留固定的“最新更新”入口。
        candidates.append(("最新更新", latest))
        candidates.append(contentsOf: promoted.map { section in
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.isEmpty ? "推荐" : title, section.comics)
        })

        var titleOccurrences: [String: Int] = [:]
        return candidates.map { candidate in
            let occurrence = titleOccurrences[candidate.title, default: 0]
            titleOccurrences[candidate.title] = occurrence + 1
            return ExploreContentSection(
                id: "\(candidate.title)#\(occurrence)",
                title: candidate.title,
                comics: candidate.comics
            )
        }
    }
}

@MainActor
private final class ExploreViewModel: ObservableObject {
    @Published private(set) var sections: [ExploreContentSection] = []
    @Published private(set) var selectedSectionID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?

    var selectedSection: ExploreContentSection? {
        sections.first { $0.id == selectedSectionID } ?? sections.first
    }

    func select(_ section: ExploreContentSection) {
        selectedSectionID = section.id
    }

    func load(api: APIClient) async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let previousID = selectedSectionID
        let previousTitle = selectedSection?.title
        do {
            async let promoted = api.home()
            async let latest = api.latest()
            let updatedSections = try await ExploreContentSection.make(
                latest: latest,
                promoted: promoted
            )
            sections = updatedSections
            selectedSectionID = previousID.flatMap { id in
                updatedSections.first { $0.id == id }?.id
            } ?? previousTitle.flatMap { title in
                updatedSections.first { $0.title == title }?.id
            } ?? updatedSections.first?.id
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject private var api: APIClient
    @StateObject private var model = ExploreViewModel()

    var body: some View {
        Group {
            if (!model.hasLoaded || model.isLoading) && model.sections.isEmpty {
                initialLoadingView
            } else if let error = model.error, model.sections.isEmpty {
                RetryView(title: "无法载入", message: error) {
                    Task { await model.load(api: api) }
                }
            } else if model.sections.isEmpty {
                ContentUnavailableView("暂无推荐", systemImage: "sparkles")
            } else {
                content
            }
        }
        .navigationTitle("发现")
        .appPageBackground()
        .task { if model.sections.isEmpty { await model.load(api: api) } }
    }

    /// 仅保留一个居中、无文字的系统进度环。根视图不应再叠加 bootstrap spinner。
    private var initialLoadingView: some View {
        AppLoadingView(accessibilityText: "正在载入推荐")
    }

    private var content: some View {
        VStack(spacing: 0) {
            sectionMenu

            ScrollView {
                if let section = model.selectedSection {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title)
                                .font(.title2.bold())
                            Spacer(minLength: 12)
                            Text("\(section.comics.count) 部")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if section.comics.isEmpty {
                            ContentUnavailableView("该栏目暂无漫画", systemImage: "books.vertical")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            ComicGrid(comics: section.comics)
                        }
                    }
                    .padding()
                }
            }
            .refreshable { await model.load(api: api) }
        }
    }

    /// 用点按菜单切换栏目，不使用 TabView paging 或横向 ScrollView，把左右滑动留给根栏目。
    private var sectionMenu: some View {
        Menu {
            ForEach(model.sections) { section in
                Button {
                    model.select(section)
                } label: {
                    if model.selectedSectionID == section.id {
                        Label(section.title, systemImage: "checkmark")
                    } else {
                        Text(section.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.grid.1x2")
                Text("切换栏目")
                    .fontWeight(.semibold)
                Spacer(minLength: 12)
                Text(model.selectedSection?.title ?? "选择")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换发现栏目")
        .accessibilityValue(model.selectedSection?.title ?? "")
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
