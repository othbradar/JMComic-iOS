import Foundation

typealias JSONDictionary = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String, default fallback: String = "") -> String {
        switch self[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return fallback
        }
    }

    func int(_ key: String, default fallback: Int = 0) -> Int {
        switch self[key] {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value) ?? fallback
        default: return fallback
        }
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        switch self[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return ["1", "true", "yes", "ok"].contains(value.lowercased())
        default: return fallback
        }
    }

    func dictionaries(_ key: String) -> [JSONDictionary] {
        self[key] as? [JSONDictionary] ?? []
    }

    func strings(_ key: String) -> [String] {
        if let values = self[key] as? [String] { return values }
        if let values = self[key] as? [Any] {
            return values.compactMap { value in
                if let string = value as? String { return string }
                if let number = value as? NSNumber { return number.stringValue }
                return nil
            }
        }
        let value = string(key)
        return value.isEmpty ? [] : value.split(separator: " ").map(String.init)
    }
}

struct ComicSummary: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var authors: [String]
    var tags: [String]

    init(id: String, name: String, authors: [String] = [], tags: [String] = []) {
        self.id = id
        self.name = name
        self.authors = authors
        self.tags = tags
    }

    init(json: JSONDictionary) {
        id = json.string(
            JMServiceResponseSchema.Comic.id,
            default: json.string(JMServiceResponseSchema.Comic.legacyAlbumID)
        )
        name = json.string(
            JMServiceResponseSchema.Comic.name,
            default: json.string(JMServiceResponseSchema.Comic.title, default: "JM\(id)")
        )
        authors = json.strings(JMServiceResponseSchema.Comic.authors)
        tags = json.strings(JMServiceResponseSchema.Comic.tags)
    }

    /// `related_list` uses a scalar `author` while search/favorites normally use an
    /// array. Keep a scalar author intact (including spaces in pen names) instead of
    /// passing it through the generic whitespace-separated value parser.
    init(relatedJSON json: JSONDictionary) {
        id = json.string(
            JMServiceResponseSchema.Comic.id,
            default: json.string(JMServiceResponseSchema.Comic.legacyAlbumID)
        )
        name = json.string(
            JMServiceResponseSchema.Comic.name,
            default: json.string(JMServiceResponseSchema.Comic.title, default: "JM\(id)")
        )
        if let values = json[JMServiceResponseSchema.Comic.authors] as? [String] {
            authors = values
        } else {
            let author = json.string(JMServiceResponseSchema.Comic.authors)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            authors = author.isEmpty ? [] : [author]
        }
        tags = json.strings(JMServiceResponseSchema.Comic.tags)
    }

    var coverPath: String { JMServiceProtocol.MediaPath.albumCover(comicID: id) }
    var authorText: String { authors.isEmpty ? "未知作者" : authors.joined(separator: " / ") }
}

struct Chapter: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var sort: Int

    init(id: String, title: String, sort: Int) {
        self.id = id
        self.title = title
        self.sort = sort
    }

    init(json: JSONDictionary) {
        id = json.string(JMServiceResponseSchema.Chapter.id)
        sort = max(1, json.int(JMServiceResponseSchema.Chapter.sort, default: 1))
        let name = json.string(JMServiceResponseSchema.Chapter.name)
        title = name.isEmpty ? "第 \(sort) 话" : "第 \(sort) 话 · \(name)"
    }
}

