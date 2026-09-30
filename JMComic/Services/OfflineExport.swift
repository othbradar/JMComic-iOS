import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

struct OfflineExportPage: Sendable {
    let source: URL
    let name: String
    let version: LocalPageVersion
    let size: CGSize
}
struct OfflineExportPlan: Sendable {
    let filename: String
    let pages: [OfflineExportPage]
    let missing: Int
    let localBookOnly: Bool
    var requiresPartialConsent: Bool { missing > 0 || localBookOnly }
    static func make(comic: OfflineComic, records: [OfflinePageRecord], root: URL, chapterID: String?, checkCancellation: () throws -> Void = {}) throws -> Self {
        var pages: [OfflineExportPage] = [], missing = 0
        let chapters = comic.chapters.filter { chapterID == nil || $0.id == chapterID }.sorted { ($0.sort, $0.id) < ($1.sort, $1.id) }
        guard !chapters.isEmpty else { throw ManagementError.missingPages(1) }
        guard records.count <= 50_000, chapters.reduce(0, { $0 + max(0, $1.expectedPageCount) }) <= 50_000 else { throw ManagementError.tooLarge }
        for (ordinal, chapter) in chapters.enumerated() {
            try checkCancellation()
            let byIndex = Dictionary(grouping: records.filter { $0.chapterID == chapter.id && $0.completed }, by: \.pageIndex)
            let folder = String(format: "%04d", ordinal + 1) + "-" + DownloadStorageNaming.safeComponent(chapter.title, maxUTF8Bytes: 80) + "-" + String(JMCrypto.md5(chapter.id).prefix(8))
            guard chapter.expectedPageCount > 0, chapter.expectedPageCount <= 50_000 else { missing += 1; continue }
            for index in 0..<chapter.expectedPageCount {
                try checkCancellation()
                guard let matching = byIndex[index], matching.count == 1, let record = matching.first else { missing += 1; continue }
                let source = root.appendingPathComponent(record.relativePath).standardizedFileURL
                guard source.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { missing += 1; continue }
                do {
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { missing += 1; continue }
                    let version = try LocalPageVersion.read(source)
                    let size = try ReadingImageHeader.size(url: source)
                    guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let type = CGImageSourceGetType(image), let ext = UTType(type as String)?.preferredFilenameExtension,
                          ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "tiff", "tif", "bmp"].contains(ext) else { missing += 1; continue }
                    pages.append(OfflineExportPage(source: source, name: folder + "/" + String(format: "%06d", index + 1) + "." + ext, version: version, size: size))
                } catch { missing += 1 }
            }
        }
        return Self(filename: DownloadStorageNaming.safeComponent(comic.comic.name, maxUTF8Bytes: 100) + ".cbz", pages: pages, missing: missing, localBookOnly: chapterID == nil)
    }
}

