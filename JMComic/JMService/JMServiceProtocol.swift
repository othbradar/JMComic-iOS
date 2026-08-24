import Foundation

struct JMServiceRequestSpec: Equatable {
    enum Method: String, Equatable {
        case get = "GET"
        case post = "POST"
    }

    enum BodyEncoding: Equatable {
        case none
        case urlEncoded
        case multipart
    }

    enum SignatureScope: Equatable {
        case api
        case content
    }

    let endpoint: JMServiceProtocol.Endpoint
    let method: Method
    let query: [String: String]
    let form: [String: String]
    let bodyEncoding: BodyEncoding
    let signatureScope: SignatureScope
}

/// JM 网络协议的唯一字面量目录。
///
/// 这里只描述上游 wire contract：endpoint、请求字段、固定值、
/// 签名参数和媒体路径。`APIClient` 只负责调度、重试、Cookie 与模型解析。
/// 上游更改请求协议时，应先改本文件及对应的协议回归测试。
enum JMServiceProtocol {
    /// Increment when bundled endpoints, fields, signing metadata or defaults
    /// change. Runtime configuration uses this to merge new built-in fallbacks
    /// into an older persisted installation exactly once.
    static let contractRevision = 2

    enum Endpoint: String, CaseIterable {
        case setting = "/setting"
        case promote = "/promote"
        case latest = "/latest"
        case search = "/search"
        case album = "/album"
        case chapter = "/chapter"
        case chapterViewTemplate = "/chapter_view_template"
        case login = "/login"
        case favorite = "/favorite"
        case favoriteFolder = "/favorite_folder"
        case forum = "/forum"
        case comment = "/comment"
        case daily = "/daily"
        case dailyCheckIn = "/daily_chk"
    }

    enum Field {
        static let id = "id"
        static let comicName = "comicName"
        static let skip = "skip"
        static let page = "page"
        static let order = "o"
        static let searchQuery = "search_query"
        static let username = "username"
        static let password = "password"
        static let folderID = "folder_id"
        static let folderName = "folder_name"
        static let userID = "user_id"
        static let dailyID = "daily_id"
        static let albumID = "aid"
        static let action = "type"
        static let mode = "mode"
        static let historyUserID = "uid"
        static let comment = "comment"
        static let commentStatus = "status"
        static let commentID = "comment_id"
        static let imageShunt = "app_img_shunt"
    }

    enum Value {
        static let empty = ""
        static let firstPage = "0"
        static let allFavoritesFolder = "0"
        static let defaultOrder = "mr"
        static let verticalMode = "vertical"
        static let comicForumMode = "manhua"
        static let userForumMode = "undefined"
        static let addFolder = "add"
        static let deleteFolder = "del"
        static let moveFavorite = "move"
        static let visibleComment = "1"
    }

    enum Signing {
        static let tokenSecret = "18comicAPP"
        static let contentTokenSecret = "18comicAPPContent"
        static let responseSecret = "185Hcomic3PAPP7R"
        static let domainServerSecret = "diosfjckwpqpdfjkvnqQjsik"

        static let tokenParameterHeader = "tokenparam"
        static let tokenHeader = "token"
        static let acceptEncodingHeader = "accept-encoding"
        static let versionHeader = "version"
        static let acceptedEncoding = "gzip"
        static let protocolVersion = "v1.3.3"
    }

    enum DiscoveryKey {
        static let encryptedServerCandidates = ["jm3_Server", "Server", "Setting"]
        static let apiDomains = "Url2List"
        static let imageDomains = "PicUrlList"
        static let clientVersion = "HeaderVer"
    }

    enum ResponseField {
        static let code = "code"
        static let data = "data"
        static let errorMessage = "errorMsg"
        static let message = "message"
        static let status = "status"
        static let operationMessage = "msg"
        static let authenticationCookieValue = "s"
    }

    enum ResponseValue {
        static let successCode = 200
        static let successStatus = "ok"
    }

    enum Header {
        static let contentType = "Content-Type"
        static let acceptEncoding = "Accept-Encoding"
        static let accept = "Accept"
        static let requestedWith = "X-Requested-With"
        static let referer = "Referer"
        static let contentDisposition = "Content-Disposition"
        static let contentTransferEncoding = "Content-Transfer-Encoding"

        static let urlEncodedContentType = "application/x-www-form-urlencoded"
        static let multipartContentTypePrefix = "multipart/form-data; boundary="
        static let multipartTextContentType = "text/plain; charset=UTF-8"
        static let binaryTransferEncoding = "binary"
        static let identityEncoding = "identity"
        static let imageAccept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        static let requestedWithValue = "com.JMComic3.app"

        static func multipartDisposition(fieldName: String) -> String {
            "form-data; name=\"\(fieldName)\""
        }
    }

    static let authenticationCookieName = "AVS"
    static let authenticationCookiePath = "/"
    static let multipartBoundaryPrefix = "JMComic-"

    enum ChapterTemplate {
        static let fallbackScrambleID = 220_980
        static let scramblePattern = #"\bscramble_id\s*=\s*(\d+)"#
        static let imageDomainPattern = #"[\"']?imghost[\"']?\s*:\s*[\"']([^\"']+)[\"']"#
    }

    /// Server-side strip-scrambling generations. Keep the thresholds and
    /// modulus here because they are part of how JM encodes page payloads, not
    /// an implementation detail of the iOS renderer.
    enum ImageScrambling {
        static let fixedTenSegmentUpperBound = 268_850
        static let moduloTenUpperBound = 421_926
        static let legacySegmentCount = 10

