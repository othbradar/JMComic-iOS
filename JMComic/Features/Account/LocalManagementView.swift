import SwiftUI
import UniformTypeIdentifiers

struct LocalManagementLinks: View {
    var body: some View {
        Section("本地管理与隐私") {
            NavigationLink("缓存空间与清理") { StorageManagementView() }
            NavigationLink("屏蔽标签") { BlockedTagsView() }
            NavigationLink("应用锁") { AppLockSettingsView() }
            NavigationLink("轻量备份与恢复") { BackupManagementView() }
        }
    }
}

struct StorageManagementView: View {
    @EnvironmentObject private var api: APIClient
    @State private var usage: StorageUsage?
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("本机磁盘空间") {
                row("可重建网络 / 图片缓存", bytes: usage?.network)
                row("用户下载图片", bytes: usage?.downloads)
                row("离线索引与持久封面（保留）", bytes: usage?.protectedFiles)
                row("导出临时文件", bytes: usage?.exports)
                Button("刷新统计") { Task { await refresh() } }.disabled(busy)
                if busy { ProgressView() }
            }
            Section {
                Button("清理缓存") {
                    Task {
                        busy = true
                        await api.clearRebuildableImageCaches()
                        await StorageInventory.shared.invalidate()
                        message = "已清理可重建缓存。下载图片、离线索引、封面、进度和账号均保留。"
                        await refresh(force: true)
                    }
                }.disabled(busy)
                Text("磁盘统计不包含内存缓存；清理也会释放未被阅读页面使用的内存图片。正在使用的图片可继续显示。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("清理过期导出文件") {
                    Task {
                        do { try await ExportFiles.shared.cleanup(); message = "已清理过期文件；制作中、分享中及分享后 10 分钟内的文件会保留。" }
                        catch { message = error.localizedDescription }
                        await refresh(force: true)
                    }
                }.disabled(busy)
                NavigationLink("删除用户下载…") { DownloadRemovalView() }
            }
            if let message { Text(message).font(.footnote) }
        }.navigationTitle("缓存空间与清理").appPageBackground()
            .task { await refresh() }
    }
    private func row(_ title: String, bytes: Int64?) -> some View {
        LabeledContent(title, value: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "待统计")
    }
    private func refresh(force: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            usage = try await StorageInventory.shared.usage(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], exports: ExportFiles.shared.root, force: force)
        } catch { message = error.localizedDescription }
    }
}