/// ZIP STORE streams unchanged source bytes in 64 KiB chunks. The archive is
/// bounded to classic ZIP limits; it never buffers all page data in memory.
enum CBZWriter {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    static func write(_ plan: OfflineExportPlan, to destination: URL, allowPartial: Bool,
                      progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws {
        guard allowPartial || !plan.requiresPartialConsent else { throw ManagementError.missingPages(max(1, plan.missing)) }
        guard !plan.pages.isEmpty, plan.pages.count <= 50_000 else { throw ManagementError.missingPages(max(1, plan.missing)) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        var completed = false
        defer { try? output.close(); if !completed { try? FileManager.default.removeItem(at: destination) } }
        var directory = Data(), offset: UInt64 = 0
        func write(_ data: Data) throws {
            guard offset + UInt64(data.count) < UInt64(UInt32.max) else { throw ManagementError.tooLarge }
            try output.write(contentsOf: data); offset += UInt64(data.count)
        }
        for (index, page) in plan.pages.enumerated() {
            try Task.checkCancellation()
            guard try LocalPageVersion.read(page.source) == page.version else { throw ManagementError.changedFile }
            let name = Data(page.name.utf8), start = offset
            var header = Data()
            header.le32(0x04034b50); header.le16(20); header.le16(0x0808); header.le16(0)
            header.le16(0); header.le16(33); header.le32(0); header.le32(0); header.le32(0)
            header.le16(UInt16(name.count)); header.le16(0); header.append(name)
            try write(header)
            let input = try FileHandle(forReadingFrom: page.source)
            var crc: UInt32 = 0xffffffff, size: UInt64 = 0
            do {
                while let data = try input.read(upToCount: 65_536), !data.isEmpty {
                    try Task.checkCancellation()
                    size += UInt64(data.count)
                    guard size < UInt64(UInt32.max) else { throw ManagementError.tooLarge }
                    for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
                    try write(data)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            guard try LocalPageVersion.read(page.source) == page.version else { throw ManagementError.changedFile }
            crc ^= 0xffffffff
            var descriptor = Data(); descriptor.le32(0x08074b50); descriptor.le32(crc); descriptor.le32(UInt32(size)); descriptor.le32(UInt32(size))
            try write(descriptor)
            directory.le32(0x02014b50); directory.le16(20); directory.le16(20); directory.le16(0x0808); directory.le16(0)
            directory.le16(0); directory.le16(33); directory.le32(crc); directory.le32(UInt32(size)); directory.le32(UInt32(size))
            directory.le16(UInt16(name.count)); directory.le16(0); directory.le16(0); directory.le16(0); directory.le16(0)
            directory.le32(0); directory.le32(UInt32(start)); directory.append(name)
            progress(index + 1, plan.pages.count)
        }
        try Task.checkCancellation()
        let directoryStart = offset
        try write(directory)
        var end = Data(); end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(plan.pages.count)); end.le16(UInt16(plan.pages.count))
        end.le32(UInt32(directory.count)); end.le32(UInt32(directoryStart)); end.le16(0)
        try write(end); try output.synchronize()
        completed = true
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}

struct ManagedShare: Identifiable {
    let id: UUID
    let url: URL
}
struct FileShareSheet: UIViewControllerRepresentable {
    let item: ManagedShare
    var onFinish: () -> Void
    func makeUIViewController(context: Context) -> Presenter { Presenter(item: item, onFinish: onFinish) }
    func updateUIViewController(_ controller: Presenter, context: Context) {}
    static func controller(item: ManagedShare, sourceView: UIView, onFinish: @escaping () -> Void) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { try? await ExportFiles.shared.finishSharing(item.id) }
            onFinish()
        }
        // The anchor belongs to the presenting hierarchy, never the presented
        // activity controller (which causes recursive popover layout on iPad).
        controller.popoverPresentationController?.sourceView = sourceView
        controller.popoverPresentationController?.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        controller.popoverPresentationController?.permittedArrowDirections = []
        return controller
    }
    final class Presenter: UIViewController, UIAdaptivePresentationControllerDelegate {
        let item: ManagedShare
        let onFinish: () -> Void
        private var shown = false
        init(item: ManagedShare, onFinish: @escaping () -> Void) {
            self.item = item; self.onFinish = onFinish
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .systemBackground }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !shown else { return }; shown = true
            let activity = FileShareSheet.controller(item: item, sourceView: view, onFinish: onFinish)
            activity.presentationController?.delegate = self
            present(activity, animated: true)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onFinish() }
    }
}

@MainActor
final class OfflineExportModel: ObservableObject {
    @Published var plan: OfflineExportPlan?
    @Published var error: String?
    @Published var working = false
    @Published var fraction = 0.0
    @Published var share: ManagedShare?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var sharedID: UUID?
    func releaseShare() {
        if let id = sharedID { Task { try? await ExportFiles.shared.finishSharing(id) } }; sharedID = nil
    }
    func prepare(downloads: DownloadManager, comicID: String, chapterID: String?) {
        guard !working else { return }
        working = true; error = nil
        work = Task {
            defer { working = false }
            do { let result = try await downloads.exportPlan(comicID: comicID, chapterID: chapterID); try Task.checkCancellation(); plan = result }
            catch { if !APIClient.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    func export(allowPartial: Bool) {
        guard let plan, !working else { return }
        working = true; fraction = 0; error = nil
        generation = UUID(); let token = generation
        work = Task {
            var lease: UUID?
            defer { working = false }
            do {
                let (id, directory) = try await ExportFiles.shared.begin(); lease = id
                let prefix = allowPartial && plan.requiresPartialConsent ? "部分-" : ""
                let url = directory.appendingPathComponent(prefix + plan.filename)
                let owner = self
                let worker = Task.detached(priority: .utility) {
                    try CBZWriter.write(plan, to: url, allowPartial: allowPartial) { done, total in
                        guard done == total || done % max(1, total / 100) == 0 else { return }
                        Task { @MainActor in if owner.generation == token { owner.fraction = Double(done) / Double(total) } }
                    }
                }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                sharedID = id; share = ManagedShare(id: id, url: url)
            } catch {
                if let lease { try? await ExportFiles.shared.discard(lease) }
                if !APIClient.isCancellation(error) { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { generation = UUID(); work?.cancel() }
}

struct OfflineExportView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var model = OfflineExportModel()
    let comicID: String
    let chapterID: String?
    @State private var partialConsent = false
    var body: some View {
        Form {
            if let plan = model.plan {
                Section("导出预检") {
                    LabeledContent("可用图片", value: "\(plan.pages.count) 页")
                    LabeledContent("缺失或无效", value: "\(plan.missing) 页")
                    Text("仅复制已有本地图片，保留原始格式与字节，不联网、不重编码。")
                    if plan.localBookOnly { Text("此书的完整服务器章节目录未保存。本包仅含本地登记章节，不能据此声称网站整本齐全。") }
                    if plan.requiresPartialConsent { Toggle("同意仅导出预检列出的本地内容", isOn: $partialConsent) }
                    Button(plan.requiresPartialConsent ? "导出本地内容 CBZ" : "完整导出章节 CBZ") { model.export(allowPartial: partialConsent) }
                        .disabled(model.working || plan.pages.isEmpty || (plan.requiresPartialConsent && !partialConsent))
                }
            }
            if model.working {
                ProgressView(value: model.fraction)
                Button("取消导出", role: .cancel) { model.cancel() }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("导出图片")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
        .task { model.prepare(downloads: downloads, comicID: comicID, chapterID: chapterID) }
        .onDisappear { if model.share == nil { model.cancel() } }
        .sheet(item: $model.share, onDismiss: model.releaseShare) { item in FileShareSheet(item: item) { model.share = nil } }
    }
}