        static func segmentCount(photoID: Int, digestLastByte: UInt8) -> Int {
            guard photoID >= fixedTenSegmentUpperBound else { return legacySegmentCount }
            let modulus = photoID <= moduloTenUpperBound ? 10 : 8
            return (Int(digestLastByte) % modulus) * 2 + 2
        }
    }

    enum MediaPath {
        static let albumCoverSuffix = "_3x4.jpg"
        static let albumCoverFallbackSuffix = ".jpg"

        static func albumCover(comicID: String) -> String {
            "/media/albums/\(comicID)\(albumCoverSuffix)"
        }

        static func fallbackAlbumCoverPath(for path: String) -> String? {
            guard path.hasSuffix(albumCoverSuffix) else { return nil }
            return String(path.dropLast(albumCoverSuffix.count)) + albumCoverFallbackSuffix
        }

        static func chapterPage(chapterID: String, filename: String) -> String {
            "/media/photos/\(chapterID)/\(filename)"
        }

        static func userPhoto(filename: String) -> String {
            "/media/users/\(filename)"
        }

        static func fallbackUserPhoto(userID: String) -> String {
            userID.isEmpty ? "" : userPhoto(filename: "\(userID).jpg")
        }
    }

    enum Request {
        static let setting = get(.setting)

        static func promote(page: Int) -> JMServiceRequestSpec {
            get(.promote, query: [Field.page: String(page)])
        }

        static func latest(page: Int) -> JMServiceRequestSpec {
            get(.latest, query: [Field.page: String(page)])
        }

        static func search(
            query: String,
            page: Int,
            order: String
        ) -> JMServiceRequestSpec {
            get(.search, query: [
                Field.searchQuery: query,
                Field.page: String(page),
                Field.order: order
            ])
        }

        static func album(id: String) -> JMServiceRequestSpec {
            get(.album, query: [
                Field.id: id,
                Field.comicName: Value.empty
            ])
        }

        static func chapter(id: String) -> JMServiceRequestSpec {
            get(.chapter, query: [
                Field.id: id,
                Field.comicName: Value.empty,
                Field.skip: Value.empty
            ])
        }

        static func chapterTemplate(
            chapterID: String,
            imageShunt: Int
        ) -> JMServiceRequestSpec {
            get(.chapterViewTemplate, query: [
                Field.id: chapterID,
                Field.mode: Value.verticalMode,
                Field.page: Value.firstPage,
                Field.imageShunt: String(imageShunt)
            ], signatureScope: .content)
        }

        static func login(username: String, password: String) -> JMServiceRequestSpec {
            post(.login, form: [
                Field.username: username,
                Field.password: password
            ])
        }

        static func favorites(
            folderID: String,
            page: Int,
            order: String
        ) -> JMServiceRequestSpec {
            get(.favorite, query: [
                Field.page: String(page),
                Field.folderID: folderID,
                Field.order: order
            ])
        }

        static func daily(userID: String) -> JMServiceRequestSpec {
            get(.daily, query: [Field.userID: userID])
        }

        static func dailyCheckIn(userID: String, dailyID: Int) -> JMServiceRequestSpec {
            post(.dailyCheckIn, form: [
                Field.userID: userID,
                Field.dailyID: String(dailyID)
            ])
        }

        static func toggleFavorite(comicID: String) -> JMServiceRequestSpec {
            post(.favorite, form: [Field.albumID: comicID])
        }

        static func createFavoriteFolder(name: String) -> JMServiceRequestSpec {
            post(.favoriteFolder, form: [
                Field.folderName: name,
                Field.action: Value.addFolder
            ])
        }

        static func deleteFavoriteFolder(id: String) -> JMServiceRequestSpec {
            post(.favoriteFolder, form: [
                Field.folderID: id,
                Field.action: Value.deleteFolder
            ])
        }

        static func moveFavorite(
            comicID: String,
            folderID: String
        ) -> JMServiceRequestSpec {
            post(.favoriteFolder, form: [
                Field.folderID: folderID,
                Field.action: Value.moveFavorite,
                Field.albumID: comicID
            ])
        }

        static func comicComments(comicID: String, page: Int) -> JMServiceRequestSpec {
            get(.forum, query: [
                Field.mode: Value.comicForumMode,
                Field.albumID: comicID,
                Field.page: String(page)
            ])
        }

        static func userComments(userID: String, page: Int) -> JMServiceRequestSpec {
            get(.forum, query: [
                Field.mode: Value.userForumMode,
                Field.historyUserID: userID,
                Field.page: String(page)
            ])
        }

        static func comment(
            comicID: String,
            content: String,
            commentID: String? = nil
        ) -> JMServiceRequestSpec {
            var form = [
                Field.comment: content,
                Field.albumID: comicID,
                Field.commentStatus: Value.visibleComment
            ]
            if let commentID {
                form[Field.commentID] = commentID
            }
            return post(.comment, form: form, bodyEncoding: .multipart)
        }

        private static func get(
            _ endpoint: Endpoint,
            query: [String: String] = [:],
            signatureScope: JMServiceRequestSpec.SignatureScope = .api
        ) -> JMServiceRequestSpec {
            JMServiceRequestSpec(
                endpoint: endpoint,
                method: .get,
                query: query,
                form: [:],
                bodyEncoding: .none,
                signatureScope: signatureScope
            )
        }

        private static func post(
            _ endpoint: Endpoint,
            form: [String: String],
            bodyEncoding: JMServiceRequestSpec.BodyEncoding = .urlEncoded
        ) -> JMServiceRequestSpec {
            JMServiceRequestSpec(
                endpoint: endpoint,
                method: .post,
                query: [:],
                form: form,
                bodyEncoding: bodyEncoding,
                signatureScope: .api
            )
        }
    }
}