struct ComicDetail: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var authors: [String]
    var tags: [String]
    var works: [String]
    var actors: [String]
    var summary: String
    var likes: String
    var views: String
    var commentCount: Int
    var isFavorite: Bool
    var chapters: [Chapter]
    var relatedComics: [ComicSummary]

    init(json: JSONDictionary) {
        let comicID = json.string(JMServiceResponseSchema.Comic.id)
        id = comicID
        name = json.string(JMServiceResponseSchema.Comic.name, default: "JM\(id)")
        authors = json.strings(JMServiceResponseSchema.Comic.authors)
        tags = json.strings(JMServiceResponseSchema.Comic.tags)
        works = json.strings(JMServiceResponseSchema.Comic.works)
        actors = json.strings(JMServiceResponseSchema.Comic.actors)
        summary = json.string(JMServiceResponseSchema.Comic.summary)
        likes = json.string(JMServiceResponseSchema.Comic.likes)
        views = json.string(JMServiceResponseSchema.Comic.totalViews)
        commentCount = json.int(JMServiceResponseSchema.Comic.commentTotal)
        isFavorite = json.bool(JMServiceResponseSchema.Comic.isFavorite)
        let series = json.dictionaries(JMServiceResponseSchema.Comic.series)
        if series.isEmpty {
            chapters = [Chapter(id: id, title: "第 1 话", sort: 1)]
        } else {
            chapters = series.map(Chapter.init).sorted { $0.sort < $1.sort }
        }
        var relatedIDs: Set<String> = []
        relatedComics = json.dictionaries(JMServiceResponseSchema.Comic.relatedList)
            .map(ComicSummary.init(relatedJSON:))
            .filter { comic in
                guard !comic.id.isEmpty, comic.id != comicID else { return false }
                return relatedIDs.insert(comic.id).inserted
            }
    }

    var summaryModel: ComicSummary {
        ComicSummary(id: id, name: name, authors: authors, tags: tags)
    }
}

struct ChapterDetail: Identifiable, Hashable, Codable {
    let id: String
    var albumID: String
    var name: String
    var images: [String]
    var scrambleID: Int

    init(json: JSONDictionary, scrambleID: Int) {
        id = json.string(JMServiceResponseSchema.Chapter.id)
        albumID = json.string(JMServiceResponseSchema.Chapter.seriesID, default: id)
        name = json.string(JMServiceResponseSchema.Chapter.name)
        images = json.strings(JMServiceResponseSchema.Chapter.images).sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        self.scrambleID = scrambleID
    }

    func pagePath(at index: Int) -> String {
        JMServiceProtocol.MediaPath.chapterPage(
            chapterID: id,
            filename: images[index]
        )
    }
}

struct HomeSection: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var comics: [ComicSummary]

    init(json: JSONDictionary) {
        title = json.string(JMServiceResponseSchema.Home.title, default: "推荐")
        comics = json.dictionaries(JMServiceResponseSchema.Home.content).map {
            ComicSummary(json: $0)
        }
    }
}

struct UserProfile: Identifiable, Hashable, Codable {
    let id: String
    var username: String
    var levelName: String
    var level: Int
    var coin: Int
    var favoriteCount: Int
    var favoriteLimit: Int
    var photo: String?
    var experience: Int?
    var nextLevelExperience: Int?

    init(json: JSONDictionary) {
        id = json.string(JMServiceResponseSchema.Profile.userID)
        username = json.string(JMServiceResponseSchema.Profile.username)
        levelName = json.string(JMServiceResponseSchema.Profile.levelName)
        level = json.int(JMServiceResponseSchema.Profile.level)
        coin = json.int(JMServiceResponseSchema.Profile.coin)
        favoriteCount = json.int(JMServiceResponseSchema.Profile.favoriteCount)
        favoriteLimit = json.int(JMServiceResponseSchema.Profile.favoriteLimit)
        let rawPhoto = json.string(JMServiceResponseSchema.Profile.photo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        photo = rawPhoto.isEmpty ? nil : rawPhoto
        experience = json[JMServiceResponseSchema.Profile.experience] == nil
            ? nil
            : json.int(JMServiceResponseSchema.Profile.experience)
        nextLevelExperience = json[JMServiceResponseSchema.Profile.nextLevelExperience] == nil
            ? nil
            : json.int(JMServiceResponseSchema.Profile.nextLevelExperience)
    }

    /// Login returns only the avatar filename on current JM endpoints. Optional
    /// stored fields preserve decoding of profiles saved by earlier app builds.
    var avatarPath: String {
        if let photo, !photo.isEmpty, !photo.hasPrefix("nopic-") {
            if photo.hasPrefix("http") || photo.hasPrefix("/") { return photo }
            return JMServiceProtocol.MediaPath.userPhoto(filename: photo)
        }
        // JMComic-qt uses this stable UID URL when login does not expose a
        // useful photo filename. A failed request silently leaves the initials.
        return JMServiceProtocol.MediaPath.fallbackUserPhoto(userID: id)
    }
}

struct FavoriteFolder: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var count: Int