private struct DownloadRemovalView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var pending: OfflineComic?
    @State private var error: String?
    @State private var deleting = false
    var body: some View {
        List {
            Text("这里会删除选中书籍的离线图片及下载索引。阅读进度保留；恢复图片需要重新下载。")
            ForEach(downloads.library) { book in
                HStack {
                    Text(book.comic.name)
                    Spacer()
                    Button("删除", role: .destructive) { pending = book }.disabled(deleting)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("删除用户下载").appPageBackground()
            .confirmationDialog("删除 \(pending?.comic.name ?? "") 的下载？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let book = pending {
                    Button("删除离线图片", role: .destructive) {
                        Task {
                            deleting = true; defer { deleting = false }
                            do { try await downloads.delete(comicID: book.id); await StorageInventory.shared.invalidate() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
    }
}

struct BlockedTagsView: View {
    @ObservedObject private var blocked = BlockedTagsStore.shared
    @State private var tag = ""
    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("完整标签名称", text: $tag).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") { blocked.add(tag); tag = "" }
                        .disabled(BlockedTagsStore.normalize(tag).isEmpty || tag.utf8.count > 256 || blocked.tags.count >= 200)
                }
                Text("仅按列表实际提供的标签精确匹配，忽略大小写和多余空白。作用于发现、推荐、最新与搜索；缺少标签的项目仍显示。收藏、历史和下载不隐藏。最多 200 条。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("已屏蔽 \(blocked.tags.count) 条") {
                ForEach(blocked.tags, id: \.self) { value in
                    HStack { Text(value); Spacer(); Button("移除", role: .destructive) { blocked.remove(value) } }
                }
            }
        }.navigationTitle("屏蔽标签").appPageBackground()
    }
}

struct AppLockSettingsView: View {
    @EnvironmentObject private var lock: AppLockSession
    var body: some View {
        Form {
            Toggle("启用应用锁", isOn: Binding(get: { lock.state.enabled }, set: { enabled in Task { await lock.setEnabled(enabled) } }))
                .disabled(lock.authenticating)
            Text("开启与关闭均需系统身份验证。启用后每次退到后台再返回时验证，可使用生物识别或设备密码。取消或失败可重试。")
            Text("切换应用时遮挡内容。应用锁仅限制界面访问，不会加密图片或数据库，也不会退出账号或删除下载。")
                .font(.footnote).foregroundStyle(.secondary)
            if lock.authenticating { ProgressView("正在验证") }
            if let error = lock.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("应用锁").appPageBackground()
    }
}

struct BackupManagementView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var progress: ReadingProgressStore
    @EnvironmentObject private var appearance: AppAppearanceStore
    @ObservedObject private var coordinator = BackupCoordinator.shared
    @State private var importing = false
    @State private var preview: LocalBackup?
    @State private var message: String?
    @State private var working = false
    @State private var share: ManagedShare?
    @State private var sharedID: UUID?
    @State private var exportTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Button("导出轻量备份") { exportTask = Task { await export() } }.disabled(working || coordinator.busy)
                Button("选择备份文件…") { importing = true }.disabled(working || coordinator.busy)
                Text("包含各章进度、非敏感设置、屏蔽标签与本地书目资料。不包含图片、密码、Cookie、Token 或应用锁状态。请将文件交给可信的接收方。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let backup = preview {
                Section("导入预检 · 版本 \(backup.schemaVersion)") {
                    LabeledContent("章节进度", value: "\(backup.progress.values.reduce(0) { $0 + $1.count }) 条")
                    LabeledContent("非敏感设置", value: "\(backup.settings.count) 项")
                    LabeledContent("屏蔽标签", value: "\(backup.blockedTags.count) 条")
                    LabeledContent("书目资料", value: "\(backup.books.count) 本")
                    Text("确认后合并：各章进度保留较新记录；已有设置优先；标签和书目取并集。书目没有图片，不会变成已下载，不会自动联网下载。")
                    Button("确认安全合并") { Task { await merge(backup) } }.disabled(working || coordinator.busy)
                    Button("取消导入", role: .cancel) { preview = nil }
                }
            }
            if working || coordinator.busy { ProgressView() }
            if let message { Text(message).font(.footnote) }
            if let error = coordinator.recoveryError { Text(error).foregroundStyle(.red) }
            if !coordinator.restoredBooks.isEmpty {
                Section("已恢复书目资料（不代表已下载）") {
                    ForEach(coordinator.restoredBooks) { book in
                        NavigationLink { ComicDetailView(comicID: book.id, initialComic: book.comic) } label: {
                            VStack(alignment: .leading) { Text(book.comic.name); Text("书目资料 · 离线状态以下载页的实际文件为准").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.navigationTitle("轻量备份与恢复").appPageBackground()
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                Task {
                    working = true; preview = nil; defer { working = false }
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        preview = try await Task.detached(priority: .utility) { try LocalBackup.read(url) }.value
                        message = nil
                    } catch { message = error.localizedDescription }
                }
            }
            .onDisappear { if share == nil { exportTask?.cancel() } }
            .sheet(item: $share, onDismiss: releaseShare) { item in FileShareSheet(item: item) { share = nil } }
    }
    private func releaseShare() {
        if let id = sharedID { Task { try? await ExportFiles.shared.finishSharing(id) } }; sharedID = nil
    }
    private func merge(_ backup: LocalBackup) async {
        working = true; defer { working = false }
        do {
            try await coordinator.merge(backup, progress: progress, blocked: .shared)
            appearance.reloadFromDefaults()
            preview = nil; message = "合并完成。书目资料不会创建已完成下载。"
        } catch { message = error.localizedDescription }
    }
    private func export() async {
        working = true; defer { working = false }
        let books = LocalBackup.mergeBooks(downloads.library.map(BackupBook.init), into: coordinator.restoredBooks)
        let backup = LocalBackup(progress: progress.chapters, settings: LocalBackup.settings(defaults: .standard), blockedTags: BlockedTagsStore.shared.tags, books: books)
        var lease: UUID?
        do {
            let (id, directory) = try await ExportFiles.shared.begin(); lease = id
            let url = directory.appendingPathComponent("JMComic-轻量备份.json")
            try await Task.detached(priority: .utility) {
                try backup.validate()
                let data = try JSONEncoder().encode(backup)
                guard data.count <= LocalBackup.maximumBytes else { throw ManagementError.tooLarge }
                try data.write(to: url, options: .atomic)
            }.value
            try Task.checkCancellation()
            sharedID = id; share = ManagedShare(id: id, url: url)
        } catch {
            if let lease { try? await ExportFiles.shared.discard(lease) }
            message = error.localizedDescription
        }
    }
}
