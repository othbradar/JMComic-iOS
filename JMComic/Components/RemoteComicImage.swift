import SwiftUI
import UIKit

struct RemoteComicImage: View {
    @EnvironmentObject private var api: APIClient
    let path: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retryID = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let error {
                Button {
                    self.error = nil
                    retryID &+= 1
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("点击重试").font(.caption)
                        Text(error).font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
                }
            }
        }
        .task(id: "\(path)#\(retryID)") { await load() }
    }

    private func load() async {
        guard !path.isEmpty else { return }
        do {
            let loaded = try await api.displayImage(path: path)
            guard !Task.isCancelled else { return }
            image = loaded
            error = nil
        } catch {
            // SwiftUI 在滚出 Lazy 容器时会正常取消 task，不应把它渲染成加载失败。
            guard !APIClient.isCancellation(error), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

struct ComicCoverView: View {
    let comic: ComicSummary

    var body: some View {
        RemoteComicImage(path: comic.coverPath)
            .aspectRatio(0.72, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 0.5)
            }
    }
}

/// Persists one deterministic physical cover per comic ID while allowing
/// downloads, every favorite account, and reading history to reference it.
/// Work is keyed only by comic ID, so simultaneous appearances share network,
/// full decode, JPEG encoding, and atomic disk publication.
@MainActor
private final class ComicCoverCacheCoordinator {
    private struct Work {
        let token: UUID
        let task: Task<UIImage?, Never>
    }

    static let shared = ComicCoverCacheCoordinator()
    private var works: [String: Work] = [:]
    private let documentsRoot = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )[0]

    func ensureFavoriteCover(
        accountID: String,
        comic: ComicSummary,
        storedRelativePath: String?,
        api: APIClient
    ) async -> UIImage? {
        guard !accountID.isEmpty, let database = JMComicDatabase.shared else { return nil }

        let indexedPath = storedRelativePath
            ?? (try? database.favoriteComicCoverRelativePath(
                accountID: accountID,
                comicID: comic.id
            ))
        if let indexedPath {
            if let url = JMComicCoverCacheStorage.fileURL(
                relativePath: indexedPath,
                documentsRoot: documentsRoot
            ), let image = await Self.decodedImage(at: url) {
                return image
            }
            invalidate(relativePath: indexedPath)
        }

        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: comic.id)
        guard let image = await sharedCoverImage(for: comic, api: api) else { return nil }
        indexFavoriteCover(
            database: database,
            accountID: accountID,
            comicID: comic.id,
            relativePath: relativePath
        )
        return image
    }

    func loadHistoryCoverImage(
        comic: ComicSummary,
        storedRelativePath: String?,
        api: APIClient
    ) async -> UIImage? {
        guard let database = JMComicDatabase.shared else { return nil }

        let indexedPath = storedRelativePath
            ?? (try? database.readingHistoryCoverRelativePath(comicID: comic.id))
        if let indexedPath {
            if let url = JMComicCoverCacheStorage.fileURL(
                relativePath: indexedPath,
                documentsRoot: documentsRoot
            ), let image = await Self.decodedImage(at: url) {
                return image
            }
            invalidate(relativePath: indexedPath)
        }

        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: comic.id)
        if let destination = JMComicCoverCacheStorage.fileURL(
            relativePath: relativePath,
            documentsRoot: documentsRoot
        ), let image = await Self.decodedImage(at: destination) {
            indexHistoryCover(
                database: database,
                comicID: comic.id,
                relativePath: relativePath
            )
            return image
        }

        guard let image = await sharedCoverImage(for: comic, api: api) else { return nil }
        indexHistoryCover(
            database: database,
            comicID: comic.id,
            relativePath: relativePath
        )
        return image
    }

    private func indexFavoriteCover(
        database: OfflineLibraryDatabase,
        accountID: String,
        comicID: String,
        relativePath: String
    ) {
        do {
            guard try database.favoriteComicCoverRelativePath(
                accountID: accountID,
                comicID: comicID
            ) != relativePath else { return }
            try database.setFavoriteComicCoverRelativePath(
                accountID: accountID,
                comicID: comicID,
                relativePath: relativePath
            )
        } catch {
            NSLog(
                "[JMComic] Favorite cover index failed for %@/%@: %@",
                accountID,
                comicID,
                error.localizedDescription
            )
        }
    }

    private func indexHistoryCover(
        database: OfflineLibraryDatabase,
        comicID: String,
        relativePath: String
    ) {
        do {
            try database.setReadingHistoryCoverRelativePath(
                comicID: comicID,
                relativePath: relativePath
            )
        } catch {
            NSLog(
                "[JMComic] Reading history cover index failed for %@: %@",
                comicID,
                error.localizedDescription
            )
        }
    }

    private func sharedCoverImage(for comic: ComicSummary, api: APIClient) async -> UIImage? {
        if let existing = works[comic.id] {
            return await existing.task.value
        }
        let token = UUID()
        let task = Task<UIImage?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer {
                if self.works[comic.id]?.token == token {
                    self.works[comic.id] = nil
                }
            }
            return await self.persistCoverImage(for: comic, api: api, token: token)
        }
        works[comic.id] = Work(token: token, task: task)
        return await task.value
    }

    private func persistCoverImage(
        for comic: ComicSummary,
        api: APIClient,
        token: UUID
    ) async -> UIImage? {
        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: comic.id)
        guard let destination = JMComicCoverCacheStorage.fileURL(
            relativePath: relativePath,
            documentsRoot: documentsRoot
        ) else { return nil }
        if let image = await Self.decodedImage(at: destination) {
            return image
        }

        do {
            let image = try await api.displayImage(path: comic.coverPath)
            guard works[comic.id]?.token == token else { return nil }
            let data = try await Task.detached(priority: .utility) { () throws -> Data in
                guard let encoded = image.jpegData(compressionQuality: 0.94), !encoded.isEmpty else {
                    throw ImageScrambler.ImageError.encodeFailed
                }
                return encoded
            }.value
            guard works[comic.id]?.token == token else { return nil }
            try await Task.detached(priority: .utility) {
                let manager = FileManager.default
                let directory = destination.deletingLastPathComponent()
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try? manager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: directory.path
                )
                try data.write(to: destination, options: .atomic)
            }.value
            return image
        } catch {
            guard !APIClient.isCancellation(error) else { return nil }
            NSLog(
                "[JMComic] Persistent cover cache failed for %@: %@",
                comic.id,
                error.localizedDescription
            )
            return nil
        }
    }

    private func invalidate(relativePath: String) {
        guard JMComicCoverCacheStorage.isSafeRelativePath(relativePath),
              let url = JMComicCoverCacheStorage.fileURL(
                relativePath: relativePath,
                documentsRoot: documentsRoot
              ) else { return }
        if let database = JMComicDatabase.shared {
            try? database.clearCoverRelativePathReferences(relativePath)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func decodedImage(at url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  APIClient.isLikelyImageData(data, contentType: nil) else { return nil }
            return try? ImageScrambler.rasterImage(from: data)
        }.value
    }
}