    init(id: String, name: String, count: Int = 0) {
        self.id = id
        self.name = name
        self.count = count
    }

    init(json: JSONDictionary) {
        id = json.string(
            JMServiceResponseSchema.Favorite.folderID,
            default: json.string(JMServiceResponseSchema.Favorite.fallbackID, default: "0")
        )
        name = json.string(JMServiceResponseSchema.Favorite.name, default: "默认收藏夹")
        count = json.int(JMServiceResponseSchema.Favorite.count)
    }
}

struct FavoritePage: Hashable {
    var total: Int
    var count: Int
    var comics: [ComicSummary]
    var folders: [FavoriteFolder]

    init(json: JSONDictionary) {
        total = json.int(JMServiceResponseSchema.Favorite.total)
        comics = json.dictionaries(JMServiceResponseSchema.Favorite.list).map {
            ComicSummary(json: $0)
        }
        // 上游用 count 表示服务器分页大小，末页 list.count 会更小。
        count = json.int(JMServiceResponseSchema.Favorite.count, default: comics.count)
        folders = [FavoriteFolder(id: "0", name: "全部收藏", count: total)]
        folders.append(contentsOf: json.dictionaries(JMServiceResponseSchema.Favorite.folderList)
            .map(FavoriteFolder.init))
    }
}

