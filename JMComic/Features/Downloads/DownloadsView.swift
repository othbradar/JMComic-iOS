import SwiftUI

private enum OfflineLibrarySort: String, CaseIterable, Identifiable {
    case added = "加入先后"
    case folder = "收藏夹"
    case name = "名称"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .added: "clock.arrow.circlepath"
        case .folder: "folder"
        case .name: "textformat"
        }
    }
}

private struct OfflineLibrarySection: Identifiable {
    let id: String
    let title: String
    let sort: Int
    var comics: [OfflineComic]
}

/// The download tab owns an explicit path so a pushed download screen can
/// exclusively handle the system interactive-pop gesture.  A closure-style
/// `NavigationLink` does not expose that state to `RootView`, which allowed
/// the root-tab swipe recognizer underneath it to switch to Favorites.
enum DownloadsRoute: Hashable {
    case tasks
    case offlineComic(OfflineComic)
    case comicDetail(ComicSummary)
}

enum DownloadsNavigationPolicy {
    static func allowsRootTabSwipe(pathCount: Int) -> Bool {
        pathCount == 0
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var downloads: DownloadManager
    @Binding var navigationPath: NavigationPath
    @AppStorage("downloads.librarySort") private var selectedSort = OfflineLibrarySort.added.rawValue
    @AppStorage(InterfacePreferences.showExplanatoryTextKey)
    private var showsExplanatoryText = false
    @State private var deleting: OfflineComic?
    @State private var deleteError: String?
    @State private var folderAssignments: [String: OfflineFavoriteFolderAssignment] = [:]

    private var sort: OfflineLibrarySort {
        OfflineLibrarySort(rawValue: selectedSort) ?? .added
    }

    private var assignmentRefreshID: String {
        let comicIDs = downloads.library.map(\.id).sorted().joined(separator: ",")
        return "\(api.profile?.id ?? "logged-out"):\(comicIDs)"
    }

    var body: some View {
        List {
            // Use a content-owned large heading while the real navigation bar
            // stays inline. Both the root and task destinations therefore have
            // the exact same fixed bar height during push/pop, but the download
            // landing page keeps its original prominent title.
            RootPageLargeTitleRow(title: "下载")

            if downloads.library.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有离线漫画",
                        systemImage: "arrow.down.circle",
                        description: showsExplanatoryText
                            ? Text("在漫画详情页选择章节下载")
                            : nil
                    )
                } footer: {
                    storageFooter
                }
            } else if sort == .folder {
                let sections = folderSections
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    Section {
                        ForEach(section.comics) { item in
                            offlineComicRow(item)
                        }
                    } header: {
                        Label(section.title, systemImage: section.id == "__unclassified__" ? "tray" : "folder")
                    } footer: {
                        if index == sections.count - 1 { storageFooter }
                    }
                }
            } else {
                Section {
                    ForEach(sortedLibrary) { item in
                        offlineComicRow(item)
                    }
                } header: {
                    Text("离线漫画")
                } footer: {
                    storageFooter
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
        .toolbar {
            // Preserve "下载" as the back-button/accessibility title without
            // drawing a duplicate inline title above the content heading.
            ToolbarItem(placement: .principal) {
                Text("").accessibilityHidden(true)
            }
            RootPageTrailingActions(count: 2) {
                Menu {
                    Picker("离线漫画排序", selection: $selectedSort) {
                        ForEach(OfflineLibrarySort.allCases) { option in
                            Label(option.rawValue, systemImage: option.systemImage)
                                .tag(option.rawValue)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("离线漫画排序：\(sort.rawValue)")

                NavigationLink(value: DownloadsRoute.tasks) {
                    Label("下载任务", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .task(id: assignmentRefreshID) {
            reloadFolderAssignments()
        }
        .onAppear {
            if sort == .folder { reloadFolderAssignments() }
        }
        .onChange(of: selectedSort) { _, newValue in
            if newValue == OfflineLibrarySort.folder.rawValue {
                reloadFolderAssignments()
            }
        }
        .confirmationDialog("删除“\(deleting?.comic.name ?? "")”的全部离线文件？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let item = deleting else { return }
                deleting = nil
                Task {
                    do {
                        try await downloads.delete(comicID: item.id)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "未知错误")
        }
        .navigationDestination(for: DownloadsRoute.self) { route in
            switch route {
            case .tasks:
                DownloadTasksView()
            case let .offlineComic(item):
                OfflineComicView(item: item)
            case let .comicDetail(comic):
                ComicDetailView(comicID: comic.id, initialComic: comic)
            }
        }
        // A detail opened from a downloaded cover can continue into author/tag
        // searches and recommended comics. The owning NavigationStack uses a
        // heterogeneous NavigationPath, so register the shared route family in
        // the same stack instead of leaving those links without a destination.
        .appNavigationDestinations()
    }

    private var sortedLibrary: [OfflineComic] {
        downloads.library.sorted { lhs, rhs in
            switch sort {
            case .added, .folder:
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.id < rhs.id
            case .name:
                let comparison = lhs.comic.name.localizedStandardCompare(rhs.comic.name)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
        }
    }

    private var folderSections: [OfflineLibrarySection] {
        var sections: [String: OfflineLibrarySection] = [:]
        for comic in downloads.library {
            let assignment = folderAssignments[comic.id]
            let id = assignment?.folderID ?? "__unclassified__"
            let title = assignment?.folderName ?? "未归类"
            let sectionSort = assignment?.sort ?? .max
            if sections[id] == nil {
                sections[id] = OfflineLibrarySection(
                    id: id,
                    title: title,
                    sort: sectionSort,
                    comics: []
                )
            }
            sections[id]?.comics.append(comic)
        }
        return sections.values
            .map { section in
                var section = section
                section.comics.sort {
                    let comparison = $0.comic.name.localizedStandardCompare($1.comic.name)
                    return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                }
                return section
            }
            .sorted {
                if $0.sort != $1.sort { return $0.sort < $1.sort }
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    @ViewBuilder
    private func offlineComicRow(_ item: OfflineComic) -> some View {
        HStack(spacing: 10) {
            Button {
                navigationPath.append(DownloadsRoute.comicDetail(item.comic))
            } label: {
                OfflineComicCoverView(item: item)
                    .frame(width: 62, height: 86)
                    .contentShape(Rectangle())
            }
            // A borderless button is an independent control inside List. Using
            // a second NavigationLink here made SwiftUI promote both links to
            // row actions, append both routes, and draw two disclosure arrows.
            .buttonStyle(.borderless)
            .accessibilityLabel("查看“\(item.comic.name)”的漫画详情")

            NavigationLink(value: DownloadsRoute.offlineComic(item)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.comic.name).font(.headline).lineLimit(2)
                    Text("\(item.chapters.count) 个章节").font(.caption).foregroundStyle(.secondary)
                    if sort == .folder {
                        Text(folderAssignments[item.id]?.folderName ?? "未归类")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看“\(item.comic.name)”的离线章节")

            Menu {
                Button("删除离线漫画", systemImage: "trash", role: .destructive) {
                    deleting = item
                }
                .disabled(downloads.deletingComicIDs.contains(item.id))
            } label: {
                if downloads.deletingComicIDs.contains(item.id) {
                    ProgressView()
                        .frame(width: 36, height: 44)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 36, height: 44)
                }
            }
            .buttonStyle(.borderless)
            .disabled(downloads.deletingComicIDs.contains(item.id))
            .accessibilityLabel("管理“\(item.comic.name)”")
        }
    }

    @ViewBuilder
    private var storageFooter: some View {
        if showsExplanatoryText {
            Text("漫画文件：文件 App → 我的 iPhone / iPad → JMComic → download → 漫画名-作者名 → 章节\n封面缓存：JMComic → cache\n数据库：JMComic → database → JMComic.db")
        }
    }

    private func reloadFolderAssignments() {
        guard let accountID = api.profile?.id else {
            folderAssignments = [:]
            return
        }
        folderAssignments = downloads.favoriteFolderAssignments(accountID: accountID)
    }
}

private struct DownloadTasksView: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(spacing: 0) {
            // Keep the global controls in the destination's normal content
            // flow. A top `safeAreaInset` is resolved independently from the
            // navigation bar during a large-title -> inline push, so its first
            // frame can still use the source page's safe area and slide under
            // the bar. This fixed row always receives the same safe-area
            // proposal as the destination and remains below the bar from the
            // first transition frame onward.
            globalControls
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 16) {
                    taskContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle("下载任务")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
    }

    private var globalControls: some View {
        HStack(spacing: 12) {
            Button {
                downloads.resumeAllDownloads()
            } label: {
                Label("开始/继续下载", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!downloads.canResumeAllDownloads)

            Button {
                downloads.pauseAllDownloads()
            } label: {
                Label("暂停下载", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(!downloads.canPauseAllDownloads)
        }
        .controlSize(.large)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var taskContent: some View {
        if downloads.progress.isEmpty {
            ContentUnavailableView(
                "还没有下载任务",
                systemImage: "list.bullet.rectangle",
                description: Text("在漫画详情页选择章节后，任务会显示在这里")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .accessibilityIdentifier("download-tasks-empty-state")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("任务")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                ForEach(downloads.progress) { item in
                    DownloadTaskRow(item: item)
                        .equatable()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                }
            }
        }
    }
}

private struct DownloadTaskRow: View, Equatable {
    let item: ChapterDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.comicName).font(.headline).lineLimit(1)
                    Text(item.chapterTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.state.rawValue)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }
            ProgressView(value: item.fraction)
            Text("\(item.completedPages) / \(item.totalPages)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch item.state {
        case .failed: .red
        case .paused: .orange
        case .preparing, .downloading, .finished: .secondary
        }
    }
}

private struct OfflineComicView: View {
    let item: OfflineComic

    var body: some View {
        List(item.chapters.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })) { chapter in
            if chapter.isComplete {
                ReaderPresentationLink(
                    comic: item.comic,
                    chapter: Chapter(id: chapter.id, title: chapter.title, sort: 1)
                ) {
                    chapterRow(chapter, complete: true)
                }
            } else {
                chapterRow(chapter, complete: false)
            }
        }
        .navigationTitle(item.comic.name)
        .appPageBackground()
    }

    private func chapterRow(_ chapter: OfflineChapter, complete: Bool) -> some View {
        HStack {
            Label(chapter.title, systemImage: complete ? "checkmark.circle.fill" : "clock")
            Spacer()
            Text(complete ? "\(chapter.relativePagePaths.count) 页" : "\(chapter.relativePagePaths.count) / \(chapter.expectedPageCount)")
                .foregroundStyle(.secondary)
        }
    }
}