/// Favorite-only disk-backed cover. It remains a passive image inside the
/// grid's existing NavigationLink, so caching never adds another tap target or
/// changes iPhone/iPad navigation behavior.
struct FavoriteComicCoverView: View {
    @EnvironmentObject private var api: APIClient
    let accountID: String
    let comic: ComicSummary
    let storedRelativePath: String?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(0.72, contentMode: .fill)
            } else if failed {
                VStack(spacing: 5) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("封面暂不可用").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
                }
            }
        }
        .aspectRatio(0.72, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .task(id: "\(accountID):\(comic.id):\(storedRelativePath ?? "")") {
            await load()
        }
    }

    private func load() async {
        failed = false
        let loaded = await ComicCoverCacheCoordinator.shared.ensureFavoriteCover(
            accountID: accountID,
            comic: comic,
            storedRelativePath: storedRelativePath,
            api: api
        )
        guard let loaded else {
            guard !Task.isCancelled else { return }
            failed = true
            return
        }
        guard !Task.isCancelled else { return }
        image = loaded
        failed = false
    }
}

/// Disk-backed cover for rows returned by `ReadingHistoryDatabase`. The caller
/// supplies the indexed relative path, so a valid file is decoded without a
/// network request; missing or corrupt files are rebuilt once through the same
/// per-comic coordinator used by favorite covers.
struct ReadingHistoryComicCoverView: View {
    @EnvironmentObject private var api: APIClient
    let comic: ComicSummary
    let storedRelativePath: String?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryID = 0

    init(entry: ReadingHistoryEntry) {
        comic = entry.comic
        storedRelativePath = entry.coverRelativePath
    }

    init(comic: ComicSummary, storedRelativePath: String?) {
        self.comic = comic
        self.storedRelativePath = storedRelativePath
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(0.72, contentMode: .fill)
            } else if failed {
                Button {
                    failed = false
                    retryID &+= 1
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("点击重试").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
                }
            }
        }
        .aspectRatio(0.72, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .task(id: "\(comic.id):\(storedRelativePath ?? ""):\(retryID)") {
            await load()
        }
    }

    private func load() async {
        image = nil
        failed = false
        let loaded = await ComicCoverCacheCoordinator.shared.loadHistoryCoverImage(
            comic: comic,
            storedRelativePath: storedRelativePath,
            api: api
        )
        guard let loaded else {
            guard !Task.isCancelled else { return }
            failed = true
            return
        }
        guard !Task.isCancelled else { return }
        image = loaded
        failed = false
    }
}

/// Cover used by the offline library. It never falls back to the ordinary
/// remote-image view: a missing legacy cache is filled once and then every
/// later appearance decodes the visible Documents/cache file directly.
struct OfflineComicCoverView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var downloads: DownloadManager
    let item: OfflineComic
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(0.72, contentMode: .fill)
            } else if error != nil {
                VStack(spacing: 5) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("封面暂不可用").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .task(id: item.id) {
            await load()
        }
    }

    private func load() async {
        image = nil
        error = nil

        if let local = downloads.localCoverURL(for: item) {
            if let loaded = await decodedImage(at: local) {
                guard !Task.isCancelled else { return }
                image = loaded
                return
            }
            guard !Task.isCancelled else { return }
            await downloads.invalidateCachedCover(comicID: item.id, expectedURL: local)
        }

        // A corrupt legacy/local file is invalidated above and gets exactly
        // one automatic network retry. If that freshly persisted JPEG still
        // cannot decode, invalidate it and keep this cover as one unambiguous
        // navigation target rather than nesting a retry Button inside its
        // enclosing NavigationLink.
        let url = await downloads.ensureCoverCached(for: item.comic, api: api)
        guard let url else {
            guard !Task.isCancelled else { return }
            error = "封面缓存失败"
            return
        }
        let loaded = await decodedImage(at: url)
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            error = nil
        } else {
            await downloads.invalidateCachedCover(comicID: item.id, expectedURL: url)
            error = "封面缓存无法读取"
        }
    }

    private func decodedImage(at url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? ImageScrambler.rasterImage(from: data)
        }.value
    }
}