/// Converts the small HTML fragments returned by the comments API into display text.
///
/// This intentionally avoids `NSAttributedString`'s HTML importer: that importer spins up
/// WebKit-related machinery, is comparatively expensive, and would otherwise run while a
/// comment page is being published to SwiftUI. The byte scanner below is linear, has no
/// regular-expression backtracking, and runs exactly once when each model is decoded.
enum CommentHTMLText {
    private struct Tag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let endIndex: Int
    }

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "figcaption", "figure",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
        "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td",
        "tfoot", "th", "thead", "tr", "ul"
    ]
    private static let hiddenContentTags: Set<String> = ["script", "style"]
    private static let inlineTags: Set<String> = [
        "a", "abbr", "acronym", "b", "bdi", "bdo", "big", "cite", "code",
        "data", "del", "dfn", "em", "font", "i", "ins", "kbd", "label",
        "mark", "q", "rp", "rt", "ruby", "s", "samp", "small", "span",
        "strike", "strong", "sub", "sup", "time", "tt", "u", "var"
    ]
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"
    ]
    private static let namedEntities: [String: String] = [
        "amp": "&", "apos": "'", "bull": "•", "copy": "©", "emsp": " ",
        "ensp": " ", "gt": ">", "hellip": "…", "laquo": "«", "lt": "<",
        "mdash": "—", "middot": "·", "nbsp": " ", "ndash": "–", "newline": "\n",
        "quot": "\"", "raquo": "»", "reg": "®", "thinsp": " ", "trade": "™"
    ]

    static func plainText(from html: String) -> String {
        guard html.contains("<") || html.contains("&") || html.contains("\r") else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let input = Array(html.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        var hiddenTags: [String] = []

        while index < input.count {
            if !hiddenTags.isEmpty {
                if input[index] == 60 {
                    if startsHTMLComment(in: input, at: index) {
                        index = indexAfterHTMLComment(in: input, at: index)
                        continue
                    }
                    if let tag = parseTag(in: input, at: index) {
                        if hiddenContentTags.contains(tag.name) {
                            if tag.isClosing {
                                // Only a correctly nested closing tag ends the current hidden
                                // scope. A mismatched close must not expose hidden content.
                                if hiddenTags.last == tag.name { hiddenTags.removeLast() }
                            } else if !tag.isSelfClosing {
                                hiddenTags.append(tag.name)
                            }
                        }
                        index = tag.endIndex + 1
                        continue
                    }
                }
                index += 1
                continue
            }

            if input[index] == 60 { // "<"
                if startsHTMLComment(in: input, at: index) {
                    index = indexAfterHTMLComment(in: input, at: index)
                    continue
                }
                if let tag = parseTag(in: input, at: index) {
                    guard isKnownTag(tag.name) else {
                        // Preserve unknown angle-bracket expressions verbatim. Besides being
                        // less destructive, advancing over the parsed range keeps the scanner
                        // linear for text such as `vector<int>` and `<love>`.
                        output.append(contentsOf: input[index...tag.endIndex])
                        index = tag.endIndex + 1
                        continue
                    }
                    if !tag.isClosing && !tag.isSelfClosing
                        && hiddenContentTags.contains(tag.name) {
                        hiddenTags.append(tag.name)
                    } else if tag.name == "br" {
                        appendLineBreak(to: &output, allowBlankLine: true)
                    } else if blockTags.contains(tag.name) {
                        appendLineBreak(to: &output, allowBlankLine: false)
                    }
                    index = tag.endIndex + 1
                    continue
                }
            } else if input[index] == 38, // "&"
                      let entity = decodedEntity(in: input, at: index) {
                output.append(contentsOf: entity.bytes)
                index = entity.endIndex + 1
                continue
            }

            output.append(input[index])
            index += 1
        }

        return normalize(String(decoding: output, as: UTF8.self))
    }

    private static func parseTag(in input: [UInt8], at start: Int) -> Tag? {
        guard start + 1 < input.count, input[start] == 60 else { return nil }
        var cursor = start + 1

        var isClosing = false
        if cursor < input.count, input[cursor] == 47 { // "/"
            isClosing = true
            cursor += 1
        }

        let nameStart = cursor
        guard cursor < input.count, isTagNameStart(input[cursor]) else { return nil }
        cursor += 1
        while cursor < input.count, isTagNameContinuation(input[cursor]) { cursor += 1 }
        // HTML does not allow whitespace immediately after `<`/`</`, and a tag name
        // must end at whitespace, `/`, or `>`. Requiring that boundary prevents prose
        // such as `1 < div > 0` and malformed pseudo-tags from being consumed.
        guard cursor < input.count,
              isASCIISpace(input[cursor]) || input[cursor] == 47 || input[cursor] == 62
        else { return nil }

        let name = String(decoding: input[nameStart..<cursor], as: UTF8.self).lowercased()
        var quote: UInt8?
        var end = cursor
        // A comment cannot reasonably contain a multi-kilobyte opening tag. The limit also
        // prevents malformed input with a lone "<" from swallowing the rest of a long post.
        let maximumEnd = min(input.count, start + 4_096)
        while end < maximumEnd {
            let byte = input[end]
            if let activeQuote = quote {
                if byte == activeQuote { quote = nil }
            } else if byte == 34 || byte == 39 { // double/single quote
                quote = byte
            } else if byte == 62 { // ">"
                var lastNonSpace = end
                while lastNonSpace > cursor, isASCIISpace(input[lastNonSpace - 1]) {
                    lastNonSpace -= 1
                }
                let isSelfClosing = lastNonSpace > cursor && input[lastNonSpace - 1] == 47
                return Tag(
                    name: name,
                    isClosing: isClosing,
                    isSelfClosing: isSelfClosing,
                    endIndex: end
                )
            }
            end += 1
        }
        return nil
    }

    private static func isKnownTag(_ name: String) -> Bool {
        blockTags.contains(name) || inlineTags.contains(name)
            || voidTags.contains(name) || hiddenContentTags.contains(name)
    }

    private static func decodedEntity(
        in input: [UInt8],
        at start: Int
    ) -> (bytes: [UInt8], endIndex: Int)? {
        let maximumEnd = min(input.count, start + 34)
        var end = start + 1
        while end < maximumEnd, input[end] != 59 { // ";"
            guard isEntityCharacter(input[end]) else { return nil }
            end += 1
        }
        guard end < input.count, input[end] == 59, end > start + 1 else { return nil }

        let token = String(decoding: input[(start + 1)..<end], as: UTF8.self)
        if token.first == "#" {
            let number = token.dropFirst()
            let value: UInt32?
            if number.first == "x" || number.first == "X" {
                value = UInt32(number.dropFirst(), radix: 16)
            } else {
                value = UInt32(number, radix: 10)
            }
            guard let value, value != 0, let scalar = UnicodeScalar(value) else { return nil }
            return (Array(String(scalar).utf8), end)
        }

        guard let replacement = namedEntities[token.lowercased()] else { return nil }
        return (Array(replacement.utf8), end)
    }

    private static func appendLineBreak(to output: inout [UInt8], allowBlankLine: Bool) {
        while output.last == 32 || output.last == 9 { output.removeLast() }
        if output.isEmpty { return }
        let trailingNewlines = output.reversed().prefix(while: { $0 == 10 }).count
        let maximum = allowBlankLine ? 2 : 1
        if trailingNewlines < maximum { output.append(10) }
    }

    private static func normalize(_ value: String) -> String {
        let normalizedNewlines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sourceLines = normalizedNewlines.components(separatedBy: "\n")
        var lines: [String] = []
        lines.reserveCapacity(sourceLines.count)

        for sourceLine in sourceLines {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func startsHTMLComment(in input: [UInt8], at index: Int) -> Bool {
        guard index + 3 < input.count else { return false }
        return input[index] == 60 && input[index + 1] == 33
            && input[index + 2] == 45 && input[index + 3] == 45
    }

    private static func indexAfterHTMLComment(in input: [UInt8], at index: Int) -> Int {
        var cursor = index + 4
        while cursor + 2 < input.count {
            if input[cursor] == 45, input[cursor + 1] == 45, input[cursor + 2] == 62 {
                return cursor + 3
            }
            cursor += 1
        }
        return input.count
    }

    private static func isASCIISpace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    private static func isTagNameStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isTagNameContinuation(_ byte: UInt8) -> Bool {
        isTagNameStart(byte) || (48...57).contains(byte) || byte == 45 || byte == 58
    }

    private static func isEntityCharacter(_ byte: UInt8) -> Bool {
        isTagNameContinuation(byte) || byte == 35
    }
}

enum CommentComicTitleNormalization {
    static func value(from rawValue: String, comicID: String) -> String? {
        let title = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = comicID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if !normalizedID.isEmpty,
           title.caseInsensitiveCompare("JM\(normalizedID)") == .orderedSame {
            return nil
        }
        return title
    }
}

struct ComicComment: Identifiable, Hashable {
    let id: String
    var comicID: String
    var comicName: String
    var userID: String
    var username: String
    var avatarPath: String?
    var content: String
    var likes: Int
    var date: String
    var levelName: String
    var replies: [ComicComment]

    init(json: JSONDictionary) {
        id = json.string(JMServiceResponseSchema.Comment.id, default: UUID().uuidString)
        let parsedComicID = json.string(JMServiceResponseSchema.Comment.albumID)
        comicID = parsedComicID
        comicName = [
            JMServiceResponseSchema.Comment.comicName,
            JMServiceResponseSchema.Comment.albumName,
            JMServiceResponseSchema.Comment.alternateComicName,
            JMServiceResponseSchema.Comment.title
        ]
        .compactMap {
            CommentComicTitleNormalization.value(
                from: json.string($0),
                comicID: parsedComicID
            )
        }
        .first ?? ""
        userID = json.string(JMServiceResponseSchema.Comment.userID)
        let accountName = json.string(JMServiceResponseSchema.Comment.username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = json.string(JMServiceResponseSchema.Comment.nickname)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        username = accountName.isEmpty ? (nickname.isEmpty ? "匿名" : nickname) : accountName
        let photo = json.string(JMServiceResponseSchema.Comment.photo)
        avatarPath = photo.hasPrefix("nopic-") || photo.isEmpty
            ? nil
            : JMServiceProtocol.MediaPath.userPhoto(filename: photo)
        content = CommentHTMLText.plainText(
            from: json.string(JMServiceResponseSchema.Comment.content)
        )
        likes = json.int(JMServiceResponseSchema.Comment.likes)
        date = json.string(JMServiceResponseSchema.Comment.addedAt)
        levelName = (json[JMServiceResponseSchema.Comment.experienceInfo] as? JSONDictionary)?
            .string(JMServiceResponseSchema.Comment.levelName) ?? ""
        replies = json.dictionaries(JMServiceResponseSchema.Comment.replies)
            .map(ComicComment.init)
    }

    var destinationComic: ComicSummary? {
        let normalizedID = comicID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        let normalizedName = CommentComicTitleNormalization.value(
            from: comicName,
            comicID: normalizedID
        )
        return ComicSummary(
            id: normalizedID,
            name: normalizedName ?? "漫画详情"
        )
    }
}

struct CommentPage {
    var total: Int
    var comments: [ComicComment]

    init(json: JSONDictionary) {
        total = json.int(JMServiceResponseSchema.Comment.total)
        comments = json.dictionaries(JMServiceResponseSchema.Comment.list)
            .map(ComicComment.init)
    }
}

struct OfflineChapter: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var sort: Int
    var relativePagePaths: [String]
    var expectedPageCount: Int

    var isComplete: Bool {
        expectedPageCount > 0 && relativePagePaths.count >= expectedPageCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, sort, relativePagePaths, expectedPageCount
    }

    init(id: String, title: String, sort: Int = 0, relativePagePaths: [String], expectedPageCount: Int) {
        self.id = id
        self.title = title
        self.sort = sort
        self.relativePagePaths = relativePagePaths
        self.expectedPageCount = expectedPageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sort = try container.decodeIfPresent(Int.self, forKey: .sort) ?? 0
        relativePagePaths = try container.decode([String].self, forKey: .relativePagePaths)
        expectedPageCount = try container.decodeIfPresent(Int.self, forKey: .expectedPageCount)
            ?? relativePagePaths.count
    }
}

struct OfflineComic: Identifiable, Hashable, Codable {
    let id: String
    var comic: ComicSummary
    var storageDirectoryName: String
    /// Relative to the user-visible Documents root, for example
    /// `cache/JM123-abcdef123456.jpg`. Never persist an iOS container URL.
    var coverRelativePath: String?
    var chapters: [OfflineChapter]
    /// The first time this comic was added to the offline library. Unlike
    /// `updatedAt`, page reservations/completions never change this value.
    var addedAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, comic, storageDirectoryName, coverRelativePath, chapters, addedAt, updatedAt
    }

    init(
        comic: ComicSummary,
        storageDirectoryName: String = "",
        coverRelativePath: String? = nil,
        chapters: [OfflineChapter] = [],
        addedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        id = comic.id
        self.comic = comic
        self.storageDirectoryName = storageDirectoryName
        self.coverRelativePath = coverRelativePath
        self.chapters = chapters
        self.addedAt = addedAt ?? updatedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comic = try container.decode(ComicSummary.self, forKey: .comic)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? comic.id
        storageDirectoryName = try container.decodeIfPresent(String.self, forKey: .storageDirectoryName) ?? ""
        coverRelativePath = try container.decodeIfPresent(String.self, forKey: .coverRelativePath)
        chapters = try container.decodeIfPresent([OfflineChapter].self, forKey: .chapters) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? updatedAt
    }
}

struct ReadingProgress: Codable, Hashable {
    var chapterID: String
    var pageIndex: Int
    var updatedAt: Date
}
