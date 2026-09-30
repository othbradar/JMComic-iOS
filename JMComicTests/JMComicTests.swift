import XCTest
import UIKit
import SwiftUI
import Security
import SQLite3
@testable import JMComic

final class JMComicTests: XCTestCase {
    func testLegacyConfigurationDefaultsImageRouteAndClampsSelections() throws {
        let legacy = try XCTUnwrap(#"{"apiDomains":["https://api.example"],"imageDomains":["https://img.example"],"appVersion":"2.0.26"}"#.data(using: .utf8))
        var configuration = try JSONDecoder().decode(AppConfiguration.self, from: legacy)
        XCTAssertEqual(configuration.imageShunt, 1)

        configuration.selectImageShunt(99)
        XCTAssertEqual(configuration.imageShunt, 4)
        configuration.selectImageShunt(-2)
        XCTAssertEqual(configuration.imageShunt, 1)
        XCTAssertEqual(AppConfiguration.normalize("//cdn.example/"), "https://cdn.example")
    }

    func testJMServiceAddressesAndWireConstantsSnapshot() {
        XCTAssertEqual(JMServiceProtocol.contractRevision, 2)
        XCTAssertEqual(
            JMServiceAddresses.encryptedUpstreamURL.absoluteString,
            "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt"
        )
        XCTAssertEqual(
            JMServiceAddresses.lineConfigurationMirrorURLs.map(\.absoluteString),
            [
                "https://app.jpacg.cc/JMComic/config.txt",
                "https://app2.jpacg.cc/JMComic/config.txt",
                "https://app3.jpacg.cc/JMComic/config.txt"
            ]
        )
        XCTAssertEqual(JMServiceAddresses.builtInAPIDomains, [
            "https://www.cdnhjk.net",
            "https://www.cdngwc.cc",
            "https://www.cdngwc.net",
            "https://www.cdngwc.club"
        ])
        XCTAssertEqual(JMServiceAddresses.builtInImageDomains, [
            "https://cdn-msp.jmapiproxy1.cc",
            "https://cdn-msp.jmapiproxy3.cc",
            "https://cdn-msp.jmapinodeudzn.net",
            "https://cdn-msp.jmdanjonproxy.xyz"
        ])
        XCTAssertEqual(JMServiceAddresses.defaultClientVersion, "2.0.26")
        XCTAssertEqual(JMServiceAddresses.availableImageShunts, [1, 2, 3, 4])
        XCTAssertEqual(AppConfiguration.defaults.apiDomains, JMServiceAddresses.builtInAPIDomains)
        XCTAssertEqual(AppConfiguration.defaults.imageDomains, JMServiceAddresses.builtInImageDomains)
        XCTAssertEqual(AppConfiguration.defaults.appVersion, JMServiceAddresses.defaultClientVersion)
        XCTAssertEqual(AppConfiguration.defaults.contractRevision, JMServiceProtocol.contractRevision)

        XCTAssertEqual(JMServiceProtocol.Endpoint.allCases.map(\.rawValue), [
            "/setting", "/promote", "/latest", "/search", "/album", "/chapter",
            "/chapter_view_template", "/login", "/favorite", "/favorite_folder",
            "/forum", "/comment", "/daily", "/daily_chk"
        ])
        XCTAssertEqual([
            JMServiceProtocol.Field.id,
            JMServiceProtocol.Field.comicName,
            JMServiceProtocol.Field.skip,
            JMServiceProtocol.Field.page,
            JMServiceProtocol.Field.order,
            JMServiceProtocol.Field.searchQuery,
            JMServiceProtocol.Field.username,
            JMServiceProtocol.Field.password,
            JMServiceProtocol.Field.folderID,
            JMServiceProtocol.Field.folderName,
            JMServiceProtocol.Field.userID,
            JMServiceProtocol.Field.dailyID,
            JMServiceProtocol.Field.albumID,
            JMServiceProtocol.Field.action,
            JMServiceProtocol.Field.mode,
            JMServiceProtocol.Field.historyUserID,
            JMServiceProtocol.Field.comment,
            JMServiceProtocol.Field.commentStatus,
            JMServiceProtocol.Field.commentID,
            JMServiceProtocol.Field.imageShunt
        ], [
            "id", "comicName", "skip", "page", "o", "search_query", "username",
            "password", "folder_id", "folder_name", "user_id", "daily_id", "aid",
            "type", "mode", "uid", "comment", "status", "comment_id", "app_img_shunt"
        ])
        XCTAssertEqual([
            JMServiceProtocol.Value.empty,
            JMServiceProtocol.Value.firstPage,
            JMServiceProtocol.Value.allFavoritesFolder,
            JMServiceProtocol.Value.defaultOrder,
            JMServiceProtocol.Value.verticalMode,
            JMServiceProtocol.Value.comicForumMode,
            JMServiceProtocol.Value.addFolder,
            JMServiceProtocol.Value.deleteFolder,
            JMServiceProtocol.Value.moveFavorite,
            JMServiceProtocol.Value.visibleComment
        ], ["", "0", "0", "mr", "vertical", "manhua", "add", "del", "move", "1"])
        XCTAssertEqual(JMServiceProtocol.DiscoveryKey.encryptedServerCandidates, [
            "jm3_Server", "Server", "Setting"
        ])
        XCTAssertEqual([
            JMServiceProtocol.DiscoveryKey.apiDomains,
            JMServiceProtocol.DiscoveryKey.imageDomains,
            JMServiceProtocol.DiscoveryKey.clientVersion
        ], ["Url2List", "PicUrlList", "HeaderVer"])
        XCTAssertEqual([
            JMServiceProtocol.ResponseField.code,
            JMServiceProtocol.ResponseField.data,
            JMServiceProtocol.ResponseField.errorMessage,
            JMServiceProtocol.ResponseField.message,
            JMServiceProtocol.ResponseField.status,
            JMServiceProtocol.ResponseField.operationMessage,
            JMServiceProtocol.ResponseField.authenticationCookieValue
        ], ["code", "data", "errorMsg", "message", "status", "msg", "s"])
        XCTAssertEqual(JMServiceProtocol.ResponseValue.successCode, 200)
        XCTAssertEqual(JMServiceProtocol.ResponseValue.successStatus, "ok")
        XCTAssertEqual(JMServiceProtocol.authenticationCookieName, "AVS")
        XCTAssertEqual(JMServiceProtocol.authenticationCookiePath, "/")
        XCTAssertEqual(JMServiceProtocol.multipartBoundaryPrefix, "JMComic-")

        XCTAssertEqual([
            JMServiceProtocol.Signing.tokenSecret,
            JMServiceProtocol.Signing.contentTokenSecret,
            JMServiceProtocol.Signing.responseSecret,
            JMServiceProtocol.Signing.domainServerSecret
        ], ["18comicAPP", "18comicAPPContent", "185Hcomic3PAPP7R", "diosfjckwpqpdfjkvnqQjsik"])
        XCTAssertEqual([
            JMServiceProtocol.Signing.tokenParameterHeader,
            JMServiceProtocol.Signing.tokenHeader,
            JMServiceProtocol.Signing.acceptEncodingHeader,
            JMServiceProtocol.Signing.versionHeader,
            JMServiceProtocol.Signing.acceptedEncoding,
            JMServiceProtocol.Signing.protocolVersion
        ], ["tokenparam", "token", "accept-encoding", "version", "gzip", "v1.3.3"])
        XCTAssertEqual(JMServiceProtocol.Header.urlEncodedContentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(JMServiceProtocol.Header.multipartContentTypePrefix, "multipart/form-data; boundary=")
        XCTAssertEqual(JMServiceProtocol.Header.multipartTextContentType, "text/plain; charset=UTF-8")
        XCTAssertEqual(JMServiceProtocol.Header.binaryTransferEncoding, "binary")
        XCTAssertEqual(JMServiceProtocol.Header.identityEncoding, "identity")
        XCTAssertEqual(JMServiceProtocol.Header.requestedWithValue, "com.JMComic3.app")
        XCTAssertEqual(
            JMServiceProtocol.Header.multipartDisposition(fieldName: "aid"),
            "form-data; name=\"aid\""
        )
    }

    func testJMServiceRequestSpecsSnapshot() {
        let actual: [JMServiceRequestSpec] = [
            JMServiceProtocol.Request.setting,
            JMServiceProtocol.Request.promote(page: 7),
            JMServiceProtocol.Request.latest(page: 8),
            JMServiceProtocol.Request.search(query: "作者 & 标签", page: 9, order: "mv"),
            JMServiceProtocol.Request.album(id: "101"),
            JMServiceProtocol.Request.chapter(id: "202"),
            JMServiceProtocol.Request.chapterTemplate(chapterID: "303", imageShunt: 4),
            JMServiceProtocol.Request.login(username: "user", password: "p&=+"),
            JMServiceProtocol.Request.favorites(folderID: "12", page: 3, order: "mr"),
            JMServiceProtocol.Request.daily(userID: "42"),
            JMServiceProtocol.Request.dailyCheckIn(userID: "42", dailyID: 77),
            JMServiceProtocol.Request.toggleFavorite(comicID: "404"),
            JMServiceProtocol.Request.createFavoriteFolder(name: "稍后看"),
            JMServiceProtocol.Request.deleteFavoriteFolder(id: "12"),
            JMServiceProtocol.Request.moveFavorite(comicID: "404", folderID: "12"),
            JMServiceProtocol.Request.comicComments(comicID: "404", page: 5),
            JMServiceProtocol.Request.userComments(userID: "42", page: 6),
            JMServiceProtocol.Request.comment(comicID: "404", content: "顶层评论"),
            JMServiceProtocol.Request.comment(comicID: "404", content: "回复", commentID: "505")
        ]
        let expected: [JMServiceRequestSpec] = [
            JMServiceRequestSpec(endpoint: .setting, method: .get, query: [:], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .promote, method: .get, query: ["page": "7"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .latest, method: .get, query: ["page": "8"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .search, method: .get, query: ["search_query": "作者 & 标签", "page": "9", "o": "mv"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .album, method: .get, query: ["id": "101", "comicName": ""], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .chapter, method: .get, query: ["id": "202", "comicName": "", "skip": ""], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .chapterViewTemplate, method: .get, query: ["id": "303", "mode": "vertical", "page": "0", "app_img_shunt": "4"], form: [:], bodyEncoding: .none, signatureScope: .content),
            JMServiceRequestSpec(endpoint: .login, method: .post, query: [:], form: ["username": "user", "password": "p&=+"], bodyEncoding: .urlEncoded, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .favorite, method: .get, query: ["page": "3", "folder_id": "12", "o": "mr"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .daily, method: .get, query: ["user_id": "42"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .dailyCheckIn, method: .post, query: [:], form: ["user_id": "42", "daily_id": "77"], bodyEncoding: .urlEncoded, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .favorite, method: .post, query: [:], form: ["aid": "404"], bodyEncoding: .urlEncoded, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .favoriteFolder, method: .post, query: [:], form: ["folder_name": "稍后看", "type": "add"], bodyEncoding: .urlEncoded, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .favoriteFolder, method: .post, query: [:], form: ["folder_id": "12", "type": "del"], bodyEncoding: .urlEncoded, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .favoriteFolder, method: .post, query: [:], form: ["folder_id": "12", "type": "move", "aid": "404"], bodyEncoding: .urlEncoded, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .forum, method: .get, query: ["mode": "manhua", "aid": "404", "page": "5"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .forum, method: .get, query: ["mode": "undefined", "uid": "42", "page": "6"], form: [:], bodyEncoding: .none, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .comment, method: .post, query: [:], form: ["comment": "顶层评论", "aid": "404", "status": "1"], bodyEncoding: .multipart, signatureScope: .api),
            JMServiceRequestSpec(endpoint: .comment, method: .post, query: [:], form: ["comment": "回复", "aid": "404", "status": "1", "comment_id": "505"], bodyEncoding: .multipart, signatureScope: .api)
        ]

        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.filter { $0.method == .get }.allSatisfy {
            $0.form.isEmpty && $0.bodyEncoding == .none
        })
        XCTAssertTrue(actual.filter { $0.bodyEncoding == .multipart }.allSatisfy {
            $0.endpoint == .comment && $0.method == .post
        })
        XCTAssertEqual(actual.filter { $0.signatureScope == .content }.map(\.endpoint), [
            .chapterViewTemplate
        ])
        XCTAssertTrue(
            actual[16].query["aid"] == nil
                && actual[16].query["mode"] == JMServiceProtocol.Value.userForumMode
        )
    }

    func testJMServiceSigningAndAESGoldenVectors() throws {
        let apiHeaders = JMCrypto.signedHeaders(
            timestamp: "1700000000",
            version: "2.0.26"
        )
        XCTAssertEqual(apiHeaders, [
            "tokenparam": "1700000000,2.0.26",
            "token": "1c6fa345eea2e10d5a30880ec2a7e0b3",
            "accept-encoding": "gzip",
            "version": "v1.3.3"
        ])

        let contentHeaders = JMCrypto.signedHeaders(
            timestamp: "1700000000",
            version: "2.0.26",
            contentRequest: true
        )
        XCTAssertEqual(contentHeaders, [
            "tokenparam": "1700000000,2.0.26",
            "token": "8be524e958f97f014ddf2a570b011305",
            "accept-encoding": "gzip",
            "version": "v1.3.3"
        ])

        let decryptedResponse = try JMCrypto.decryptResponse(
            "XNEHjUKKaJFw8MCbReF8Kw==",
            timestamp: "1700000000"
        )
        XCTAssertEqual(String(data: decryptedResponse, encoding: .utf8), #"{"status":"ok"}"#)

        let decryptedDirectory = try JMCrypto.decryptResponse(
            "U6h+lJyrqIEAx9va6oTYKWek4KhYnPogMBm5T11JuIugWGmlZp4C8rqVX5QLeXzj",
            timestamp: "",
            secret: JMServiceProtocol.Signing.domainServerSecret
        )
        XCTAssertEqual(
            String(data: decryptedDirectory, encoding: .utf8),
            #"{"jm3_Server":["https://api.example"]}"#
        )
    }

    func testLegacyAppConfigurationContractMigrationIsIdempotent() throws {
        let legacyData = try XCTUnwrap(#"""
        {
            "apiDomains":["//custom-api.example/","https://www.cdnhjk.net/","https://custom-api.example"],
            "imageDomains":["custom-image.example/","https://cdn-msp.jmapiproxy1.cc/"],
            "appVersion":"1.9.9",
            "imageShunt":99
        }
        """#.data(using: .utf8))
        var configuration = try JSONDecoder().decode(AppConfiguration.self, from: legacyData)
        XCTAssertEqual(configuration.contractRevision, 0)
        XCTAssertEqual(configuration.imageShunt, 4)

        XCTAssertTrue(configuration.migrateToCurrentContractIfNeeded())
        XCTAssertEqual(configuration.contractRevision, JMServiceProtocol.contractRevision)
        XCTAssertEqual(configuration.appVersion, JMServiceAddresses.defaultClientVersion)
        XCTAssertEqual(configuration.imageShunt, 4)
        XCTAssertEqual(configuration.apiDomains, [
            "https://custom-api.example",
            "https://www.cdnhjk.net",
            "https://www.cdngwc.cc",
            "https://www.cdngwc.net",
            "https://www.cdngwc.club"
        ])
        XCTAssertEqual(configuration.imageDomains, [
            "https://custom-image.example",
            "https://cdn-msp.jmapiproxy1.cc",
            "https://cdn-msp.jmapiproxy3.cc",
            "https://cdn-msp.jmapinodeudzn.net",
            "https://cdn-msp.jmdanjonproxy.xyz"
        ])

        let migrated = configuration
        XCTAssertFalse(configuration.migrateToCurrentContractIfNeeded())
        XCTAssertEqual(configuration, migrated)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppConfiguration.self,
                from: JSONEncoder().encode(configuration)
            ),
            migrated
        )
    }

    func testJMServiceMediaPathsAndImageScramblingThresholdsSnapshot() {
        XCTAssertEqual(JMServiceProtocol.MediaPath.albumCover(comicID: "123"), "/media/albums/123_3x4.jpg")
        XCTAssertEqual(
            JMServiceProtocol.MediaPath.chapterPage(chapterID: "456", filename: "00001.webp"),
            "/media/photos/456/00001.webp"
        )
        XCTAssertEqual(JMServiceProtocol.MediaPath.userPhoto(filename: "avatar.jpg"), "/media/users/avatar.jpg")
        XCTAssertEqual(JMServiceProtocol.MediaPath.fallbackUserPhoto(userID: "42"), "/media/users/42.jpg")
        XCTAssertEqual(JMServiceProtocol.MediaPath.fallbackUserPhoto(userID: ""), "")

        XCTAssertEqual(ComicSummary(id: "123", name: "Path").coverPath, "/media/albums/123_3x4.jpg")
        let chapter = ChapterDetail(json: [
            "id": "456",
            "images": ["00002.webp", "00001.webp"]
        ], scrambleID: 220_980)
        XCTAssertEqual(chapter.pagePath(at: 0), "/media/photos/456/00001.webp")
        XCTAssertEqual(UserProfile(json: ["uid": "42"]).avatarPath, "/media/users/42.jpg")

        XCTAssertEqual(JMServiceProtocol.ChapterTemplate.fallbackScrambleID, 220_980)
        XCTAssertEqual(JMServiceProtocol.ImageScrambling.fixedTenSegmentUpperBound, 268_850)
        XCTAssertEqual(JMServiceProtocol.ImageScrambling.moduloTenUpperBound, 421_926)
        XCTAssertEqual(JMServiceProtocol.ImageScrambling.legacySegmentCount, 10)
        XCTAssertEqual(
            JMServiceProtocol.ImageScrambling.segmentCount(photoID: 268_849, digestLastByte: 0xFF),
            10
        )
        XCTAssertEqual(
            JMServiceProtocol.ImageScrambling.segmentCount(photoID: 268_850, digestLastByte: 0x66),
            6
        )
        XCTAssertEqual(
            JMServiceProtocol.ImageScrambling.segmentCount(photoID: 421_926, digestLastByte: 0x66),
            6
        )
        XCTAssertEqual(
            JMServiceProtocol.ImageScrambling.segmentCount(photoID: 421_927, digestLastByte: 0x66),
            14
        )
    }

    func testChapterTemplateMetadataParsesRouteHostAndScrambleID() {
        let html = #"""
        <script>
        const config = {"imghost":"https:\/\/route-3.example\/","jmid":"123","cache":"?v=1"};
        var scramble_id = 456789;
        </script>
        """#
        XCTAssertEqual(
            ChapterTemplateMetadata.parse(html),
            ChapterTemplateMetadata(scrambleID: 456_789, imageDomain: "https://route-3.example")
        )
        XCTAssertEqual(
            ChapterTemplateMetadata.parse("<html></html>"),
            ChapterTemplateMetadata(scrambleID: 220_980, imageDomain: nil)
        )
    }

    func testRootTabSwipeOnlyMovesOneAdjacentTabAndHonorsBoundaries() {
        XCTAssertEqual(
            RootTabSwipePolicy.destination(
                from: .explore,
                translation: CGSize(width: -90, height: 8),
                predictedEndTranslation: CGSize(width: -150, height: 10)
            ),
            .search
        )
        XCTAssertEqual(
            RootTabSwipePolicy.destination(
                from: .downloads,
                translation: CGSize(width: 90, height: 5),
                predictedEndTranslation: CGSize(width: 140, height: 5)
            ),
            .favorites
        )
        XCTAssertNil(RootTabSwipePolicy.destination(
            from: .explore,
            translation: CGSize(width: 100, height: 0),
            predictedEndTranslation: CGSize(width: 160, height: 0)
        ))
        XCTAssertNil(RootTabSwipePolicy.destination(
            from: .account,
            translation: CGSize(width: -100, height: 0),
            predictedEndTranslation: CGSize(width: -160, height: 0)
        ))
    }

    func testRootTabSwipeRejectsVerticalAndShortDragsButAcceptsFlicks() {
        XCTAssertNil(RootTabSwipePolicy.destination(
            from: .search,
            translation: CGSize(width: 70, height: 80),
            predictedEndTranslation: CGSize(width: 140, height: 120)
        ))
        XCTAssertNil(RootTabSwipePolicy.destination(
            from: .search,
            translation: CGSize(width: 40, height: 4),
            predictedEndTranslation: CGSize(width: 80, height: 6)
        ))
        XCTAssertEqual(
            RootTabSwipePolicy.destination(
                from: .search,
                translation: CGSize(width: -42, height: 5),
                predictedEndTranslation: CGSize(width: -180, height: 7)
            ),
            .favorites
        )

        let horizontalContent = CGRect(x: 20, y: 200, width: 320, height: 160)
        XCTAssertFalse(RootTabSwipePolicy.beginsOutsideExclusions(
            at: CGPoint(x: 100, y: 260),
            excludedFrames: [horizontalContent]
        ))
        XCTAssertTrue(RootTabSwipePolicy.beginsOutsideExclusions(
            at: CGPoint(x: 100, y: 120),
            excludedFrames: [horizontalContent]
        ))
    }

    func testRootTabSwipeTracksFingerAndRubberBandsAtOuterBoundaries() {
        let viewport: CGFloat = 400
        let regular = RootTabSwipePolicy.interactiveOffset(
            from: .search,
            translation: CGSize(width: -100, height: 4),
            viewportWidth: viewport
        )
        XCTAssertEqual(regular, -100, accuracy: 0.001)

        let firstTabBoundary = RootTabSwipePolicy.interactiveOffset(
            from: .explore,
            translation: CGSize(width: 100, height: 2),
            viewportWidth: viewport
        )
        XCTAssertEqual(firstTabBoundary, 16, accuracy: 0.001)

        let lastTabBoundary = RootTabSwipePolicy.interactiveOffset(
            from: .account,
            translation: CGSize(width: -100, height: 2),
            viewportWidth: viewport
        )
        XCTAssertEqual(lastTabBoundary, -16, accuracy: 0.001)

        XCTAssertEqual(RootTabSwipePolicy.interactiveOffset(
            from: .favorites,
            translation: CGSize(width: 80, height: 100),
            viewportWidth: viewport
        ), 0)

        XCTAssertEqual(
            RootTabSwipePolicy.adjacentTab(from: .downloads, horizontalTranslation: -1),
            .account
        )
        XCTAssertEqual(
            RootTabSwipePolicy.adjacentTab(from: .downloads, horizontalTranslation: 1),
            .favorites
        )
        XCTAssertNil(RootTabSwipePolicy.adjacentTab(from: .explore, horizontalTranslation: 1))
        XCTAssertNil(RootTabSwipePolicy.adjacentTab(from: .account, horizontalTranslation: -1))
    }

    func testRootTabTrackpadProjectsContinuousHorizontalScrollIntoExistingSwipePolicy() {
        XCTAssertTrue(RootTabTrackpadPolicy.isHorizontal(
            velocity: CGPoint(x: -400, y: 40)
        ))
        XCTAssertFalse(RootTabTrackpadPolicy.isHorizontal(
            velocity: CGPoint(x: 80, y: 300)
        ))

        let translation = CGSize(width: -40, height: 4)
        let fastPrediction = RootTabTrackpadPolicy.predictedEndTranslation(
            translation: translation,
            velocity: CGPoint(x: -400, y: 10)
        )
        XCTAssertEqual(fastPrediction.width, -120, accuracy: 0.001)
        XCTAssertEqual(fastPrediction.height, 6, accuracy: 0.001)
        XCTAssertEqual(
            RootTabSwipePolicy.destination(
                from: .search,
                translation: translation,
                predictedEndTranslation: fastPrediction
            ),
            .favorites
        )

        let slowPrediction = RootTabTrackpadPolicy.predictedEndTranslation(
            translation: translation,
            velocity: CGPoint(x: -100, y: 0)
        )
        XCTAssertNil(RootTabSwipePolicy.destination(
            from: .search,
            translation: translation,
            predictedEndTranslation: slowPrediction
        ))
    }

    func testRootTabSnapshotLeavesAdaptiveSystemChromeStationary() {
        // iPhone 17 Pro Max: status area and floating bottom tab bar stay live.
        let phoneWindow = CGRect(x: 0, y: 0, width: 440, height: 956)
        let phoneCrop = RootTabSnapshotPolicy.pageCrop(
            anchorFrame: phoneWindow,
            windowBounds: phoneWindow,
            safeAreaTop: 62,
            tabBarFrames: [CGRect(x: 0, y: 873, width: 440, height: 83)]
        )
        XCTAssertEqual(phoneCrop, CGRect(x: 0, y: 62, width: 440, height: 811))
        XCTAssertEqual(
            RootTabSnapshotPolicy.stationaryTopHeight(
                windowBounds: phoneWindow,
                safeAreaTop: 62,
                tabBarFrames: [CGRect(x: 0, y: 873, width: 440, height: 83)],
                screenScale: 3
            ),
            62
        )
        XCTAssertEqual(
            RootTabSnapshotPolicy.stationaryTopHeight(
                windowBounds: CGRect(x: 0, y: 0, width: 320, height: 640),
                safeAreaTop: 0,
                screenScale: 2
            ),
            1
        )

        let iPadWindow = CGRect(x: 0, y: 0, width: 1_210, height: 834)
        let iPadAnchor = CGRect(x: 0, y: 32, width: 1_210, height: 782)

        // iPad top-tab mode: UIKit's content layout guide excludes the shared
        // top chrome. No foreground status fill is drawn in this presentation,
        // leaving the live liquid-glass capsule and its upper shadow untouched.
        let topContentFrame = CGRect(x: 0, y: 96, width: 1_210, height: 718)
        let topCrop = RootTabSnapshotPolicy.pageCrop(
            anchorFrame: iPadAnchor,
            windowBounds: iPadWindow,
            safeAreaTop: 32,
            tabContentFrame: topContentFrame
        )
        XCTAssertEqual(topCrop, CGRect(x: 0, y: 96, width: 1_210, height: 718))
        XCTAssertEqual(
            RootTabSnapshotPolicy.stationaryTopHeight(
                windowBounds: iPadWindow,
                safeAreaTop: 32,
                tabContentFrame: topContentFrame,
                screenScale: 2
            ),
            0
        )
        XCTAssertEqual(
            RootTabSnapshotPolicy.stationaryTopHeight(
                windowBounds: iPadWindow,
                safeAreaTop: 32,
                tabContentFrame: CGRect(x: 0.2, y: 96.25, width: 1_209.6, height: 717.75),
                screenScale: 2
            ),
            0
        )

        // iPad sidebar mode: the moving page starts to the right of the live
        // 280pt sidebar instead of capturing a stale copy of it.
        let sidebarCrop = RootTabSnapshotPolicy.pageCrop(
            anchorFrame: iPadAnchor,
            windowBounds: iPadWindow,
            safeAreaTop: 32,
            tabContentFrame: CGRect(x: 280, y: 32, width: 930, height: 782)
        )
        XCTAssertEqual(sidebarCrop, CGRect(x: 280, y: 32, width: 930, height: 782))
        XCTAssertEqual(
            RootTabSnapshotPolicy.stationaryTopHeight(
                windowBounds: iPadWindow,
                safeAreaTop: 32,
                tabContentFrame: CGRect(x: 280, y: 32, width: 930, height: 782),
                screenScale: 2
            ),
            32
        )

        // iOS 18 fallback: a public conventional top UITabBar reserves its
        // whole horizontal band even without contentLayoutGuide.
        let fallbackTopCrop = RootTabSnapshotPolicy.pageCrop(
            anchorFrame: iPadAnchor,
            windowBounds: iPadWindow,
            safeAreaTop: 32,
            tabBarFrames: [CGRect(x: 0, y: 32, width: 1_210, height: 44)]
        )
        XCTAssertEqual(fallbackTopCrop, CGRect(x: 0, y: 76, width: 1_210, height: 738))
        XCTAssertEqual(
            RootTabSnapshotPolicy.stationaryTopHeight(
                windowBounds: iPadWindow,
                safeAreaTop: 32,
                tabBarFrames: [CGRect(x: 0, y: 32, width: 1_210, height: 44)],
                screenScale: 2
            ),
            0
        )
    }

    func testRootTabSnapshotEdgesOverlapWithoutLeavingASeam() {
        let viewport = CGRect(x: 0, y: 59, width: 430, height: 873)
        let overlap = RootTabSnapshotPolicy.seamOverlap(screenScale: 3)
        XCTAssertEqual(overlap, 2.0 / 3.0, accuracy: 0.001)

        let movingLeft = RootTabSnapshotPolicy.expandedSourceFrame(
            viewportFrame: viewport,
            destinationBaseOffset: viewport.width,
            screenScale: 3
        )
        XCTAssertEqual(movingLeft.minX, viewport.minX)
        XCTAssertEqual(movingLeft.maxX, viewport.maxX + overlap, accuracy: 0.001)

        let movingRight = RootTabSnapshotPolicy.expandedSourceFrame(
            viewportFrame: viewport,
            destinationBaseOffset: -viewport.width,
            screenScale: 3
        )
        XCTAssertEqual(movingRight.minX, viewport.minX - overlap, accuracy: 0.001)
        XCTAssertEqual(movingRight.maxX, viewport.maxX)
    }

    func testInstallingRootTabCancellationNeverSelectsDestination() {
        XCTAssertEqual(
            RootTabTransitionPreparationPolicy.sourceSnapshotInstalledAction(
                endDecision: false
            ),
            .discardWithoutSelectingDestination
        )
    }

    func testPreparingRootTabCancellationIgnoresLateDestinationReadiness() {
        XCTAssertEqual(
            RootTabTransitionPreparationPolicy.destinationReadyAction(
                endDecision: false
            ),
            .restoreSourceWithoutReveal
        )
    }

    @MainActor
    func testRootTabSelectionMutationGateHandlesRoundTripAndCoalescing() {
        let gate = RootTabSelectionMutationGate()
        gate.expect(.search)
        gate.expect(.explore)
        XCTAssertTrue(gate.consume(.search))
        XCTAssertTrue(gate.consume(.explore))

        gate.expect(.search)
        gate.expect(.explore)
        XCTAssertTrue(gate.consume(.explore))
        XCTAssertFalse(gate.consume(.search))
    }

    @MainActor
    func testRootTabGestureLifecycleRejectsRepeatedBeginUntilCleanup() {
        let lifecycle = RootTabGestureLifecycle()
        XCTAssertTrue(lifecycle.begin())
        XCTAssertFalse(lifecycle.begin())
        lifecycle.end()
        XCTAssertTrue(lifecycle.begin())
    }

    func testEverySharedSecondaryRouteDisablesRootTabSwipeUntilItPops() {
        XCTAssertTrue(RootNavigationPathPolicy.allowsRootTabSwipe(
            path: [AppNavigationRoute]()
        ))

        let comic = ComicSummary(id: "route-1", name: "导航测试")
        let routes: [AppNavigationRoute] = [
            .comic(comic),
            .search("作者"),
            .login,
            .settings,
            .myComments,
            .dailyCheckIn,
            .readingHistory
        ]
        for route in routes {
            XCTAssertFalse(
                RootNavigationPathPolicy.allowsRootTabSwipe(path: [route]),
                "\(route) must leave the system interactive-pop gesture exclusive"
            )
        }
        XCTAssertFalse(RootNavigationPathPolicy.allowsRootTabSwipe(
            path: [
                AppNavigationRoute.comic(comic),
                AppNavigationRoute.search("标签")
            ]
        ))

        var commentsPath: [AppNavigationRoute] = [.myComments, .comic(comic)]
        XCTAssertFalse(RootNavigationPathPolicy.allowsRootTabSwipe(path: commentsPath))
        commentsPath.removeLast()
        XCTAssertFalse(RootNavigationPathPolicy.allowsRootTabSwipe(path: commentsPath))
        commentsPath.removeLast()
        XCTAssertTrue(RootNavigationPathPolicy.allowsRootTabSwipe(path: commentsPath))
    }

    func testMyCommentsInitialLoadPolicyPreservesLoadedRowsWhenReturningFromDetail() {
        XCTAssertTrue(MyCommentsInitialLoadPolicy.shouldLoad(
            requestedUserID: "42",
            activeUserID: nil,
            hasLoaded: false
        ))
        XCTAssertFalse(MyCommentsInitialLoadPolicy.shouldLoad(
            requestedUserID: "42",
            activeUserID: "42",
            hasLoaded: true
        ))
        XCTAssertTrue(MyCommentsInitialLoadPolicy.shouldLoad(
            requestedUserID: "42",
            activeUserID: "42",
            hasLoaded: false
        ))
        XCTAssertTrue(MyCommentsInitialLoadPolicy.shouldLoad(
            requestedUserID: "84",
            activeUserID: "42",
            hasLoaded: true
        ))
        XCTAssertFalse(MyCommentsInitialLoadPolicy.shouldLoad(
            requestedUserID: "   ",
            activeUserID: "42",
            hasLoaded: false
        ))
    }

    func testCompactFavoritesFolderIsSecondaryEvenBeforeDetailPathPushes() {
        XCTAssertTrue(RootNavigationPathPolicy.allowsFavoritesSidebarRootTabSwipe(
            isRegularWidth: false,
            selectedFolderID: nil,
            detailDepth: 0
        ))
        XCTAssertFalse(RootNavigationPathPolicy.allowsFavoritesSidebarRootTabSwipe(
            isRegularWidth: false,
            selectedFolderID: "0",
            detailDepth: 0
        ))
        XCTAssertFalse(RootNavigationPathPolicy.allowsFavoritesSidebarRootTabSwipe(
            isRegularWidth: true,
            selectedFolderID: "0",
            detailDepth: 1
        ))
        XCTAssertTrue(RootNavigationPathPolicy.allowsFavoritesSidebarRootTabSwipe(
            isRegularWidth: true,
            selectedFolderID: "0",
            detailDepth: 0
        ))
    }

    func testDownloadDestinationsDisableRootTabSwipeUntilTheyPop() {
        var path = NavigationPath()
        XCTAssertTrue(DownloadsNavigationPolicy.allowsRootTabSwipe(pathCount: path.count))

        path.append(DownloadsRoute.tasks)
        XCTAssertFalse(DownloadsNavigationPolicy.allowsRootTabSwipe(pathCount: path.count))

        // A detail reached from Downloads can append the shared route family
        // for tags/recommendations without re-enabling root-tab paging.
        path.append(AppNavigationRoute.search("标签"))
        XCTAssertFalse(DownloadsNavigationPolicy.allowsRootTabSwipe(pathCount: path.count))

        path.removeLast(2)
        XCTAssertTrue(DownloadsNavigationPolicy.allowsRootTabSwipe(pathCount: path.count))
    }

    func testContentOwnedRootTitlesShareOneBaselineContract() {
        XCTAssertEqual(RootPageLargeTitleRow.topInset, 5)
        XCTAssertEqual(RootPageLargeTitleRow.bottomInset, 8)
    }

    func testMD5AndSignedHeaders() {
        XCTAssertEqual(JMCrypto.md5("170000000018comicAPP"), "1c6fa345eea2e10d5a30880ec2a7e0b3")
        let headers = JMCrypto.signedHeaders(timestamp: "1700000000", version: "2.0.26")
        XCTAssertEqual(headers["tokenparam"], "1700000000,2.0.26")
        XCTAssertEqual(headers["token"], "1c6fa345eea2e10d5a30880ec2a7e0b3")
    }

    func testSegmentationBoundaries() {
        XCTAssertEqual(ImageScrambler.segmentationCount(scrambleID: 220_980, photoID: 220_979, filename: "00001"), 0)
        XCTAssertEqual(ImageScrambler.segmentationCount(scrambleID: 220_980, photoID: 220_980, filename: "00001"), 10)
        let value = ImageScrambler.segmentationCount(scrambleID: 220_980, photoID: 500_000, filename: "00001")
        XCTAssertTrue(stride(from: 2, through: 16, by: 2).contains(value))
        XCTAssertEqual(
            ImageScrambler.segmentationCount(scrambleID: 220_980, photoID: 421_926, filename: "00001"),
            (Int(JMCrypto.md5("42192600001").utf8.last!) % 10) * 2 + 2
        )
    }

    func testCancellationRecognitionStopsDomainFallback() {
        let cancelled = URLError(.cancelled)
        XCTAssertTrue(APIClient.isCancellation(cancelled))
        XCTAssertTrue(APIClient.isCancellation(CancellationError()))
        let wrapped = NSError(
            domain: "JMComicTests",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: cancelled]
        )
        XCTAssertTrue(APIClient.isCancellation(wrapped))
        XCTAssertFalse(APIClient.isCancellation(URLError(.timedOut)))
    }

    func testImageRaceRejectsHTTP200HTMLResponse() {
        XCTAssertFalse(APIClient.isLikelyImageData(
            Data("<!doctype html><html>blocked</html>".utf8),
            contentType: "text/html"
        ))
        XCTAssertFalse(APIClient.isLikelyImageData(
            Data("<html>mislabelled challenge</html>".utf8),
            contentType: "image/jpeg"
        ))
        XCTAssertFalse(APIClient.isLikelyImageData(
            Data("\u{FEFF}  <div>mislabelled gateway response</div>".utf8),
            contentType: "image/webp"
        ))
        XCTAssertFalse(APIClient.isLikelyImageData(
            Data("[{\"error\":\"rate limited\"}]".utf8),
            contentType: "image/jpeg"
        ))
        XCTAssertTrue(APIClient.isLikelyImageData(
            Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
            contentType: "application/octet-stream"
        ))
        XCTAssertTrue(APIClient.isLikelyImageData(
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            contentType: nil
        ))
    }

    func testRasterImageDecodesPixelsBeforeDisplay() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 72), format: format)
        let source = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 72))
        }
        let data = try XCTUnwrap(source.pngData())
        let raster = try ImageScrambler.rasterImage(from: data)
        XCTAssertEqual(raster.cgImage?.width, 48)
        XCTAssertEqual(raster.cgImage?.height, 72)

        let decoded = try ImageScrambler.decodeImage(
            data,
            scrambleID: 100,
            photoID: "99",
            filename: "00001.png"
        )
        XCTAssertEqual(decoded.cgImage?.width, 48)
        XCTAssertEqual(decoded.cgImage?.height, 72)
    }

    func testLosslessScrambleRestoresEveryPixelWithNonDivisibleStripHeight() throws {
        let width = 37
        let height = 173
        let photoID = "1452616"
        let filename = "00001.png"
        let count = ImageScrambler.segmentationCount(
            scrambleID: 220_980,
            photoID: try XCTUnwrap(Int(photoID)),
            filename: "00001"
        )
        XCTAssertEqual(count, 8)
        XCTAssertNotEqual(height % count, 0)

        let original = smoothColourPage(width: width, height: height)
        let scrambled = scrambleRows(
            original,
            width: width,
            height: height,
            segmentationCount: count
        )
        let scrambledImage = try imageFromRGBX(scrambled, width: width, height: height)
        let data = try XCTUnwrap(scrambledImage.pngData())
        // PNG/ImageIO may colour-manage DeviceRGB while encoding.  Pass the
        // original through that same round trip so this assertion isolates
        // scanline mapping rather than comparing two different colour spaces.
        let originalData = try XCTUnwrap(
            imageFromRGBX(original, width: width, height: height).pngData()
        )
        let expected = try rgbxPixels(
            from: ImageScrambler.rasterImage(from: originalData)
        )
        let decoded = try ImageScrambler.decodeImage(
            data,
            scrambleID: 220_980,
            photoID: photoID,
            filename: filename
        )
        let restored = try rgbxPixels(from: decoded)

        XCTAssertEqual(restored.count, expected.count)
        var firstMismatch: (pixel: Int, channel: Int, expected: UInt8, actual: UInt8)?
        for offset in stride(from: 0, to: expected.count, by: 4) {
            for channel in 0..<3 where restored[offset + channel] != expected[offset + channel] {
                firstMismatch = (
                    pixel: offset / 4,
                    channel: channel,
                    expected: expected[offset + channel],
                    actual: restored[offset + channel]
                )
                break
            }
            if firstMismatch != nil { break }
        }
        if let mismatch = firstMismatch {
            XCTFail(
                "Lossless scanline restore differs at pixel \(mismatch.pixel), "
                    + "channel \(mismatch.channel): expected \(mismatch.expected), "
                    + "got \(mismatch.actual)"
            )
        }
    }

    func testOptInChromaRepairAndLosslessDownloadKeepSamePixels() throws {
        let width = 96
        let height = 173
        let photoID = "1452616"
        let filename = "00001.jpg"
        let count = ImageScrambler.segmentationCount(
            scrambleID: 220_980,
            photoID: try XCTUnwrap(Int(photoID)),
            filename: "00001"
        )
        XCTAssertEqual(count, 8)

        let original = smoothColourPage(width: width, height: height)
        let scrambled = scrambleRows(
            original,
            width: width,
            height: height,
            segmentationCount: count
        )
        let scrambledImage = try imageFromRGBX(scrambled, width: width, height: height)
        // Model the CDN: it compresses one image while unrelated scrambled
        // strips are still neighbours, contaminating their boundary chroma.
        let lossySource = try XCTUnwrap(scrambledImage.jpegData(compressionQuality: 0.55))
        let naive = try rgbxPixels(
            from: legacyDecodedImage(
                lossySource,
                segmentationCount: count
            )
        )

        let repairedImage = try ImageScrambler.decodeImage(
            lossySource,
            scrambleID: 220_980,
            photoID: photoID,
            filename: filename,
            processing: .repairChroma
        )
        let repaired = try rgbxPixels(from: repairedImage)
        let joins = decodedStripJoins(height: height, segmentationCount: count)
        let naiveResidual = meanBoundaryChromaResidual(
            naive,
            width: width,
            joins: joins
        )
        let repairedResidual = meanBoundaryChromaResidual(
            repaired,
            width: width,
            joins: joins
        )
        XCTAssertGreaterThan(naiveResidual, 1.0)
        XCTAssertLessThan(repairedResidual, naiveResidual * 0.3)
        XCTAssertLessThan(
            meanBoundaryLuminanceDifference(
                lhs: naive,
                rhs: repaired,
                width: width,
                joins: joins
            ),
            0.75
        )

        // The optional transform is identical online and in lossless storage.
        let download = try ImageScrambler.decode(
            lossySource, scrambleID: 220_980, photoID: photoID,
            filename: filename, processing: .repairChroma
        )
        XCTAssertEqual(download.fileExtension, "png")
        assertSamePixels(
            try normalizedPixels(repairedImage),
            try normalizedPixels(ImageScrambler.rasterImage(from: download.data))
        )
    }

    func testFaithfulPagesKeepColourDetailsAndAllStripRows() throws {
        // Include divisible/non-divisible heights, single rows/columns and
        // more strips than rows. Use both legacy ten strips and hashed strips.
        for photoID in ["220980", "1452616"] {
            let count = ImageScrambler.segmentationCount(scrambleID: 220_980, photoID: Int(photoID)!, filename: "00001")
            for (width, height) in [(1, 1), (1, 7), (37, 80), (37, 173)] {
                let pixels = colourDetailPage(width: width, height: height)
                let source = try imageFromRGBX(scrambleRows(pixels, width: width, height: height, segmentationCount: count), width: width, height: height)
                for data in [try XCTUnwrap(source.pngData()), try XCTUnwrap(source.jpegData(compressionQuality: 0.96))] {
                    // Compare against decoded CDN pixels, never against the
                    // pristine pre-JPEG source: the client cannot undo JPEG.
                    let expected = unscrambleRows(
                        try normalizedPixels(ImageScrambler.rasterImage(from: data)),
                        width: width, height: height, segmentationCount: count
                    )
                    let online = try ImageScrambler.decodeImage(data, scrambleID: 220_980, photoID: photoID, filename: "00001.jpg")
                    XCTAssertEqual(online.cgImage?.width, width)
                    XCTAssertEqual(online.cgImage?.height, height)
                    assertSamePixels(try normalizedPixels(online), expected)
                    let stored = try ImageScrambler.decode(data, scrambleID: 220_980, photoID: photoID, filename: "00001.jpg")
                    XCTAssertEqual(stored.fileExtension, "png")
                    XCTAssertTrue(stored.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
                    let offline = try ImageScrambler.rasterImage(from: stored.data)
                    XCTAssertEqual(offline.cgImage?.width, width)
                    XCTAssertEqual(offline.cgImage?.height, height)
                    assertSamePixels(try normalizedPixels(online), try normalizedPixels(offline))
                }
            }
        }
    }

    func testSyntheticWebPDefaultIsExactAndStorageUsesRealFormat() throws {
        // Pillow RGB 13x53, eight reversed strips, quality=90. Generated from
        // the same coloured-stroke pattern as colourDetailPage; no real page.
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRoADAABXRUJQVlA4IHQDAAAwGACdASoNADUAPi0QhkKhoQ36AAwBYlsAJ0yhHq3nf5AcpQ4bwI09/ZvYBtgP1V9QH6ef3b+q+9B6APOq6gD0AP0A9Kr/He4T+zv+1/w/tI3Zf8g/En9mew+8M+sWSs+sePn87/IDgK/078kNkB4i/xX+Pfjp5Vv7d3gP6B6B3+O1gj+Qf4D9Hf9J7XP6h+Rv9d9lnxv/hPzA+ST+Z/37+r/uR/cP//4K/0z9h/9IywGoBl979Km/5eKaRcLaj++qz2FgDi/53EsAAP7VrFr3l1QnFHRsRrBk7y3KgziziH+YRHy9EJYW8QWNmunD7qLuXh8miIlquNmY2LDV8lEUPgPeYqrY3JzID5VjHEgTIncwl0puHxj4w8MSN4qMgcPdfGw/w4V/tyrT0rJJ0PebDLRl3H2NDl61CoJBlZUbMgj+NPStQSre/Fpql7iOIMzj4H2z/53oYcOm0B99V9HAhd5oDM4cXSE6uxWyzy5f4AQfvw+40Pu8AkX0AaSkpIyCsD2jKJtsJgLvPLQkxkhoaEL0Yh8+95U5Mf94UwhldE8DkbGra/rYYT9/1wUzDu3d4Z7O9MARU98J4vPr+YUAU0v+5LnObHX+nxAbEF6yAud/QP6Q0hDtjhLNniOfKJNKDCIDXysvCxs3AiGVz//xlh39Zo4Eo9UHxeoPQ6s/4jkXIqlbTHqJzhEZgkWB56vwr6SiiE856Z9USzb6gHrPrgSLZyawO4kgVkpC5XJA3/ta30gOYhkf+JdkhlRVekNSSsuD1rrZqRNxmm2tzY31QjerBWle4rxauyp+UeZhHxrCrP7pi2xewaAQwO2BHJKG3rbVfygh2vYlUymtCVb34tNUvcRxBmclmfUWxLj5sOz0RLtQOROflrwrcgYgX1QukkB//astM+EdSe9RTXW5wcmUv381YvZx5nImbA0h6tJuuTkXJ2eOSy4Q85O6X/wGno3La1BGSypY5sFR7j538XmUPa6BBDYjrLWLf+m7J9Cvh74nMoDiihTIyF22IxV4e5ItSqDTGD5XJhHu37MVlU2kuB96edvHqtnpPqZpq3t9Tazz/1y/lxoulibitrct5NNSjEqD5FaN6MAaH1+bAagy3Z/dKKM9ntiXDVrS2AzIt+X8+Jt0K1b+Y4/+7l4kq7Ah/twmb0/EOiL/jAOY43AAAA=="))
        let source = try ImageScrambler.rasterImage(from: data)
        let expected = unscrambleRows(try normalizedPixels(source), width: 13, height: 53, segmentationCount: 8)
        let online = try ImageScrambler.decodeImage(data, scrambleID: 220_980, photoID: "1452616", filename: "00001.webp")
        assertSamePixels(try normalizedPixels(online), expected)
        let repaired = try ImageScrambler.decodeImage(data, scrambleID: 220_980, photoID: "1452616", filename: "00001.webp", processing: .repairChroma)
        XCTAssertFalse(try normalizedPixels(repaired).elementsEqual(expected))
        let stored = try ImageScrambler.decode(data, scrambleID: 220_980, photoID: "1452616", filename: "00001.webp")
        XCTAssertEqual(stored.fileExtension, "png")
        assertSamePixels(try normalizedPixels(online), try normalizedPixels(ImageScrambler.rasterImage(from: stored.data)))
        let original = try ImageScrambler.decode(data, scrambleID: 100, photoID: "99", filename: "wrong.jpg")
        XCTAssertEqual(original.fileExtension, "webp")
        XCTAssertEqual(original.data, data)
    }

    func testUnprocessedOriginalBytesAndExplicitJPEGStorage() throws {
        let source = try imageFromRGBX(colourDetailPage(width: 37, height: 173), width: 37, height: 173)
        for (data, ext) in [(try XCTUnwrap(source.pngData()), "png"), (try XCTUnwrap(source.jpegData(compressionQuality: 0.96)), "jpg")] {
            let stored = try ImageScrambler.decode(data, scrambleID: 100, photoID: "99", filename: "mislabelled.webp")
            XCTAssertEqual(stored.data, data)
            XCTAssertEqual(stored.fileExtension, ext)
        }
        let jpeg = try XCTUnwrap(source.jpegData(compressionQuality: 0.96))
        let stored = try ImageScrambler.decode(jpeg, scrambleID: 220_980, photoID: "1452616", filename: "00001.jpg", storage: .spaceSavingJPEG)
        XCTAssertEqual(stored.fileExtension, "jpg")
        XCTAssertTrue(stored.data.starts(with: [0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try ImageScrambler.rasterImage(from: stored.data).cgImage?.height, 173)
    }

    func testLosslessPagePreservesAlphaAndRGBProfile() throws {
        let width = 19, height = 83
        var pixels = colourDetailPage(width: width, height: height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha: UInt8 = offset % 3 == 0 ? 0 : 128
            for channel in 0..<3 { pixels[offset + channel] = UInt8(Int(pixels[offset + channel]) * Int(alpha) / 255) }
            pixels[offset + 3] = alpha
        }
        let scrambled = scrambleRows(pixels, width: width, height: height, segmentationCount: 8)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(scrambled) as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = try XCTUnwrap(UIImage(cgImage: cgImage).pngData())
        let expected = unscrambleRows(try normalizedPixels(ImageScrambler.rasterImage(from: data)), width: width, height: height, segmentationCount: 8)
        let online = try ImageScrambler.decodeImage(data, scrambleID: 220_980, photoID: "1452616", filename: "00001.png")
        assertSamePixels(try normalizedPixels(online), expected)
        let stored = try ImageScrambler.decode(data, scrambleID: 220_980, photoID: "1452616", filename: "00001.png", storage: .spaceSavingJPEG)
        XCTAssertEqual(stored.fileExtension, "png", "JPEG must not flatten transparent pages")
        assertSamePixels(try normalizedPixels(online), try normalizedPixels(ImageScrambler.rasterImage(from: stored.data)))
    }

    @MainActor
    func testOnlineInFlightPoliciesStaySeparateAndMatchLosslessDownload() async throws {
        let width = 37, height = 173
        let source = try imageFromRGBX(scrambleRows(colourDetailPage(width: width, height: height), width: width, height: height, segmentationCount: 8), width: width, height: height)
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.96))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PageFixtureURLProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); PageFixtureURLProtocol.handle = nil }
        let api = APIClient(
            secureStore: PageFixtureSecureStore(),
            configuration: AppConfiguration(apiDomains: [], imageDomains: ["https://page-fixture.invalid"], appVersion: "test"),
            session: session,
            requiresBootstrap: false
        )
        let chapter = ChapterDetail(json: ["id": "1452616", "images": ["00001.jpg"]], scrambleID: 220_980)
        let oldStarted = expectation(description: "repair request started")
        let newStarted = expectation(description: "faithful request started")
        var requests: [PageFixtureURLProtocol] = []
        PageFixtureURLProtocol.handle = { request in
            DispatchQueue.main.async {
                requests.append(request)
                if requests.count == 1 { oldStarted.fulfill() }
                if requests.count == 2 { newStarted.fulfill() }
            }
        }
        let old = Task { try await api.decodedPageImage(chapter: chapter, index: 0, processing: .repairChroma) }
        await fulfillment(of: [oldStarted], timeout: 3)
        let current = Task { try await api.decodedPageImage(chapter: chapter, index: 0, processing: .faithful) }
        // Respect a user's one-request concurrency setting as well. Both
        // strategies are in flight even if the second transport is queued.
        let transportsOverlap = DownloadConcurrencyPreferences.cachedImageRequests() > 1
        if !transportsOverlap { requests[0].respond(data) }
        await fulfillment(of: [newStarted], timeout: 3)
        guard requests.count == 2 else { old.cancel(); current.cancel(); return }
        requests[1].respond(data)
        let faithful = try await current.value
        // Complete the old strategy last, as when a settings change races I/O.
        if transportsOverlap { requests[0].respond(data) }
        let repaired = try await old.value
        let cachedFaithful = try await api.decodedPageImage(chapter: chapter, index: 0, processing: .faithful)
        let cachedRepaired = try await api.decodedPageImage(chapter: chapter, index: 0, processing: .repairChroma)
        XCTAssertTrue(cachedFaithful === faithful)
        XCTAssertTrue(cachedRepaired === repaired)
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(try normalizedPixels(faithful).elementsEqual(normalizedPixels(repaired)))
        let download = try ImageScrambler.decode(data, scrambleID: chapter.scrambleID, photoID: chapter.id, filename: chapter.images[0])
        let offline = try ImageScrambler.rasterImage(from: download.data)
        XCTAssertEqual(faithful.size, offline.size)
        assertSamePixels(try normalizedPixels(faithful), try normalizedPixels(offline))
    }

    private func colourDetailPage(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let colours: [[UInt8]] = [[240, 12, 35], [16, 220, 80], [35, 60, 245], [245, 210, 20]]
        for y in 0..<height {
            for x in 0..<width {
                // Thin horizontal colour strokes and repeating text-like
                // stems/crossbars intentionally run through strip boundaries.
                let colour = (y % 3 == 0 || x % 9 == 2 || (y % 7 == 1 && x % 9 < 7))
                    ? colours[(y + x / 9) % colours.count] : [235, 235, 235]
                for c in 0..<3 { pixels[(y * width + x) * 4 + c] = colour[c] }
            }
        }
        return pixels
    }

    private func normalizedPixels(_ image: UIImage) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: source.width * source.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
        return pixels
    }

    private func assertSamePixels(_ actual: [UInt8], _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        if let mismatch = zip(actual, expected).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
            XCTFail("Pixel byte \(mismatch.offset): \(mismatch.element.0) != \(mismatch.element.1)", file: file, line: line)
        }
    }

    private func smoothColourPage(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let t = Double(y) / Double(max(1, height - 1))
            for x in 0..<width {
                let wave = sin(Double(x) / Double(max(1, width - 1)) * .pi * 2) * 9
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(max(0, min(255, Int((32 + 188 * t + wave).rounded()))))
                pixels[offset + 1] = UInt8(max(0, min(255, Int((48 + 142 * t - wave * 0.35).rounded()))))
                pixels[offset + 2] = UInt8(max(0, min(255, Int((226 - 166 * t + wave * 0.7).rounded()))))
            }
        }
        return pixels
    }

    private func imageFromRGBX(_ pixels: [UInt8], width: Int, height: Int) throws -> UIImage {
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.noneSkipLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    private func rgbxPixels(from image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(created)
        return pixels
    }

    /// Previous production implementation: crop and draw complete strips but
    /// do not repair codec contamination at their new neighbours.  It provides
    /// a coordinate-correct baseline for measuring the seam repair itself.
    private func legacyDecodedImage(
        _ data: Data,
        segmentationCount count: Int
    ) throws -> UIImage {
        let source = try ImageScrambler.rasterImage(from: data)
        let cgImage = try XCTUnwrap(source.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let baseHeight = height / count
        let remainder = height % count
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        return renderer.image { _ in
            for index in 0..<count {
                let sliceHeight = baseHeight + (index == 0 ? remainder : 0)
                let sourceY = height - baseHeight * (index + 1) - remainder
                let destinationY = baseHeight * index + (index == 0 ? 0 : remainder)
                guard let slice = cgImage.cropping(to: CGRect(
                    x: 0,
                    y: sourceY,
                    width: width,
                    height: sliceHeight
                )) else { continue }
                UIImage(cgImage: slice).draw(in: CGRect(
                    x: 0,
                    y: destinationY,
                    width: width,
                    height: sliceHeight
                ))
            }
        }
    }

    private func scrambleRows(
        _ original: [UInt8],
        width: Int,
        height: Int,
        segmentationCount count: Int
    ) -> [UInt8] {
        let bytesPerRow = width * 4
        let baseHeight = height / count
        let remainder = height % count
        var ranges: [Range<Int>] = []
        var start = 0
        for index in 0..<count {
            let blockHeight = baseHeight + (index == 0 ? remainder : 0)
            ranges.append(start..<(start + blockHeight))
            start += blockHeight
        }
        var output = [UInt8](repeating: 0, count: original.count)
        var destinationY = 0
        for range in ranges.reversed() {
            for sourceY in range {
                let sourceOffset = sourceY * bytesPerRow
                let destinationOffset = destinationY * bytesPerRow
                output.replaceSubrange(
                    destinationOffset..<(destinationOffset + bytesPerRow),
                    with: original[sourceOffset..<(sourceOffset + bytesPerRow)]
                )
                destinationY += 1
            }
        }
        return output
    }

    private func unscrambleRows(
        _ scrambled: [UInt8],
        width: Int,
        height: Int,
        segmentationCount count: Int
    ) -> [UInt8] {
        let bytesPerRow = width * 4
        let baseHeight = height / count
        let remainder = height % count
        var output = [UInt8](repeating: 0, count: scrambled.count)
        for index in 0..<count {
            let blockHeight = baseHeight + (index == 0 ? remainder : 0)
            let sourceY = height - baseHeight * (index + 1) - remainder
            let destinationY = baseHeight * index + (index == 0 ? 0 : remainder)
            for row in 0..<blockHeight {
                let sourceOffset = (sourceY + row) * bytesPerRow
                let destinationOffset = (destinationY + row) * bytesPerRow
                output.replaceSubrange(
                    destinationOffset..<(destinationOffset + bytesPerRow),
                    with: scrambled[sourceOffset..<(sourceOffset + bytesPerRow)]
                )
            }
        }
        return output
    }

    private func decodedStripJoins(height: Int, segmentationCount count: Int) -> [Int] {
        let baseHeight = height / count
        let remainder = height % count
        return (1..<count).map { baseHeight * $0 + remainder }
    }

    private func meanBoundaryChromaResidual(
        _ pixels: [UInt8],
        width: Int,
        joins: [Int]
    ) -> Double {
        let bytesPerRow = width * 4
        var total = 0.0
        var samples = 0
        for join in joins {
            let topY = join - 3
            let bottomY = join + 2
            for rowOffset in 1..<5 {
                let y = topY + rowOffset
                let topWeight = Double(5 - rowOffset) / 5
                let bottomWeight = Double(rowOffset) / 5
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let top = topY * bytesPerRow + x * 4
                    let bottom = bottomY * bytesPerRow + x * 4
                    let expectedR = Double(pixels[top]) * topWeight + Double(pixels[bottom]) * bottomWeight
                    let expectedG = Double(pixels[top + 1]) * topWeight + Double(pixels[bottom + 1]) * bottomWeight
                    let expectedB = Double(pixels[top + 2]) * topWeight + Double(pixels[bottom + 2]) * bottomWeight
                    let actualR = Double(pixels[offset])
                    let actualG = Double(pixels[offset + 1])
                    let actualB = Double(pixels[offset + 2])
                    let expectedY = expectedR * 0.299 + expectedG * 0.587 + expectedB * 0.114
                    let actualY = actualR * 0.299 + actualG * 0.587 + actualB * 0.114
                    total += abs((actualR - actualY) - (expectedR - expectedY))
                    total += abs((actualB - actualY) - (expectedB - expectedY))
                    samples += 2
                }
            }
        }
        return total / Double(max(1, samples))
    }

    private func meanBoundaryLuminanceDifference(
        lhs: [UInt8],
        rhs: [UInt8],
        width: Int,
        joins: [Int]
    ) -> Double {
        let bytesPerRow = width * 4
        var total = 0.0
        var samples = 0
        for join in joins {
            for y in (join - 2)...(join + 1) {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let lhsY = Double(lhs[offset]) * 0.299
                        + Double(lhs[offset + 1]) * 0.587
                        + Double(lhs[offset + 2]) * 0.114
                    let rhsY = Double(rhs[offset]) * 0.299
                        + Double(rhs[offset + 1]) * 0.587
                        + Double(rhs[offset + 2]) * 0.114
                    total += abs(lhsY - rhsY)
                    samples += 1
                }
            }
        }
        return total / Double(max(1, samples))
    }

    func testAlbumParsingAndSingleChapterFallback() {
        let detail = ComicDetail(json: [
            "id": "123",
            "name": "Example",
            "author": ["A"],
            "tags": ["中文"],
            "comment_total": "7",
            "is_favorite": true,
            "series": []
        ])
        XCTAssertEqual(detail.chapters, [Chapter(id: "123", title: "第 1 话", sort: 1)])
        XCTAssertEqual(detail.commentCount, 7)
        XCTAssertTrue(detail.isFavorite)
    }

    func testExploreSectionsStaySeparateAndKeepStableMenuIdentity() {
        let latest = [ComicSummary(id: "1", name: "最新一", authors: [], tags: [])]
        let promoted = [
            HomeSection(json: [
                "title": "連載更新",
                "content": [["id": "2", "name": "連載一"]]
            ]),
            HomeSection(json: [
                "title": "C107 & 推荐",
                "content": [["id": "3", "name": "推荐一"]]
            ]),
            HomeSection(json: [
                "title": "右滑看更多",
                "content": []
            ])
        ]

        let first = ExploreContentSection.make(latest: latest, promoted: promoted)
        let refreshed = ExploreContentSection.make(latest: latest, promoted: promoted)

        XCTAssertEqual(first.map(\.title), ["最新更新", "連載更新", "C107 & 推荐", "右滑看更多"])
        XCTAssertEqual(first.map { $0.comics.map(\.id) }, [["1"], ["2"], ["3"], []])
        XCTAssertEqual(first.map(\.id), refreshed.map(\.id))

        let emptyLatest = ExploreContentSection.make(latest: [], promoted: promoted)
        XCTAssertEqual(emptyLatest.first?.title, "最新更新")
        XCTAssertEqual(emptyLatest.first?.comics, [])
        XCTAssertEqual(emptyLatest.dropFirst().map(\.title), promoted.map(\.title))
    }

    func testAlbumParsesSearchableMetadataAndRelatedRecommendations() throws {
        let detail = ComicDetail(json: [
            "id": "123",
            "name": "Example",
            "author": ["主作者"],
            "tags": ["全彩", "巨乳"],
            "works": ["测试作品"],
            "actors": ["测试角色"],
            "series": [],
            "related_list": [
                ["id": "456", "name": "推荐一", "author": "Author With Spaces"],
                ["id": "456", "name": "重复项", "author": "重复作者"],
                ["id": "123", "name": "当前漫画", "author": "当前作者"],
                ["id": "789", "name": "推荐二", "author": ["作者 A", "作者 B"]]
            ]
        ])

        XCTAssertEqual(detail.tags, ["全彩", "巨乳"])
        XCTAssertEqual(detail.works, ["测试作品"])
        XCTAssertEqual(detail.actors, ["测试角色"])
        XCTAssertEqual(detail.relatedComics.map(\.id), ["456", "789"])
        XCTAssertEqual(detail.relatedComics.first?.authors, ["Author With Spaces"])
        XCTAssertEqual(detail.relatedComics.last?.authors, ["作者 A", "作者 B"])
    }

    func testSearchDestinationNormalizesPrefilledAuthorOrTag() {
        XCTAssertEqual(SearchView(initialQuery: "  全彩\n").initialQuery, "全彩")
        XCTAssertEqual(SearchView(initialQuery: "Author With Spaces").initialQuery, "Author With Spaces")
    }

    func testCommentHTMLIsCleanedOnceForCommentsAndNestedReplies() throws {
        let comment = ComicComment(json: [
            "CID": "parent",
            "content": "<div style='flex-direction:row;flex-wrap:wrap;'>第一行<br>第二行 &amp; 朋友</div><p><span>第三行&nbsp;内容</span></p>",
            "replys": [[
                "CID": "reply",
                "content": "<div>回复 <strong>重点</strong><script>alert('ignored')</script><br/>&lt;测试&gt; &#x1F621;</div>",
                "replys": [[
                    "CID": "nested-reply",
                    "content": "<span>数字实体：&#20320;&#22909;</span>"
                ]]
            ]]
        ])

        XCTAssertEqual(comment.content, "第一行\n第二行 & 朋友\n第三行 内容")
        let reply = try XCTUnwrap(comment.replies.first)
        XCTAssertEqual(reply.content, "回复 重点\n<测试> 😡")
        XCTAssertEqual(reply.replies.first?.content, "数字实体：你好")
        XCTAssertEqual(CommentHTMLText.plainText(from: "喜欢 <3，1 < 2 也是普通文本"), "喜欢 <3，1 < 2 也是普通文本")
        XCTAssertEqual(CommentHTMLText.plainText(from: "<div>A</div><br><br><br><p>B</p>"), "A\n\nB")
    }

    func testCommentSubmissionUsesCurrentMultipartFieldsAndStrictBusinessStatus() throws {
        let topLevel = try APIClient.commentSubmissionForm(
            comicID: " 778899 ",
            content: "  中文评论\n&+=  "
        )
        XCTAssertEqual(topLevel["aid"], "778899")
        XCTAssertEqual(topLevel["comment"], "中文评论\n&+=")
        XCTAssertEqual(topLevel["status"], "1")
        XCTAssertNil(topLevel["comment_id"])

        let reply = try APIClient.commentSubmissionForm(
            comicID: "778899",
            content: "回复",
            replyingTo: " 456 "
        )
        XCTAssertEqual(reply["comment_id"], "456")

        let boundary = "JMComic-Test-Boundary"
        let body = try XCTUnwrap(
            String(
                data: APIClient.multipartFormData(reply, boundary: boundary),
                encoding: .utf8
            )
        )
        XCTAssertTrue(body.contains("name=\"comment\"\r\n"))
        XCTAssertTrue(body.contains("name=\"aid\"\r\n"))
        XCTAssertTrue(body.contains("name=\"status\"\r\n"))
        XCTAssertTrue(body.contains("name=\"comment_id\"\r\n"))
        XCTAssertTrue(body.contains("Content-Transfer-Encoding: binary\r\n"))
        XCTAssertTrue(body.contains("\r\n\r\n回复\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))

        XCTAssertEqual(
            try APIClient.commentSubmissionMessage(from: [
                "status": " OK ",
                "msg": "评论成功",
                "cid": 123
            ] as JSONDictionary),
            "评论成功"
        )
        XCTAssertEqual(
            try APIClient.commentSubmissionMessage(from: [
                "status": "ok",
                "msg": "   "
            ] as JSONDictionary),
            "评论已发送"
        )
        XCTAssertThrowsError(
            try APIClient.commentSubmissionMessage(from: [
                "status": "error",
                "msg": "评论被拒绝"
            ] as JSONDictionary)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "评论被拒绝")
        }
        XCTAssertThrowsError(
            try APIClient.commentSubmissionMessage(from: [
                "msg": "缺少业务状态"
            ] as JSONDictionary)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "缺少业务状态")
        }
        XCTAssertThrowsError(
            try APIClient.commentSubmissionMessage(from: [
                "status": "error",
                "msg": "   "
            ] as JSONDictionary)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "评论提交失败")
        }
        XCTAssertThrowsError(
            try APIClient.commentSubmissionMessage(from: "评论已发送")
        ) { error in
            XCTAssertEqual(error.localizedDescription, "服务器返回的数据无效")
        }
        XCTAssertThrowsError(
            try APIClient.commentSubmissionForm(comicID: "invalid", content: "评论")
        )
    }

    func testUserCommentPageKeepsComicDestinationAndCleansHTML() throws {
        let page = CommentPage(json: [
            "total": "1",
            "list": [[
                "AID": "778899",
                "CID": "comment-1",
                "UID": "42",
                "username": "",
                "nickname": "昵称用户",
                "name": "评论所属漫画",
                "content": "<div>我的评论<br>第二行</div>",
                "likes": "7",
                "addtime": "Jul 15, 2026",
                "replys": [[
                    "CID": "reply-1",
                    "content": "<span>回复 &amp; 内容</span>"
                ]]
            ]]
        ])

        XCTAssertEqual(page.total, 1)
        let comment = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(comment.id, "comment-1")
        XCTAssertEqual(comment.username, "昵称用户")
        XCTAssertEqual(comment.content, "我的评论\n第二行")
        XCTAssertEqual(comment.likes, 7)
        XCTAssertEqual(comment.replies.first?.content, "回复 & 内容")
        XCTAssertEqual(comment.destinationComic?.id, "778899")
        XCTAssertEqual(comment.destinationComic?.name, "评论所属漫画")
    }

    func testUserCommentComicTitleUsesAlternateWireKeysWithoutShowingJMNumber() throws {
        let alternate = ComicComment(json: [
            "AID": "1084888",
            "CID": "comment-alternate",
            "name": "JM1084888",
            "album_name": "真实漫画名",
            "content": "评论"
        ])
        XCTAssertEqual(alternate.comicName, "真实漫画名")
        XCTAssertEqual(alternate.destinationComic?.name, "真实漫画名")

        let missing = ComicComment(json: [
            "AID": "1084888",
            "CID": "comment-missing-title",
            "content": "评论"
        ])
        XCTAssertTrue(missing.comicName.isEmpty)
        XCTAssertEqual(missing.destinationComic?.name, "漫画详情")
        XCTAssertNotEqual(missing.destinationComic?.name, "JM1084888")

        let pseudoOnly = ComicComment(json: [
            "AID": "1084888",
            "CID": "comment-pseudo-title",
            "name": "jm1084888",
            "content": "评论"
        ])
        XCTAssertTrue(pseudoOnly.comicName.isEmpty)
        XCTAssertEqual(pseudoOnly.destinationComic?.name, "漫画详情")
    }

    func testCommentHTMLCleanerPreservesAngleBracketProseAndHandlesHiddenNesting() {
        let prose = "1 < value > 0，C++ vector<int>，<love>仍是普通文字，1 < div > 0"
        XCTAssertEqual(CommentHTMLText.plainText(from: prose), prose)
        XCTAssertEqual(
            CommentHTMLText.plainText(from: "<love>真心</love><div>可见</div>"),
            "<love>真心</love>\n可见"
        )

        XCTAssertEqual(
            CommentHTMLText.plainText(from: "前<script>外<script>内</script>外<style>样式</style></script>后"),
            "前后"
        )
        XCTAssertEqual(
            CommentHTMLText.plainText(from: "A<script />B<style/>C<script>隐<style/>仍隐</script>D"),
            "ABCD"
        )
        XCTAssertEqual(
            CommentHTMLText.plainText(from: "<script><style>不可见</script>仍不可见</style>也不可见"),
            ""
        )
    }

    func testFavoriteFolderParsing() {
        let page = FavoritePage(json: [
            "total": "2",
            "list": [["id": "1", "name": "Comic"]],
            "folder_list": [["FID": "9", "name": "稍后看"]]
        ])
        XCTAssertEqual(page.folders.map(\.id), ["0", "9"])
        XCTAssertEqual(page.comics.first?.name, "Comic")
        XCTAssertEqual(page.count, 1)
    }

    func testLegacyOfflineChapterMigration() throws {
        let data = #"{"id":"1","title":"第一话","relativePagePaths":["1/1/00001.jpg"]}"#.data(using: .utf8)!
        let chapter = try JSONDecoder().decode(OfflineChapter.self, from: data)
        XCTAssertEqual(chapter.expectedPageCount, 1)
        XCTAssertTrue(chapter.isComplete)

        let comicData = #"{"comic":{"id":"9","name":"Legacy","authors":[],"tags":[]},"chapters":[]}"#
            .data(using: .utf8)!
        let legacyComic = try JSONDecoder().decode(OfflineComic.self, from: comicData)
        XCTAssertNil(legacyComic.coverRelativePath)
    }

    func testSQLiteOfflineCoverPathMigratesPersistsAndRejectsUnsafeValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        var legacyHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyHandle), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE comics (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            storage_directory_name TEXT NOT NULL,
            added_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        INSERT INTO comics VALUES ('cover-1', 'Cover Test', 'Cover Test-Author', 1, 1);
        """
        XCTAssertEqual(sqlite3_exec(legacyHandle, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacyHandle), SQLITE_OK)

        let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
        let migrated = try XCTUnwrap(database.loadLibrary().first)
        XCTAssertNil(migrated.coverRelativePath)

        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: migrated.id)
        XCTAssertTrue(JMComicCoverCacheStorage.isSafeRelativePath(relativePath))
        try database.setComicCoverRelativePath(
            comicID: migrated.id,
            relativePath: relativePath
        )
        XCTAssertEqual(try database.comicCoverRelativePath(comicID: migrated.id), relativePath)
        XCTAssertEqual(try database.loadLibrary().first?.coverRelativePath, relativePath)

        try database.upsertComic(migrated.comic, storageDirectoryName: migrated.storageDirectoryName)
        XCTAssertEqual(try database.loadLibrary().first?.coverRelativePath, relativePath)

        for unsafe in ["/cache/cover.jpg", "cache/../cover.jpg", "download/cover.jpg", "cache/a/b.jpg"] {
            XCTAssertThrowsError(try database.setComicCoverRelativePath(
                comicID: migrated.id,
                relativePath: unsafe
            ))
        }

        let firstCollision = JMComicCoverCacheStorage.relativePath(comicID: "same/id")
        let secondCollision = JMComicCoverCacheStorage.relativePath(comicID: "same\\id")
        XCTAssertNotEqual(firstCollision, secondCollision)
        XCTAssertTrue(JMComicCoverCacheStorage.isSafeRelativePath(firstCollision))
        XCTAssertEqual(
            JMComicStorageLayout.cacheRoot(documentsRoot: directory).lastPathComponent,
            "cache"
        )
    }

    func testDownloadConcurrencyPreferencesPersistAndClampToFive() throws {
        let suiteName = "JMComicTests.download-concurrency.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            DownloadConcurrencyPreferences.cachedImageRequests(defaults: defaults),
            DownloadConcurrencyPreferences.defaultCachedImageRequests
        )
        defaults.set(0, forKey: DownloadConcurrencyPreferences.cachedImageRequestsKey)
        defaults.set(99, forKey: DownloadConcurrencyPreferences.simultaneousComicsKey)
        defaults.set(5, forKey: DownloadConcurrencyPreferences.pageDownloadsPerComicKey)
        XCTAssertEqual(DownloadConcurrencyPreferences.cachedImageRequests(defaults: defaults), 1)
        XCTAssertEqual(DownloadConcurrencyPreferences.simultaneousComics(defaults: defaults), 5)
        XCTAssertEqual(DownloadConcurrencyPreferences.pageDownloadsPerComic(defaults: defaults), 5)
        XCTAssertEqual(DownloadConcurrencyPreferences.bounded(-8), 1)
        XCTAssertEqual(DownloadConcurrencyPreferences.bounded(8), 5)
    }

    func testSQLiteOfflineLibraryLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OfflineLibraryDatabase(databaseURL: directory.appendingPathComponent("JMComic.db"))
        let comic = ComicSummary(id: "123", name: "测试漫画", authors: ["作者"], tags: ["中文"])
        let chapter = Chapter(id: "456", title: "第 1 话", sort: 1)

        try database.upsertComic(comic, storageDirectoryName: "测试漫画-作者")
        try database.upsertChapter(comicID: comic.id, chapter: chapter, expectedPageCount: 1)
        try database.reservePage(
            chapterID: chapter.id,
            pageIndex: 0,
            globalOrdinal: 1,
            relativePath: "测试漫画-作者/测试漫画-1.jpg"
        )
        XCTAssertEqual(try database.loadLibrary().first?.chapters.first?.relativePagePaths, [])

        try database.markPageCompleted(chapterID: chapter.id, pageIndex: 0)
        let loaded = try XCTUnwrap(database.loadLibrary().first)
        XCTAssertEqual(loaded.storageDirectoryName, "测试漫画-作者")
        XCTAssertEqual(loaded.comic.authors, ["作者"])
        XCTAssertEqual(loaded.chapters.first?.relativePagePaths, ["测试漫画-作者/测试漫画-1.jpg"])

        let firstAddedAt = loaded.addedAt
        try database.upsertComic(comic, storageDirectoryName: "测试漫画-作者")
        let updated = try XCTUnwrap(database.loadLibrary().first)
        XCTAssertEqual(updated.addedAt, firstAddedAt)
        XCTAssertGreaterThanOrEqual(updated.updatedAt, loaded.updatedAt)

        try database.deleteComic(comicID: comic.id)
        XCTAssertTrue(try database.loadLibrary().isEmpty)
    }

    func testSQLiteFavoriteCachePaginationSyncAndAccountIsolation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OfflineLibraryDatabase(databaseURL: directory.appendingPathComponent("JMComic.db"))
        let folders = [
            FavoriteFolder(id: "0", name: "全部收藏", count: 3),
            FavoriteFolder(id: "9", name: "稍后看", count: 1)
        ]
        try database.replaceFavoriteFolders(accountID: "account-a", folders: folders)

        let page1 = FavoritePage(json: [
            "total": 3,
            "list": [
                ["id": "1", "name": "漫画 1", "author": ["作者 A"], "tags": ["中文"]],
                ["id": "2", "name": "漫画 2", "author": ["作者 B"], "tags": ["完结"]]
            ],
            "folder_list": [["FID": "9", "name": "稍后看", "count": 1]]
        ])
        let page2 = FavoritePage(json: [
            "total": 3,
            "list": [["id": "3", "name": "漫画 3", "author": ["作者 C"], "tags": []]],
            "folder_list": [["FID": "9", "name": "稍后看", "count": 1]]
        ])
        try database.cacheFavoritePage(
            accountID: "account-a", folderID: "0", page: 1, pageSize: 2,
            result: page1, syncToken: "complete"
        )
        try database.cacheFavoritePage(
            accountID: "account-a", folderID: "0", page: 2, pageSize: 2,
            result: page2, syncToken: "complete"
        )
        try database.finishFavoriteSync(
            accountID: "account-a", folderID: "0", syncToken: "complete", total: 3
        )

        let firstTwo = try database.cachedFavoritePage(
            accountID: "account-a", folderID: "0", offset: 0, limit: 2
        )
        let finalOne = try database.cachedFavoritePage(
            accountID: "account-a", folderID: "0", offset: 2, limit: 2
        )
        XCTAssertEqual(firstTwo.total, 3)
        XCTAssertEqual(firstTwo.comics.map(\.id), ["1", "2"])
        XCTAssertEqual(firstTwo.comics.first?.authors, ["作者 A"])
        XCTAssertEqual(firstTwo.comics.first?.tags, ["中文"])
        XCTAssertEqual(finalOne.comics.map(\.id), ["3"])
        XCTAssertNotNil(try database.lastFavoriteSync(accountID: "account-a", folderID: "0"))

        // 未覆盖全部远程总数时，finish 必须回滚，不得清理旧页。
        try database.cacheFavoritePage(
            accountID: "account-a", folderID: "0", page: 1, pageSize: 2,
            result: page1, syncToken: "incomplete"
        )
        XCTAssertThrowsError(try database.finishFavoriteSync(
            accountID: "account-a", folderID: "0", syncToken: "incomplete", total: 3
        ))
        XCTAssertEqual(
            try database.cachedFavoritePage(accountID: "account-a", folderID: "0", offset: 2, limit: 1)
                .comics.map(\.id),
            ["3"]
        )

        // 相同收藏夹 ID / 漫画 ID 在另一账号中必须完全隔离。
        try database.replaceFavoriteFolders(
            accountID: "account-b",
            folders: [FavoriteFolder(id: "0", name: "Account B", count: 1)]
        )
        let accountBPage = FavoritePage(json: [
            "total": 1,
            "list": [["id": "1", "name": "B 账号漫画", "author": ["B 作者"]]],
            "folder_list": []
        ])
        try database.cacheFavoritePage(
            accountID: "account-b", folderID: "0", page: 1, pageSize: 20,
            result: accountBPage, syncToken: "account-b-token"
        )
        try database.finishFavoriteSync(
            accountID: "account-b", folderID: "0", syncToken: "account-b-token", total: 1
        )
        XCTAssertEqual(
            try database.cachedFavoritePage(accountID: "account-b", folderID: "0", offset: 0, limit: 10)
                .comics.first?.name,
            "B 账号漫画"
        )
        XCTAssertEqual(
            try database.cachedFavoritePage(accountID: "account-a", folderID: "0", offset: 0, limit: 1)
                .comics.first?.name,
            "漫画 1"
        )

        // folder_list 并不保证返回 count，重读收藏夹时不能把已同步数量抹成 0。
        let customPage = FavoritePage(json: [
            "total": 1,
            "count": 20,
            "list": [["id": "2", "name": "漫画 2"]],
            "folder_list": [["FID": "9", "name": "稍后看"]]
        ])
        try database.cacheFavoritePage(
            accountID: "account-a", folderID: "9", page: 1, pageSize: 20,
            result: customPage, syncToken: "custom-token"
        )
        try database.finishFavoriteSync(
            accountID: "account-a", folderID: "9", syncToken: "custom-token", total: 1
        )
        try database.replaceFavoriteFolders(accountID: "account-a", folders: folders)
        XCTAssertEqual(
            try database.cachedFavoriteFolders(accountID: "account-a").first(where: { $0.id == "9" })?.count,
            1
        )

        let assignments = try database.favoriteFolderAssignments(
            accountID: "account-a",
            comicIDs: ["1", "2", "missing"]
        )
        XCTAssertEqual(assignments["1"]?.folderID, "0")
        XCTAssertEqual(assignments["1"]?.folderName, "全部收藏")
        // Comic 2 exists in both the aggregate folder and the custom folder;
        // custom membership must win deterministically.
        XCTAssertEqual(assignments["2"]?.folderID, "9")
        XCTAssertEqual(assignments["2"]?.folderName, "稍后看")
        XCTAssertNil(assignments["missing"])
    }

    func testSQLiteFavoriteCacheHandlesThreeThousandComics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OfflineLibraryDatabase(databaseURL: directory.appendingPathComponent("JMComic.db"))
        let total = 3_000
        let pageSize = 20
        let token = UUID().uuidString
        try database.replaceFavoriteFolders(
            accountID: "large-account",
            folders: [FavoriteFolder(id: "0", name: "全部收藏", count: total)]
        )

        for page in 1...(total / pageSize) {
            let start = (page - 1) * pageSize
            let rows: [JSONDictionary] = (start..<(start + pageSize)).map { index in
                [
                    "id": String(index),
                    "name": "漫画 \(index)",
                    "author": ["作者 \(index % 50)"],
                    "tags": ["标签 \(index % 20)"]
                ]
            }
            let result = FavoritePage(json: [
                "total": total,
                "count": pageSize,
                "list": rows,
                "folder_list": []
            ])
            try database.cacheFavoritePage(
                accountID: "large-account",
                folderID: "0",
                page: page,
                pageSize: pageSize,
                result: result,
                syncToken: token
            )
        }
        try database.finishFavoriteSync(
            accountID: "large-account",
            folderID: "0",
            syncToken: token,
            total: total
        )

        let tail = try database.cachedFavoritePage(
            accountID: "large-account", folderID: "0", offset: 2_940, limit: 60
        )
        XCTAssertEqual(tail.total, total)
        XCTAssertEqual(tail.comics.count, 60)
        XCTAssertEqual(tail.comics.first?.id, "2940")
        XCTAssertEqual(tail.comics.last?.id, "2999")
        XCTAssertEqual(tail.comics.last?.authors, ["作者 49"])
        XCTAssertTrue(
            try database.cachedFavoritePage(
                accountID: "large-account",
                folderID: "0",
                sortOrder: .updated,
                offset: 0,
                limit: 60
            ).comics.isEmpty
        )
    }

    func testSQLiteFavoriteIncrementalPrependOrderDeduplicationAndIsolation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OfflineLibraryDatabase(databaseURL: directory.appendingPathComponent("JMComic.db"))
        let accountA = "incremental-account-a"
        let accountB = "incremental-account-b"
        let folderID = "0"
        let initialSyncDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldComics = (0..<40).map { index in
            ComicSummary(
                id: "old-\(index)",
                name: "旧漫画 \(index)",
                authors: ["旧作者 \(index % 3)"],
                tags: ["旧标签"]
            )
        }

        try database.replaceFavoriteFolders(
            accountID: accountA,
            folders: [FavoriteFolder(id: folderID, name: "全部收藏", count: oldComics.count)]
        )
        let syncToken = "initial-full-sync"
        for page in 1...2 {
            let lower = (page - 1) * 20
            let upper = page * 20
            let pageComics = Array(oldComics[lower..<upper])
            let result = FavoritePage(json: [
                "total": oldComics.count,
                "count": 20,
                "list": pageComics.map { comic in
                    [
                        "id": comic.id,
                        "name": comic.name,
                        "author": comic.authors,
                        "tags": comic.tags
                    ] as JSONDictionary
                },
                "folder_list": []
            ])
            try database.cacheFavoritePage(
                accountID: accountA,
                folderID: folderID,
                page: page,
                pageSize: 20,
                result: result,
                syncToken: syncToken,
                at: initialSyncDate
            )
        }
        try database.finishFavoriteSync(
            accountID: accountA,
            folderID: folderID,
            syncToken: syncToken,
            total: oldComics.count,
            at: initialSyncDate
        )

        let existing = try database.existingFavoriteComicIDs(
            accountID: accountA,
            folderID: folderID,
            comicIDs: ["new-1", "old-0", "old-39", "old-0"]
        )
        XCTAssertEqual(existing, ["old-0", "old-39"])

        let new1 = ComicSummary(id: "new-1", name: "新漫画 1", authors: ["新作者"], tags: ["新标签"])
        let new2 = ComicSummary(id: "new-2", name: "新漫画 2", authors: ["新作者"], tags: ["新标签"])
        let new3 = ComicSummary(id: "new-3", name: "新漫画 3", authors: ["第三作者"], tags: ["置顶"])
        XCTAssertEqual(
            try database.prependFavoriteComics(
                accountID: accountA,
                folderID: folderID,
                comics: [new1, new2, new2]
            ),
            2
        )
        XCTAssertEqual(
            try database.prependFavoriteComics(
                accountID: accountA,
                folderID: folderID,
                comics: [oldComics[0], new3, new3]
            ),
            1
        )

        let cached = try database.cachedFavoritePage(
            accountID: accountA,
            folderID: folderID,
            offset: 0,
            limit: 50
        )
        XCTAssertEqual(cached.total, 43)
        XCTAssertEqual(Array(cached.comics.prefix(5).map(\.id)), ["new-3", "new-1", "new-2", "old-0", "old-1"])
        XCTAssertEqual(cached.comics.first?.authors, ["第三作者"])
        XCTAssertEqual(cached.comics.first?.tags, ["置顶"])
        XCTAssertEqual(try database.favoriteMembershipCount(accountID: accountA, folderID: folderID), 43)
        XCTAssertEqual(try database.lastFavoriteSync(accountID: accountA, folderID: folderID), initialSyncDate)

        // 收藏夹列表可先看到远端 badge，但内容分页总数必须始终取本地实际成员数。
        try database.replaceFavoriteFolders(
            accountID: accountA,
            folders: [FavoriteFolder(id: folderID, name: "全部收藏", count: 99)]
        )
        XCTAssertEqual(
            try database.cachedFavoritePage(
                accountID: accountA,
                folderID: folderID,
                offset: 0,
                limit: 10
            ).total,
            43
        )

        try database.replaceFavoriteFolders(
            accountID: accountB,
            folders: [FavoriteFolder(id: folderID, name: "全部收藏", count: 0)]
        )
        XCTAssertEqual(try database.favoriteMembershipCount(accountID: accountB, folderID: folderID), 0)
        XCTAssertTrue(
            try database.existingFavoriteComicIDs(
                accountID: accountB,
                folderID: folderID,
                comicIDs: ["new-1", "old-0"]
            ).isEmpty
        )
    }

    func testSQLiteFavoriteOrderNamespacesMigrateLegacyMembershipsToMR() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        var legacyHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyHandle), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE favorite_folders (
            account_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            name TEXT NOT NULL,
            sort INTEGER NOT NULL,
            total INTEGER NOT NULL DEFAULT 0,
            last_synced_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (account_id, folder_id)
        );
        CREATE TABLE favorite_comics (
            account_id TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            name TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, comic_id)
        );
        CREATE TABLE favorite_memberships (
            account_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            sync_token TEXT NOT NULL,
            PRIMARY KEY (account_id, folder_id, comic_id),
            FOREIGN KEY (account_id, folder_id)
                REFERENCES favorite_folders(account_id, folder_id) ON DELETE CASCADE,
            FOREIGN KEY (account_id, comic_id)
                REFERENCES favorite_comics(account_id, comic_id) ON DELETE CASCADE
        );
        INSERT INTO favorite_folders
            VALUES ('legacy-account', '0', '全部收藏', 0, 2, 123);
        INSERT INTO favorite_comics VALUES ('legacy-account', '1', '旧漫画 1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-account', '2', '旧漫画 2', 1);
        INSERT INTO favorite_memberships
            VALUES ('legacy-account', '0', '1', 0, 'legacy-token');
        INSERT INTO favorite_memberships
            VALUES ('legacy-account', '0', '2', 1, 'legacy-token');
        """
        XCTAssertEqual(sqlite3_exec(legacyHandle, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacyHandle), SQLITE_OK)

        do {
            let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
            XCTAssertEqual(
                try database.cachedFavoritePage(
                    accountID: "legacy-account",
                    folderID: "0",
                    sortOrder: .added,
                    offset: 0,
                    limit: 20
                ).comics.map(\.id),
                ["1", "2"]
            )
            XCTAssertTrue(
                try database.cachedFavoritePage(
                    accountID: "legacy-account",
                    folderID: "0",
                    sortOrder: .updated,
                    offset: 0,
                    limit: 20
                ).comics.isEmpty
            )
            XCTAssertEqual(
                try database.lastFavoriteSync(
                    accountID: "legacy-account",
                    folderID: "0",
                    sortOrder: .added
                ),
                Date(timeIntervalSince1970: 123)
            )
            XCTAssertNil(try database.lastFavoriteSync(
                accountID: "legacy-account",
                folderID: "0",
                sortOrder: .updated
            ))
        }

        // Opening the migrated database again must be idempotent.
        let reopened = try OfflineLibraryDatabase(databaseURL: databaseURL)
        XCTAssertEqual(
            try reopened.favoriteMembershipCount(
                accountID: "legacy-account",
                folderID: "0",
                sortOrder: .added
            ),
            2
        )
        XCTAssertEqual(
            try reopened.favoriteMembershipCount(
                accountID: "legacy-account",
                folderID: "0",
                sortOrder: .updated
            ),
            0
        )

        var verificationHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &verificationHandle), SQLITE_OK)
        defer { sqlite3_close(verificationHandle) }

        func scalar(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(verificationHandle, sql, -1, &statement, nil),
                SQLITE_OK
            )
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }
        XCTAssertEqual(
            scalar("SELECT pk FROM pragma_table_info('favorite_memberships') WHERE name = 'order_mode'"),
            3
        )
        XCTAssertEqual(
            scalar("""
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'index' AND name IN (
                    'idx_favorite_memberships_page',
                    'idx_favorite_memberships_sync',
                    'idx_favorite_memberships_comic'
                )
                """),
            3
        )
        var foreignKeyCheck: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                verificationHandle,
                "PRAGMA foreign_key_check",
                -1,
                &foreignKeyCheck,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(foreignKeyCheck), SQLITE_DONE)
        sqlite3_finalize(foreignKeyCheck)
    }

    func testSQLiteFavoriteLegacySyncStateBackfillRejectsIncompleteOrCorruptCaches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        var legacyHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyHandle), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE favorite_folders (
            account_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            name TEXT NOT NULL,
            sort INTEGER NOT NULL,
            total INTEGER NOT NULL DEFAULT 0,
            last_synced_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (account_id, folder_id)
        );
        CREATE TABLE favorite_comics (
            account_id TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            name TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, comic_id)
        );
        CREATE TABLE favorite_memberships (
            account_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            sync_token TEXT NOT NULL,
            PRIMARY KEY (account_id, folder_id, comic_id),
            FOREIGN KEY (account_id, folder_id)
                REFERENCES favorite_folders(account_id, folder_id) ON DELETE CASCADE,
            FOREIGN KEY (account_id, comic_id)
                REFERENCES favorite_comics(account_id, comic_id) ON DELETE CASCADE
        );

        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'valid', 'valid', 0, 2, 101);
        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'gap', 'gap', 1, 2, 102);
        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'count', 'count', 2, 3, 103);
        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'tokens', 'tokens', 3, 2, 104);
        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'incremental', 'incremental', 4, 2, 105);
        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'mixed-tokens', 'mixed-tokens', 5, 3, 106);
        INSERT INTO favorite_folders VALUES ('legacy-corrupt', 'empty', 'empty', 6, 0, 107);

        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'valid-0', 'valid-0', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'valid-1', 'valid-1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'gap-0', 'gap-0', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'gap-1', 'gap-1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'count-0', 'count-0', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'count-1', 'count-1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'tokens-0', 'tokens-0', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'tokens-1', 'tokens-1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'incremental-0', 'incremental-0', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'incremental-1', 'incremental-1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'mixed-0', 'mixed-0', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'mixed-1', 'mixed-1', 1);
        INSERT INTO favorite_comics VALUES ('legacy-corrupt', 'mixed-2', 'mixed-2', 1);

        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'valid', 'valid-0', 0, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'valid', 'valid-1', 1, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'gap', 'gap-0', 0, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'gap', 'gap-1', 2, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'count', 'count-0', 0, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'count', 'count-1', 1, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'tokens', 'tokens-0', 0, 'full-a');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'tokens', 'tokens-1', 1, 'full-b');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'incremental', 'incremental-0', 0, 'full');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'incremental', 'incremental-1', 1, 'incremental');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'mixed-tokens', 'mixed-0', 0, 'full-a');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'mixed-tokens', 'mixed-1', 1, 'full-b');
        INSERT INTO favorite_memberships VALUES ('legacy-corrupt', 'mixed-tokens', 'mixed-2', 2, 'incremental');
        """
        XCTAssertEqual(sqlite3_exec(legacyHandle, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacyHandle), SQLITE_OK)

        for attempt in 0..<2 {
            let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
            XCTAssertEqual(
                try database.lastFavoriteSync(
                    accountID: "legacy-corrupt", folderID: "valid", sortOrder: .added
                ),
                Date(timeIntervalSince1970: 101),
                "valid cache must migrate on attempt \(attempt)"
            )
            XCTAssertEqual(
                try database.lastFavoriteSync(
                    accountID: "legacy-corrupt", folderID: "incremental", sortOrder: .added
                ),
                Date(timeIntervalSince1970: 105),
                "one full token plus incremental rows is valid"
            )
            XCTAssertEqual(
                try database.lastFavoriteSync(
                    accountID: "legacy-corrupt", folderID: "empty", sortOrder: .added
                ),
                Date(timeIntervalSince1970: 107),
                "an empty zero-total cache is complete"
            )
            for invalidFolder in ["gap", "count", "tokens", "mixed-tokens"] {
                XCTAssertNil(
                    try database.lastFavoriteSync(
                        accountID: "legacy-corrupt",
                        folderID: invalidFolder,
                        sortOrder: .added
                    ),
                    "\(invalidFolder) must remain uninitialised on attempt \(attempt)"
                )
            }
            XCTAssertEqual(
                try database.favoriteMembershipCount(
                    accountID: "legacy-corrupt", folderID: "gap", sortOrder: .added
                ),
                2,
                "migration validation must not discard the readable legacy cache"
            )
        }
    }

    func testSQLiteFavoriteMRAndMPStayIndependentAndMPLeadingPageIsContinuous() throws {
        XCTAssertEqual(FavoriteComicSortOrder.added.rawValue, "mr")
        XCTAssertEqual(FavoriteComicSortOrder.updated.rawValue, "mp")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("JMComic.db")
        let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
        let accountID = "dual-order-account"
        let folderID = "0"
        let addedDate = Date(timeIntervalSince1970: 100)
        let updatedDate = Date(timeIntervalSince1970: 200)
        let comics = (0..<40).map { index in
            ComicSummary(
                id: "old-\(index)",
                name: "漫画 \(index)",
                authors: ["作者 \(index % 4)"],
                tags: ["标签"]
            )
        }
        try database.replaceFavoriteFolders(
            accountID: accountID,
            folders: [FavoriteFolder(id: folderID, name: "全部收藏", count: comics.count)]
        )

        func page(_ pageComics: [ComicSummary], total: Int) -> FavoritePage {
            FavoritePage(json: [
                "total": total,
                "count": 20,
                "list": pageComics.map { comic in
                    [
                        "id": comic.id,
                        "name": comic.name,
                        "author": comic.authors,
                        "tags": comic.tags
                    ] as JSONDictionary
                },
                "folder_list": []
            ])
        }

        func fullSync(
            order: FavoriteComicSortOrder,
            orderedComics: [ComicSummary],
            at date: Date
        ) throws {
            // Deliberately reuse one token across both modes: the mode column,
            // not token uniqueness, must provide isolation.
            let token = "same-token"
            for pageNumber in 1...2 {
                let lower = (pageNumber - 1) * 20
                let upper = pageNumber * 20
                try database.cacheFavoritePage(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: order,
                    page: pageNumber,
                    pageSize: 20,
                    result: page(Array(orderedComics[lower..<upper]), total: orderedComics.count),
                    syncToken: token,
                    at: date
                )
            }
            try database.finishFavoriteSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: order,
                syncToken: token,
                total: orderedComics.count,
                at: date
            )
        }

        try fullSync(order: .added, orderedComics: comics, at: addedDate)
        try fullSync(order: .updated, orderedComics: Array(comics.reversed()), at: updatedDate)
        XCTAssertEqual(
            try database.cachedFavoritePage(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .added,
                offset: 0,
                limit: 40
            ).comics.map(\.id),
            comics.map(\.id)
        )
        XCTAssertEqual(
            try database.cachedFavoritePage(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .updated,
                offset: 0,
                limit: 40
            ).comics.map(\.id),
            comics.reversed().map(\.id)
        )

        // An unchanged `mp` leading page should update comic metadata without
        // rewriting all membership rows/tokens in a large collection.
        var verificationHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &verificationHandle), SQLITE_OK)
        defer { sqlite3_close(verificationHandle) }
        func unchangedTokenCount() -> Int32 {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    verificationHandle,
                    """
                    SELECT COUNT(*) FROM favorite_memberships
                    WHERE account_id = 'dual-order-account'
                      AND folder_id = '0'
                      AND order_mode = 'mp'
                      AND sync_token = 'same-token'
                    """,
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }
        XCTAssertEqual(unchangedTokenCount(), 40)
        try database.replaceFavoriteLeadingPage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: .updated,
            comics: Array(comics.reversed().prefix(20)),
            remoteTotal: 40
        )
        XCTAssertEqual(unchangedTokenCount(), 40)

        let newComic = ComicSummary(id: "new", name: "新更新漫画")
        let leading = [comics[0], comics[39], newComic]
        try database.replaceFavoriteLeadingPage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: .updated,
            comics: leading,
            remoteTotal: 41
        )

        let expectedUpdated = leading.map(\.id)
            + comics.reversed().map(\.id).filter { !Set(leading.map(\.id)).contains($0) }
        let refreshed = try database.cachedFavoritePage(
            accountID: accountID,
            folderID: folderID,
            sortOrder: .updated,
            offset: 0,
            limit: 50
        )
        XCTAssertEqual(refreshed.total, 41)
        XCTAssertEqual(refreshed.comics.map(\.id), expectedUpdated)
        // Offset inside the old first page must not land in a position hole.
        XCTAssertEqual(
            try database.cachedFavoritePage(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .updated,
                offset: 20,
                limit: 20
            ).comics.count,
            20
        )
        XCTAssertEqual(
            try database.cachedFavoritePage(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .added,
                offset: 0,
                limit: 50
            ).comics.map(\.id),
            comics.map(\.id)
        )
        XCTAssertEqual(
            try database.lastFavoriteSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .added
            ),
            addedDate
        )
        XCTAssertEqual(
            try database.lastFavoriteSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .updated
            ),
            updatedDate
        )
    }

    func testSQLiteBeginFavoriteFullSyncPreservesCacheAndMarksOnlyThatModeIncomplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("JMComic.db")
        let accountID = "interrupted-account"
        let folderID = "0"
        let addedDate = Date(timeIntervalSince1970: 301)
        let updatedDate = Date(timeIntervalSince1970: 302)
        let comics = [
            ComicSummary(id: "1", name: "漫画 1"),
            ComicSummary(id: "2", name: "漫画 2")
        ]
        let page = FavoritePage(json: [
            "total": 2,
            "count": 20,
            "list": comics.map { ["id": $0.id, "name": $0.name] },
            "folder_list": []
        ])

        do {
            let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
            try database.replaceFavoriteFolders(
                accountID: accountID,
                folders: [FavoriteFolder(id: folderID, name: "全部收藏", count: 2)]
            )
            for (order, date) in [
                (FavoriteComicSortOrder.added, addedDate),
                (FavoriteComicSortOrder.updated, updatedDate)
            ] {
                try database.cacheFavoritePage(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: order,
                    page: 1,
                    pageSize: 20,
                    result: page,
                    syncToken: "full-\(order.rawValue)",
                    at: date
                )
                try database.finishFavoriteSync(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: order,
                    syncToken: "full-\(order.rawValue)",
                    total: 2,
                    at: date
                )
            }

            try database.beginFavoriteFullSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .updated
            )
            XCTAssertNil(try database.lastFavoriteSync(
                accountID: accountID, folderID: folderID, sortOrder: .updated
            ))
            XCTAssertEqual(
                try database.lastFavoriteSync(
                    accountID: accountID, folderID: folderID, sortOrder: .added
                ),
                addedDate
            )
            XCTAssertEqual(
                try database.favoriteMembershipCount(
                    accountID: accountID, folderID: folderID, sortOrder: .updated
                ),
                2
            )
        }

        // Simulate an app termination in the middle of the full refresh.
        do {
            let reopened = try OfflineLibraryDatabase(databaseURL: databaseURL)
            XCTAssertNil(try reopened.lastFavoriteSync(
                accountID: accountID, folderID: folderID, sortOrder: .updated
            ))
            XCTAssertEqual(
                try reopened.cachedFavoritePage(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: .updated,
                    offset: 0,
                    limit: 20
                ).comics.map(\.id),
                ["1", "2"]
            )
            XCTAssertEqual(
                try reopened.lastFavoriteSync(
                    accountID: accountID, folderID: folderID, sortOrder: .added
                ),
                addedDate
            )

            try reopened.beginFavoriteFullSync(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .added
            )
            XCTAssertNil(try reopened.lastFavoriteSync(
                accountID: accountID, folderID: folderID, sortOrder: .added
            ))
            XCTAssertEqual(
                try reopened.favoriteMembershipCount(
                    accountID: accountID, folderID: folderID, sortOrder: .added
                ),
                2
            )
        }

        let reopenedAgain = try OfflineLibraryDatabase(databaseURL: databaseURL)
        XCTAssertNil(try reopenedAgain.lastFavoriteSync(
            accountID: accountID, folderID: folderID, sortOrder: .added
        ))
        XCTAssertEqual(
            try reopenedAgain.cachedFavoritePage(
                accountID: accountID,
                folderID: folderID,
                sortOrder: .added,
                offset: 0,
                limit: 20
            ).comics.map(\.id),
            ["1", "2"]
        )
    }

    func testFavoriteCoverPathMigratesPersistsAndSharesPhysicalCacheReference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        var legacyHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyHandle), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE favorite_comics (
            account_id TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            name TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, comic_id)
        );
        INSERT INTO favorite_comics VALUES ('account-a', 'shared-cover', '旧收藏', 1);
        """
        XCTAssertEqual(sqlite3_exec(legacyHandle, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacyHandle), SQLITE_OK)

        let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
        let comic = ComicSummary(
            id: "shared-cover",
            name: "共享封面",
            authors: ["作者"],
            tags: ["标签"]
        )
        let result = FavoritePage(json: [
            "total": 1,
            "count": 20,
            "list": [[
                "id": comic.id,
                "name": comic.name,
                "author": comic.authors,
                "tags": comic.tags
            ]],
            "folder_list": []
        ])
        try database.replaceFavoriteFolders(
            accountID: "account-a",
            folders: [FavoriteFolder(id: "0", name: "全部收藏", count: 1)]
        )
        try database.cacheFavoritePage(
            accountID: "account-a",
            folderID: "0",
            page: 1,
            pageSize: 20,
            result: result,
            syncToken: "first"
        )

        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: comic.id)
        try database.setFavoriteComicCoverRelativePath(
            accountID: "account-a",
            comicID: comic.id,
            relativePath: relativePath
        )
        XCTAssertEqual(
            try database.favoriteComicCoverRelativePath(
                accountID: "account-a",
                comicID: comic.id
            ),
            relativePath
        )
        XCTAssertEqual(
            try database.cachedFavoritePage(
                accountID: "account-a",
                folderID: "0",
                offset: 0,
                limit: 20
            ).coverRelativePaths[comic.id],
            relativePath
        )

        // Normal favorite refreshes update metadata but keep the local cover.
        try database.cacheFavoritePage(
            accountID: "account-a",
            folderID: "0",
            page: 1,
            pageSize: 20,
            result: result,
            syncToken: "second"
        )
        XCTAssertEqual(
            try database.favoriteComicCoverRelativePath(
                accountID: "account-a",
                comicID: comic.id
            ),
            relativePath
        )

        // Downloads and any number of favorite accounts may share one file.
        try database.upsertComic(comic, storageDirectoryName: "共享封面-作者")
        try database.setComicCoverRelativePath(comicID: comic.id, relativePath: relativePath)
        XCTAssertTrue(try database.isCoverRelativePathReferenced(relativePath))
        try database.deleteComic(comicID: comic.id)
        XCTAssertTrue(try database.isCoverRelativePathReferenced(relativePath))

        for unsafe in ["/cache/cover.jpg", "cache/../cover.jpg", "download/cover.jpg"] {
            XCTAssertThrowsError(try database.setFavoriteComicCoverRelativePath(
                accountID: "account-a",
                comicID: comic.id,
                relativePath: unsafe
            ))
        }

        try database.clearCoverRelativePathReferences(relativePath)
        XCTAssertNil(try database.favoriteComicCoverRelativePath(
            accountID: "account-a",
            comicID: comic.id
        ))
        XCTAssertFalse(try database.isCoverRelativePathReferenced(relativePath))

        var verificationHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &verificationHandle), SQLITE_OK)
        defer { sqlite3_close(verificationHandle) }

        var versionStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(verificationHandle, "PRAGMA user_version", -1, &versionStatement, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(versionStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(versionStatement, 0), 5)
        sqlite3_finalize(versionStatement)

        var indexStatement: OpaquePointer?
        let indexSQL = """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'index'
          AND name IN (
              'idx_comics_cover_relative_path',
              'idx_favorite_comics_cover_relative_path'
          )
        """
        XCTAssertEqual(
            sqlite3_prepare_v2(verificationHandle, indexSQL, -1, &indexStatement, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(indexStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(indexStatement, 0), 2)
        sqlite3_finalize(indexStatement)
    }

    func testVisibleDownloadNamesRespectUTF8FilesystemByteLimit() throws {
        // This mirrors the reported long Japanese/Chinese title. The previous
        // Character-based 100/120 limits produced 300+ byte APFS components.
        let title = String(repeating: "[山櫻漢化]サンクリ漫画", count: 30)
        let author = String(repeating: "作者テスト", count: 20)
        let comic = ComicSummary(id: "987654", name: title, authors: [author], tags: [])
        let folder = DownloadStorageNaming.folderName(for: comic)
        let filename = DownloadStorageNaming.pageFileName(comicName: title, imageNumber: 28)
        let relativePath = DownloadStorageNaming.relativePath(
            comicName: title,
            storageDirectoryName: folder,
            chapterDirectoryName: DownloadStorageNaming.chapterFolderName(chapterTitle: "第 1 话"),
            imageNumber: 28
        )

        XCTAssertLessThanOrEqual(folder.utf8.count, DownloadStorageNaming.generatedComponentByteLimit)
        XCTAssertLessThanOrEqual(filename.utf8.count, DownloadStorageNaming.generatedComponentByteLimit)
        XCTAssertTrue(folder.hasSuffix("-" + DownloadStorageNaming.safeComponent(author, maxUTF8Bytes: 72)))
        XCTAssertTrue(filename.hasSuffix("-28.jpg"))
        XCTAssertTrue(DownloadStorageNaming.isSafeRelativePagePath(
            relativePath,
            directoryName: folder,
            chapterDirectoryName: DownloadStorageNaming.chapterFolderName(chapterTitle: "第 1 话")
        ))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("image".utf8).write(to: destination, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: destination), Data("image".utf8))

        // An old DB reservation may contain an invalid component; rewriting the
        // same page primary key to the generated path must be supported.
        let database = try OfflineLibraryDatabase(databaseURL: root.appendingPathComponent("JMComic.db"))
        let chapter = Chapter(id: "chapter-long-path", title: "第 1 话", sort: 1)
        try database.upsertComic(comic, storageDirectoryName: folder)
        try database.upsertChapter(comicID: comic.id, chapter: chapter, expectedPageCount: 1)
        let oldInvalidPath = "\(String(repeating: "漫", count: 100))/\(String(repeating: "画", count: 100)).jpg"
        try database.reservePage(
            chapterID: chapter.id,
            pageIndex: 0,
            globalOrdinal: 1,
            relativePath: oldInvalidPath
        )
        try database.reservePage(
            chapterID: chapter.id,
            pageIndex: 0,
            globalOrdinal: 1,
            relativePath: relativePath
        )
        let repaired = try XCTUnwrap(database.pageRecords(comicID: comic.id, chapterID: chapter.id).first)
        XCTAssertEqual(repaired.relativePath, relativePath)
        XCTAssertFalse(repaired.completed)
    }

    func testChapterDownloadAttemptRejectsReentryAndStaleCallbacks() throws {
        let registry = DownloadAttemptRegistry()
        let progressID = "comic-1:chapter-1"

        XCTAssertEqual(registry.beginIfIdle(progressID: progressID, token: "attempt-A"), "attempt-A")
        XCTAssertNil(registry.beginIfIdle(progressID: progressID, token: "duplicate"))
        XCTAssertTrue(registry.isCurrent(progressID: progressID, token: "attempt-A"))

        XCTAssertTrue(registry.finishIfCurrent(progressID: progressID, token: "attempt-A"))
        XCTAssertEqual(registry.beginIfIdle(progressID: progressID, token: "attempt-B"), "attempt-B")
        XCTAssertFalse(registry.isCurrent(progressID: progressID, token: "attempt-A"))
        // A late callback from A cannot finish/remove B.
        XCTAssertFalse(registry.finishIfCurrent(progressID: progressID, token: "attempt-A"))
        XCTAssertTrue(registry.isCurrent(progressID: progressID, token: "attempt-B"))

        let cancelled = URLError(.cancelled)
        XCTAssertTrue(DownloadFailurePolicy.isCancellation(cancelled))
        XCTAssertTrue(DownloadFailurePolicy.isCancellation(NSError(
            domain: "JMComicTests",
            code: 7,
            userInfo: [NSUnderlyingErrorKey: cancelled]
        )))
        XCTAssertFalse(DownloadFailurePolicy.isCancellation(URLError(.timedOut)))

    }

    func testDownloadDescriptorPersistsAttemptAndDecodesLegacyTask() throws {
        let descriptor = PageDownloadDescriptor(
            comic: ComicSummary(id: "comic", name: "name", authors: ["author"], tags: []),
            chapterID: "chapter",
            chapterTitle: "chapter title",
            chapterSort: 1,
            scrambleID: 123,
            filename: "00001.jpg",
            pageIndex: 0,
            globalOrdinal: 1,
            totalPages: 2,
            relativePath: "folder/name-1.jpg",
            imageDomains: ["https://image.invalid"],
            domainIndex: 0,
            referer: "https://api.invalid",
            attemptID: "attempt-uuid",
            imageProcessing: .repairChroma,
            imageStorage: .spaceSavingJPEG
        )
        let encoded = try JSONEncoder().encode(descriptor)
        let restored = try JSONDecoder().decode(PageDownloadDescriptor.self, from: encoded)
        XCTAssertEqual(restored.attemptToken, "attempt-uuid")
        XCTAssertEqual(restored.imageProcessing, .repairChroma)
        XCTAssertEqual(restored.imageStorage, .spaceSavingJPEG)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "attemptID")
        legacyObject.removeValue(forKey: "imageProcessing")
        legacyObject.removeValue(forKey: "imageStorage")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(PageDownloadDescriptor.self, from: legacyData)
        XCTAssertNil(legacy.attemptID)
        XCTAssertNil(legacy.imageProcessing)
        XCTAssertNil(legacy.imageStorage)
        XCTAssertEqual(legacy.attemptToken, "legacy:comic:chapter")
    }

    func testPageStoragePreferencesAndMixedLegacyLibrary() throws {
        let suite = "PageStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PageImagePreferences.processing(defaults: defaults), .faithful)
        XCTAssertEqual(PageImagePreferences.storage(defaults: defaults), .lossless)
        defaults.set(true, forKey: PageImagePreferences.repairChromaKey)
        defaults.set(PageImageStorage.spaceSavingJPEG.rawValue, forKey: PageImagePreferences.storageKey)
        let capturedProcessing = PageImagePreferences.processing(defaults: defaults)
        let capturedStorage = PageImagePreferences.storage(defaults: defaults)
        defaults.set(false, forKey: PageImagePreferences.repairChromaKey)
        defaults.set(PageImageStorage.lossless.rawValue, forKey: PageImagePreferences.storageKey)
        XCTAssertEqual(capturedProcessing, .repairChroma)
        XCTAssertEqual(capturedStorage, .spaceSavingJPEG)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try OfflineLibraryDatabase(databaseURL: root.appendingPathComponent("library.db"))
        let comic = ComicSummary(id: "synthetic", name: "Synthetic")
        let chapter = Chapter(id: "1452616", title: "Strips", sort: 1)
        try database.upsertComic(comic, storageDirectoryName: "pages")
        try database.upsertChapter(comicID: comic.id, chapter: chapter, expectedPageCount: 2)
        let original = try imageFromRGBX(colourDetailPage(width: 37, height: 173), width: 37, height: 173)
        let legacy = try XCTUnwrap(original.jpegData(compressionQuality: 0.96))
        let legacyPath = "legacy.jpg"
        try legacy.write(to: root.appendingPathComponent(legacyPath))
        try database.upsertPage(chapterID: chapter.id, pageIndex: 0, globalOrdinal: 1, relativePath: legacyPath)
        let descriptor = PageDownloadDescriptor(
            comic: comic, chapterID: chapter.id, chapterTitle: chapter.title, chapterSort: 1,
            scrambleID: 220_980, filename: "00001.jpg", pageIndex: 1, globalOrdinal: 2, totalPages: 2,
            relativePath: "page-2.jpg", imageDomains: [], domainIndex: 0, referer: "", attemptID: "fixture",
            imageProcessing: PageImagePreferences.processing(defaults: defaults),
            imageStorage: PageImagePreferences.storage(defaults: defaults)
        )
        let encoded = try ImageScrambler.decode(legacy, scrambleID: descriptor.scrambleID, photoID: descriptor.chapterID, filename: descriptor.filename, processing: descriptor.imageProcessing!, storage: descriptor.imageStorage!)
        let stored = descriptor.storing(encoded)
        XCTAssertEqual(stored.relativePath, "page-2.png")
        try database.reservePage(chapterID: chapter.id, pageIndex: 1, globalOrdinal: 2, relativePath: stored.relativePath)
        let destination = root.appendingPathComponent(stored.relativePath)
        try encoded.data.write(to: destination, options: .atomic)
        try database.upsertPage(chapterID: chapter.id, pageIndex: 1, globalOrdinal: 2, relativePath: stored.relativePath)
        let records = try database.pageRecords(comicID: comic.id, chapterID: chapter.id)
        XCTAssertEqual(records.map(\.relativePath), [legacyPath, "page-2.png"])
        XCTAssertTrue(records.allSatisfy(\.completed))
        for record in records {
            let bytes = try Data(contentsOf: root.appendingPathComponent(record.relativePath))
            let image = try ImageScrambler.rasterImage(from: bytes)
            XCTAssertEqual(image.cgImage?.width, 37)
            XCTAssertEqual(image.cgImage?.height, 173)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(legacyPath)), legacy)
        XCTAssertTrue(DownloadStorageNaming.pageFileName(comicName: String(repeating: "长", count: 100), imageNumber: 2, fileExtension: "png").hasSuffix(".png"))
    }

    func testCompletedPathMigrationRollsBackWhenSQLiteCommitFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = try OfflineLibraryDatabase(databaseURL: root.appendingPathComponent("JMComic.db"))
        let comic = ComicSummary(id: "migration-comic", name: "Migration", authors: [], tags: [])
        let chapter = Chapter(id: "migration-chapter", title: "Chapter", sort: 1)
        try database.upsertComic(comic, storageDirectoryName: "new-folder")
        try database.upsertChapter(comicID: comic.id, chapter: chapter, expectedPageCount: 2)

        let oldRelativePath = "old-folder/old-page.jpg"
        let newRelativePath = "new-folder/new-page.jpg"
        let source = root.appendingPathComponent(oldRelativePath)
        let destination = root.appendingPathComponent(newRelativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalBytes = Data("completed image".utf8)
        try originalBytes.write(to: source)
        try database.upsertPage(
            chapterID: chapter.id,
            pageIndex: 0,
            globalOrdinal: 1,
            relativePath: oldRelativePath
        )
        // Reserve the proposed path for another row so SQLite's UNIQUE index
        // rejects page 0 only after the helper has moved its physical file.
        try database.reservePage(
            chapterID: chapter.id,
            pageIndex: 1,
            globalOrdinal: 2,
            relativePath: newRelativePath
        )

        XCTAssertThrowsError(try DownloadPathMigration.moveCompletedFileThenCommit(
            source: source,
            destination: destination,
            createDestinationDirectory: {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            },
            commitIndex: { remainsCompleted in
                XCTAssertTrue(remainsCompleted)
                try database.upsertPage(
                    chapterID: chapter.id,
                    pageIndex: 0,
                    globalOrdinal: 1,
                    relativePath: newRelativePath
                )
            }
        ))

        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let unchanged = try XCTUnwrap(database.pageRecords(comicID: comic.id, chapterID: chapter.id).first)
        XCTAssertEqual(unchanged.relativePath, oldRelativePath)
        XCTAssertTrue(unchanged.completed)

        // Once the conflict is removed, file and index migrate together and a
        // same-process load sees only the repaired path.
        try database.deletePage(chapterID: chapter.id, pageIndex: 1)
        XCTAssertTrue(try DownloadPathMigration.moveCompletedFileThenCommit(
            source: source,
            destination: destination,
            createDestinationDirectory: {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            },
            commitIndex: { remainsCompleted in
                XCTAssertTrue(remainsCompleted)
                try database.upsertPage(
                    chapterID: chapter.id,
                    pageIndex: 0,
                    globalOrdinal: 1,
                    relativePath: newRelativePath
                )
            }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        XCTAssertEqual(try database.loadLibrary().first?.chapters.first?.relativePagePaths, [newRelativePath])
    }

    func testDownloadTransferLimiterEnforcesComicAndPerComicPageLimits() async {
        let limiter = DownloadTransferLimiter()
        let recorder = LimiterPeakRecorder()
        await withTaskGroup(of: Void.self) { group in
            for comicIndex in 0..<4 {
                for pageIndex in 0..<5 {
                    group.addTask {
                        let token = "comic-\(comicIndex)-page-\(pageIndex)"
                        await limiter.acquire(
                            token: token,
                            comicID: "comic-\(comicIndex)",
                            comicLimit: 2,
                            pageLimit: 2
                        )
                        let snapshot = await limiter.snapshot()
                        await recorder.observe(snapshot)
                        try? await Task.sleep(nanoseconds: 8_000_000)
                        await limiter.release(token: token)
                    }
                }
            }
            await group.waitForAll()
        }
        let peak = await recorder.peak()
        XCTAssertEqual(peak.activeComics, 2)
        XCTAssertEqual(peak.pagesForOneComic, 2)
    }

    func testDownloadLimiterRejectsRapidPauseResumeDuplicateToken() async {
        let limiter = DownloadTransferLimiter()
        let token = "attempt:comic:chapter:page-1"

        // A globally deferred page retains this original permit while paused.
        let firstAcquire = await limiter.acquire(
            token: token,
            comicID: "comic",
            comicLimit: 1,
            pageLimit: 1
        )
        XCTAssertTrue(firstAcquire)
        let pausedSnapshot = await limiter.snapshot()
        XCTAssertEqual(pausedSnapshot.activeComics, 1)
        XCTAssertEqual(pausedSnapshot.maximumPagesForOneComic, 1)

        // If a future regression schedules the same token again before an
        // asynchronous release, the limiter must reject it instead of returning
        // an untracked permit that breaks both concurrency ceilings.
        let duplicateAcquire = await limiter.acquire(
            token: token,
            comicID: "comic",
            comicLimit: 1,
            pageLimit: 1
        )
        XCTAssertFalse(duplicateAcquire)
        let duplicateSnapshot = await limiter.snapshot()
        XCTAssertEqual(duplicateSnapshot.activeComics, 1)
        XCTAssertEqual(duplicateSnapshot.maximumPagesForOneComic, 1)

        // Resume now starts the deferred descriptor directly with its retained
        // permit. Completion releases exactly once and restores full capacity.
        await limiter.release(token: token)
        let releasedSnapshot = await limiter.snapshot()
        XCTAssertEqual(releasedSnapshot.activeComics, 0)
        let reacquired = await limiter.acquire(
            token: token,
            comicID: "comic",
            comicLimit: 1,
            pageLimit: 1
        )
        XCTAssertTrue(reacquired)
        await limiter.release(token: token)
    }

    func testGlobalDownloadControlsPauseOnlyActiveWorkAndPreserveTerminalStates() {
        XCTAssertEqual(DownloadGlobalControlPolicy.pausing(.preparing), .paused)
        XCTAssertEqual(DownloadGlobalControlPolicy.pausing(.downloading), .paused)
        XCTAssertEqual(DownloadGlobalControlPolicy.pausing(.failed), .failed)
        XCTAssertEqual(DownloadGlobalControlPolicy.pausing(.finished), .finished)

        XCTAssertEqual(
            DownloadGlobalControlPolicy.resuming(.paused, totalPages: 0),
            .preparing
        )
        XCTAssertEqual(
            DownloadGlobalControlPolicy.resuming(.paused, totalPages: 20),
            .downloading
        )
        XCTAssertEqual(
            DownloadGlobalControlPolicy.resuming(.failed, totalPages: 20),
            .failed
        )
        XCTAssertEqual(
            DownloadGlobalControlPolicy.resuming(.finished, totalPages: 20),
            .finished
        )

        let active = ChapterDownloadProgress(
            id: "comic:chapter",
            comicID: "comic",
            comicName: "Comic",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            completedPages: 2,
            totalPages: 20,
            state: .downloading
        )
        XCTAssertTrue(DownloadGlobalControlPolicy.canPause([active], globallyPaused: false))
        XCTAssertFalse(DownloadGlobalControlPolicy.canPause([active], globallyPaused: true))
        var terminal = active
        terminal.state = .failed
        XCTAssertFalse(DownloadGlobalControlPolicy.canPause([terminal], globallyPaused: false))
    }

    func testVisibleDatabaseMigrationMovesBaseWALAndSHMIdempotently() throws {
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let legacy = documents.appendingPathComponent("JMComic.db")
        let payloads = [
            "": Data("database".utf8),
            "-wal": Data("wal-content".utf8),
            "-shm": Data("shm-content".utf8)
        ]
        for (suffix, data) in payloads {
            try data.write(to: URL(fileURLWithPath: legacy.path + suffix))
        }

        let destination = try JMComicStorageLayout.prepareDatabaseDirectory(
            documentsRoot: documents,
            fileManager: .default
        )
        XCTAssertEqual(destination, documents.appendingPathComponent("database/JMComic.db"))
        for (suffix, data) in payloads {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + suffix)), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path + suffix))
        }

        // A second launch must be a no-op and preserve all migrated bytes.
        XCTAssertEqual(
            try JMComicStorageLayout.prepareDatabaseDirectory(
                documentsRoot: documents,
                fileManager: .default
            ),
            destination
        )
        XCTAssertEqual(try Data(contentsOf: destination), payloads[""])
    }

    func testIndexedDownloadsMigrateIntoChapterFoldersAndDisambiguateDuplicateTitles() throws {
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let database = try OfflineLibraryDatabase(
            databaseURL: documents.appendingPathComponent("database/JMComic.db")
        )
        let comic = ComicSummary(id: "comic-storage", name: "漫画名", authors: ["作者"], tags: [])
        let folder = "漫画名-作者"
        let first = Chapter(id: "chapter-A", title: "特别篇", sort: 1)
        let second = Chapter(id: "chapter-B", title: "特别篇", sort: 2)
        let third = Chapter(id: "chapter-C", title: "第 3 话", sort: 3)
        try database.upsertComic(comic, storageDirectoryName: folder)
        try database.upsertChapter(comicID: comic.id, chapter: first, expectedPageCount: 1)
        try database.upsertChapter(comicID: comic.id, chapter: second, expectedPageCount: 1)
        try database.upsertChapter(comicID: comic.id, chapter: third, expectedPageCount: 1)

        let oldFirst = "\(folder)/漫画名-1.jpg"
        let oldSecond = "\(folder)/漫画名-2.jpg"
        // Some intermediate builds already wrote a chapter component into the
        // SQLite path while the physical file still lived below Documents.
        // Equal old/new relative paths must still move into Documents/download.
        let thirdFolder = DownloadStorageNaming.chapterFolderName(chapterTitle: third.title)
        let oldThird = "\(folder)/\(thirdFolder)/漫画名-3.jpg"
        try database.upsertPage(chapterID: first.id, pageIndex: 0, globalOrdinal: 1, relativePath: oldFirst)
        try database.upsertPage(chapterID: second.id, pageIndex: 0, globalOrdinal: 2, relativePath: oldSecond)
        try database.upsertPage(chapterID: third.id, pageIndex: 0, globalOrdinal: 3, relativePath: oldThird)
        for (relative, bytes) in [
            (oldFirst, Data("first".utf8)),
            (oldSecond, Data("second".utf8)),
            (oldThird, Data("third".utf8))
        ] {
            let url = documents.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }

        let downloadRoot = documents.appendingPathComponent("download", isDirectory: true)
        try DownloadStorageMigration.migrateIndexedLibrary(
            database: database,
            documentsRoot: documents,
            downloadRoot: downloadRoot
        )
        let firstFolder = DownloadStorageNaming.disambiguatedChapterFolderName(
            chapterTitle: first.title,
            chapterID: first.id
        )
        let secondFolder = DownloadStorageNaming.disambiguatedChapterFolderName(
            chapterTitle: second.title,
            chapterID: second.id
        )
        let newFirst = "\(folder)/\(firstFolder)/漫画名-1.jpg"
        let newSecond = "\(folder)/\(secondFolder)/漫画名-2.jpg"
        let newThird = oldThird
        XCTAssertEqual(try Data(contentsOf: downloadRoot.appendingPathComponent(newFirst)), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: downloadRoot.appendingPathComponent(newSecond)), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: downloadRoot.appendingPathComponent(newThird)), Data("third".utf8))
        let loaded = try XCTUnwrap(database.loadLibrary().first)
        XCTAssertEqual(loaded.chapters.first(where: { $0.id == first.id })?.relativePagePaths, [newFirst])
        XCTAssertEqual(loaded.chapters.first(where: { $0.id == second.id })?.relativePagePaths, [newSecond])
        XCTAssertEqual(loaded.chapters.first(where: { $0.id == third.id })?.relativePagePaths, [newThird])
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent(oldFirst).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent(oldThird).path))

        // Re-running after a successful or interrupted upgrade remains stable.
        try DownloadStorageMigration.migrateIndexedLibrary(
            database: database,
            documentsRoot: documents,
            downloadRoot: downloadRoot
        )
        XCTAssertEqual(try database.loadLibrary().first?.chapters.flatMap(\.relativePagePaths).count, 3)
        XCTAssertEqual(try Data(contentsOf: downloadRoot.appendingPathComponent(newFirst)), Data("first".utf8))
    }

    func testSQLiteSearchHistoryNormalizesDeduplicatesCapsAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        do {
            let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
            try database.recordSearchQuery(
                "  鬼   针草  ",
                at: Date(timeIntervalSince1970: 100),
                maximumEntries: 3
            )
            try database.recordSearchQuery(
                "ＡＢＣ",
                at: Date(timeIntervalSince1970: 200),
                maximumEntries: 3
            )
            try database.recordSearchQuery(
                "abc",
                at: Date(timeIntervalSince1970: 300),
                maximumEntries: 3
            )
            try database.recordSearchQuery(
                "第三条",
                at: Date(timeIntervalSince1970: 400),
                maximumEntries: 3
            )
            try database.recordSearchQuery(
                "第四条",
                at: Date(timeIntervalSince1970: 500),
                maximumEntries: 3
            )

            let history = try database.searchHistory(limit: 20)
            XCTAssertEqual(history.map(\.query), ["第四条", "第三条", "abc"])
            XCTAssertEqual(history.map(\.queryKey), ["第四条", "第三条", "abc"])
            XCTAssertEqual(history.last?.lastSearchedAt, Date(timeIntervalSince1970: 300))
        }

        let reopened = try OfflineLibraryDatabase(databaseURL: databaseURL)
        XCTAssertEqual(try reopened.searchHistory(limit: 20).map(\.query), ["第四条", "第三条", "abc"])
        try reopened.deleteSearchQuery("ＡＢＣ")
        XCTAssertEqual(try reopened.searchHistory(limit: 20).map(\.query), ["第四条", "第三条"])
        try reopened.clearSearchHistory()
        XCTAssertTrue(try reopened.searchHistory(limit: 20).isEmpty)
    }

    func testSQLiteComicTitleCacheFiltersInvalidValuesAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        do {
            let database = try OfflineLibraryDatabase(databaseURL: databaseURL)
            try database.cacheComicTitles([
                "1084888": "  真实漫画名  ",
                "": "不应写入",
                "empty-title": "   "
            ], at: Date(timeIntervalSince1970: 600))
            XCTAssertEqual(
                try database.cachedComicTitles(comicIDs: ["1084888", "", "empty-title"]),
                ["1084888": "真实漫画名"]
            )
        }

        let reopened = try OfflineLibraryDatabase(databaseURL: databaseURL)
        XCTAssertEqual(
            try reopened.cachedComicTitles(comicIDs: ["1084888"]),
            ["1084888": "真实漫画名"]
        )
    }

    func testSQLiteReadingHistoryIsNormalizedPagedAndCapped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ReadingHistoryDatabase(
            databaseURL: directory.appendingPathComponent("JMComic.db")
        )
        let first = ComicSummary(
            id: "history-1",
            name: "第一本",
            authors: ["作者 A", "作者 B"],
            tags: ["中文", "完结"]
        )
        let second = ComicSummary(
            id: "history-2",
            name: "第二本",
            authors: ["作者 B"],
            tags: ["连载"]
        )
        let third = ComicSummary(
            id: "history-3",
            name: "第三本",
            authors: [],
            tags: []
        )
        let chapter1 = Chapter(id: "chapter-1", title: "第 1 话", sort: 1)
        let chapter2 = Chapter(id: "chapter-2", title: "第 2 话", sort: 2)

        try database.record(
            comic: first, chapter: chapter1, pageIndex: 2,
            at: Date(timeIntervalSince1970: 100), maximumEntries: 2
        )
        try database.record(
            comic: second, chapter: chapter1, pageIndex: 4,
            at: Date(timeIntervalSince1970: 200), maximumEntries: 2
        )
        // Reopening the same comic updates one row instead of appending JSON-like snapshots.
        try database.record(
            comic: first, chapter: chapter2, pageIndex: 8,
            at: Date(timeIntervalSince1970: 300), maximumEntries: 2
        )

        let firstPage = try database.page(offset: 0, limit: 1)
        XCTAssertEqual(firstPage.map(\.id), ["history-1"])
        XCTAssertEqual(firstPage.first?.comic.authors, ["作者 A", "作者 B"])
        XCTAssertEqual(firstPage.first?.comic.tags, ["中文", "完结"])
        XCTAssertEqual(firstPage.first?.chapterID, "chapter-2")
        XCTAssertEqual(firstPage.first?.pageIndex, 8)
        XCTAssertEqual(try database.page(offset: 1, limit: 1).map(\.id), ["history-2"])

        try database.record(
            comic: third, chapter: chapter1, pageIndex: 0,
            at: Date(timeIntervalSince1970: 400), maximumEntries: 2
        )
        XCTAssertEqual(try database.page(offset: 0, limit: 10).map(\.id), ["history-3", "history-1"])

        try database.clear()
        XCTAssertTrue(try database.page(offset: 0, limit: 10).isEmpty)
    }

    func testReadingHistoryCoverPathMigratesPreservesAndReturnsReleasedPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("JMComic.db")

        // Build 8 and earlier databases have the history table but no cover
        // column. Opening the new store must upgrade this exact database in
        // place without depending on OfflineLibraryDatabase.user_version.
        var legacyHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyHandle), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE reading_history (
            comic_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            chapter_id TEXT NOT NULL,
            chapter_title TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK (page_index >= 0),
            first_viewed_at REAL NOT NULL,
            last_viewed_at REAL NOT NULL
        );
        INSERT INTO reading_history VALUES (
            'history-cover-1', 'Legacy History', 'chapter-1', '第 1 话', 2, 100, 100
        );
        """
        XCTAssertEqual(sqlite3_exec(legacyHandle, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacyHandle), SQLITE_OK)

        let database = try ReadingHistoryDatabase(databaseURL: databaseURL)
        XCTAssertNil(try database.coverRelativePath(comicID: "history-cover-1"))

        let firstPath = JMComicCoverCacheStorage.relativePath(comicID: "history-cover-1")
        XCTAssertTrue(JMComicCoverCacheStorage.isSafeRelativePath(firstPath))
        try database.setCoverRelativePath(comicID: "history-cover-1", relativePath: firstPath)

        // An ordinary reading-progress UPSERT updates metadata while preserving
        // the cover reference populated asynchronously by the image cache.
        let firstComic = ComicSummary(
            id: "history-cover-1",
            name: "Updated History",
            authors: ["作者"],
            tags: ["标签"]
        )
        let chapter = Chapter(id: "chapter-2", title: "第 2 话", sort: 2)
        XCTAssertTrue(try database.record(
            comic: firstComic,
            chapter: chapter,
            pageIndex: 9,
            at: Date(timeIntervalSince1970: 200),
            maximumEntries: 1
        ).isEmpty)
        XCTAssertEqual(try database.coverRelativePath(comicID: firstComic.id), firstPath)
        XCTAssertEqual(try database.page(offset: 0, limit: 10).first?.coverRelativePath, firstPath)

        for unsafe in ["/cache/cover.jpg", "cache/../cover.jpg", "download/cover.jpg", "cache/a/b.jpg"] {
            XCTAssertThrowsError(try database.setCoverRelativePath(
                comicID: firstComic.id,
                relativePath: unsafe
            ))
        }

        let secondComic = ComicSummary(id: "history-cover-2", name: "Second")
        let secondPath = JMComicCoverCacheStorage.relativePath(comicID: secondComic.id)
        XCTAssertEqual(
            try database.record(
                comic: secondComic,
                chapter: chapter,
                pageIndex: 0,
                at: Date(timeIntervalSince1970: 300),
                maximumEntries: 1
            ),
            [firstPath]
        )
        try database.setCoverRelativePath(comicID: secondComic.id, relativePath: secondPath)
        XCTAssertEqual(try database.clear(), [secondPath])

        var verificationHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &verificationHandle), SQLITE_OK)
        defer { sqlite3_close(verificationHandle) }

        var columnStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                verificationHandle,
                "SELECT COUNT(*) FROM pragma_table_info('reading_history') WHERE name = 'cover_relative_path'",
                -1,
                &columnStatement,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(columnStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(columnStatement, 0), 1)
        sqlite3_finalize(columnStatement)

        var indexStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                verificationHandle,
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_reading_history_cover_relative_path'",
                -1,
                &indexStatement,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(indexStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(indexStatement, 0), 1)
        sqlite3_finalize(indexStatement)
    }

    func testReadingHistoryCoverCleanupRetainsSharedDownloadAndFavoriteFile() throws {
        let documentsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documentsRoot) }
        let databaseURL = JMComicStorageLayout.databaseURL(documentsRoot: documentsRoot)
        let referenceDatabase = try OfflineLibraryDatabase(databaseURL: databaseURL)
        let historyDatabase = try ReadingHistoryDatabase(databaseURL: databaseURL)

        let comic = ComicSummary(
            id: "history-shared-cover",
            name: "Shared Cover",
            authors: ["Author"]
        )
        let chapter = Chapter(id: "history-shared-chapter", title: "Chapter", sort: 1)
        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: comic.id)
        let coverURL = try XCTUnwrap(JMComicCoverCacheStorage.fileURL(
            relativePath: relativePath,
            documentsRoot: documentsRoot
        ))
        try FileManager.default.createDirectory(
            at: coverURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cached-cover".utf8).write(to: coverURL, options: .atomic)

        try historyDatabase.record(comic: comic, chapter: chapter, pageIndex: 0)
        try historyDatabase.setCoverRelativePath(comicID: comic.id, relativePath: relativePath)
        XCTAssertEqual(
            try referenceDatabase.readingHistoryCoverRelativePath(comicID: comic.id),
            relativePath
        )

        try referenceDatabase.upsertComic(comic, storageDirectoryName: "Shared Cover-Author")
        try referenceDatabase.setComicCoverRelativePath(
            comicID: comic.id,
            relativePath: relativePath
        )
        try referenceDatabase.replaceFavoriteFolders(
            accountID: "cover-account",
            folders: [FavoriteFolder(id: "0", name: "全部收藏", count: 1)]
        )
        try referenceDatabase.cacheFavoritePage(
            accountID: "cover-account",
            folderID: "0",
            page: 1,
            pageSize: 20,
            result: FavoritePage(json: [
                "total": 1,
                "count": 20,
                "list": [["id": comic.id, "name": comic.name]],
                "folder_list": []
            ]),
            syncToken: "shared-cover"
        )
        try referenceDatabase.setFavoriteComicCoverRelativePath(
            accountID: "cover-account",
            comicID: comic.id,
            relativePath: relativePath
        )

        let releasedByHistory = try historyDatabase.clear()
        ReadingHistoryStore.removeUnreferencedCoverFiles(
            releasedByHistory,
            database: referenceDatabase,
            documentsRoot: documentsRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))

        // Removing the download still must retain the one physical file while
        // the favorite row owns the same deterministic cache path.
        try referenceDatabase.deleteComic(comicID: comic.id)
        ReadingHistoryStore.removeUnreferencedCoverFiles(
            [relativePath],
            database: referenceDatabase,
            documentsRoot: documentsRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))

        // Corrupt-file invalidation clears every DB owner. Once no owner remains,
        // the conservative cleanup may remove the visible cache file.
        try referenceDatabase.clearCoverRelativePathReferences(relativePath)
        XCTAssertFalse(try referenceDatabase.isCoverRelativePathReferenced(relativePath))
        ReadingHistoryStore.removeUnreferencedCoverFiles(
            [relativePath],
            database: referenceDatabase,
            documentsRoot: documentsRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverURL.path))

        // Unsafe paths and a failed/missing reference database never touch an
        // arbitrary file. This also verifies custom test roots stay isolated
        // from the process-wide JMComicDatabase.shared connection.
        let unrelated = documentsRoot.appendingPathComponent("unrelated.jpg")
        try Data("keep".utf8).write(to: unrelated)
        ReadingHistoryStore.removeUnreferencedCoverFiles(
            ["../unrelated.jpg", relativePath],
            database: nil,
            documentsRoot: documentsRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @MainActor
    func testAppearanceDefaultsAndPersistsSelection() throws {
        let suiteName = "JMComicTests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppAppearanceStore(defaults: defaults)
        XCTAssertEqual(initial.palette, .ivory)
        XCTAssertEqual(initial.colorMode, .system)
        initial.palette = .lightPink
        initial.colorMode = .dark

        let restored = AppAppearanceStore(defaults: defaults)
        XCTAssertEqual(restored.palette, .lightPink)
        XCTAssertEqual(restored.colorMode, .dark)
        XCTAssertEqual(restored.preferredColorScheme, .dark)
    }

    func testDailyStatusParsesNestedRecordsAndTodayState() {
        let today = Calendar.current.component(.day, from: .now)
        let otherDay = today == 1 ? 2 : 1
        let nestedRecords: [[JSONDictionary]] = [
            [["date": String(otherDay), "signed": false, "bonus": false]],
            [["date": today, "signed": true, "bonus": true]]
        ]
        let status = DailyStatus(json: [
            "daily_id": "77",
            "event_name": "每日签到",
            "currentProgress": "1/7",
            "three_days_coin": "3",
            "three_days_exp": 30,
            "seven_days_coin": 10,
            "seven_days_exp": "100",
            "record": nestedRecords
        ])

        XCTAssertEqual(status.dailyID, 77)
        XCTAssertEqual(status.records.count, 2)
        XCTAssertTrue(status.isSignedToday)
        XCTAssertEqual(status.signedDayCount, 1)
        XCTAssertTrue(status.records.first(where: { $0.date == today })?.bonus == true)
        XCTAssertEqual(status.threeDaysCoin, 3)
        XCTAssertEqual(status.sevenDaysExperience, 100)
    }

    func testDailyStatusUsesExplicitDatesThenSequentialFallbackAndCalculatesStreak() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let referenceDate = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 20)
        ))
        let nestedRecords: [[JSONDictionary]] = [[
            ["date": "2026-07-01", "signed": true, "bonus": false],
            ["signed": true, "bonus": true],
            ["date": "3", "signed": false, "bonus": false],
            ["date": 4, "signed": true, "bonus": false],
            ["date": "5", "signed": true, "bonus": false],
            ["date": "invalid", "signed": true, "bonus": true]
        ]]
        let status = DailyStatus(
            json: ["record": nestedRecords],
            referenceDate: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(status.calendarYear, 2026)
        XCTAssertEqual(status.calendarMonth, 7)
        XCTAssertEqual(status.records.map(\.date), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(status.signedDayCount, 5)
        XCTAssertEqual(status.longestSignedStreak, 3)
        XCTAssertTrue(status.recordsByDay[2]?.bonus == true)
        XCTAssertTrue(status.recordsByDay[6]?.bonus == true)
    }

    func testDailyStatusDoesNotTreatSameDayNumberInAnotherMonthAsToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let july = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 20)
        ))
        let august = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 20)
        ))
        let status = DailyStatus(
            json: ["record": [["date": 20, "signed": true, "bonus": false]]],
            referenceDate: july,
            calendar: calendar
        )

        XCTAssertTrue(status.isSigned(on: july, calendar: calendar))
        XCTAssertFalse(status.isSigned(on: august, calendar: calendar))
        XCTAssertFalse(DailyCheckInSubmissionPolicy.needsFreshStatus(
            userID: "42",
            statusUserID: "42",
            status: status,
            now: july,
            calendar: calendar
        ))
        XCTAssertTrue(DailyCheckInSubmissionPolicy.needsFreshStatus(
            userID: "42",
            statusUserID: "42",
            status: status,
            now: august,
            calendar: calendar
        ))
        XCTAssertTrue(DailyCheckInSubmissionPolicy.needsFreshStatus(
            userID: "42",
            statusUserID: "another-account",
            status: status,
            now: july,
            calendar: calendar
        ))
    }

    func testDailyMonthLayoutUsesSundayFirstAndHandlesLeapYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let july2026 = DailyMonthLayout(year: 2026, month: 7, calendar: calendar)
        XCTAssertEqual(july2026.leadingEmptyDays, 3)
        XCTAssertEqual(july2026.numberOfDays, 31)

        let february2024 = DailyMonthLayout(year: 2024, month: 2, calendar: calendar)
        XCTAssertEqual(february2024.leadingEmptyDays, 4)
        XCTAssertEqual(february2024.numberOfDays, 29)
        XCTAssertEqual(DailyCalendarSystem.current.identifier, .gregorian)
    }

    func testDailyStatusFiltersDaysOutsideMonthAndOptimisticallyMarksSuccessfulDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let february = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2025, month: 2, day: 20)
        ))
        let status = DailyStatus(
            json: [
                "daily_id": 88,
                "record": [
                    ["date": 20, "signed": false, "bonus": true],
                    ["date": 28, "signed": true, "bonus": false],
                    ["date": 29, "signed": true, "bonus": false],
                    ["date": 30, "signed": true, "bonus": false],
                    ["date": 31, "signed": true, "bonus": false]
                ]
            ],
            referenceDate: february,
            calendar: calendar
        )

        XCTAssertEqual(status.records.map(\.date), [20, 28])
        XCTAssertEqual(status.signedDayCount, 1)

        let optimistic = status.markingSigned(on: february, calendar: calendar)
        XCTAssertTrue(optimistic.isSigned(on: february, calendar: calendar))
        XCTAssertTrue(optimistic.recordsByDay[20]?.bonus == true)
        XCTAssertEqual(optimistic.signedDayCount, 2)
    }

    func testDailyStatusLoadsOncePerAccountUnlessUserForcesRefresh() {
        XCTAssertFalse(DailyStatusRefreshPolicy.shouldLoad(
            userID: nil,
            attemptedUserID: nil,
            force: true
        ))
        XCTAssertTrue(DailyStatusRefreshPolicy.shouldLoad(
            userID: "account-a",
            attemptedUserID: nil,
            force: false
        ))
        // Re-entering the account tab must not retry even when the one startup
        // attempt failed and therefore did not produce a snapshot.
        XCTAssertFalse(DailyStatusRefreshPolicy.shouldLoad(
            userID: "account-a",
            attemptedUserID: "account-a",
            force: false
        ))
        XCTAssertTrue(DailyStatusRefreshPolicy.shouldLoad(
            userID: "account-a",
            attemptedUserID: "account-a",
            force: true
        ))
        XCTAssertTrue(DailyStatusRefreshPolicy.shouldLoad(
            userID: "account-b",
            attemptedUserID: "account-a",
            force: false
        ))
    }

    func testStartupRefreshesSavedCredentialsOnceAndFallsBackToAVSWithoutThem() throws {
        let validAVS = try XCTUnwrap(HTTPCookie(properties: [
            .name: "AVS",
            .value: "restored-session",
            .domain: "example.test",
            .path: "/",
            .secure: true,
            .expires: Date(timeIntervalSinceNow: 3_600)
        ]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .name: "preferences",
            .value: "dark",
            .domain: "example.test",
            .path: "/"
        ]))

        XCTAssertTrue(APIClient.hasUsableAuthenticationCookie([validAVS], now: .now))
        XCTAssertFalse(APIClient.hasUsableAuthenticationCookie([unrelated], now: .now))
        XCTAssertEqual(
            APIClient.startupAuthenticationAction(
                hasSavedCredentials: true,
                hasRestoredProfile: true,
                hasUsableAuthenticationCookie: true
            ),
            .refreshSavedCredentials
        )
        XCTAssertEqual(
            APIClient.startupAuthenticationAction(
                hasSavedCredentials: false,
                hasRestoredProfile: true,
                hasUsableAuthenticationCookie: true
            ),
            .validateRestoredSession
        )
        XCTAssertEqual(
            APIClient.startupAuthenticationAction(
                hasSavedCredentials: false,
                hasRestoredProfile: true,
                hasUsableAuthenticationCookie: false
            ),
            .invalidateRestoredSession
        )
        XCTAssertEqual(
            APIClient.startupAuthenticationAction(
                hasSavedCredentials: false,
                hasRestoredProfile: false,
                hasUsableAuthenticationCookie: false
            ),
            .none
        )
        XCTAssertTrue(APIClient.isExplicitAuthenticationFailure(APIError.http(401)))
        XCTAssertTrue(APIClient.isExplicitAuthenticationFailure(APIError.http(403)))
        XCTAssertTrue(APIClient.isExplicitAuthenticationFailure(APIError.server("会话失效，请先登录")))
        XCTAssertTrue(APIClient.isExplicitAuthenticationFailure(APIError.server("session expired")))
        XCTAssertTrue(APIClient.isExplicitAuthenticationFailure(APIError.server("登录失败，请检查账号或密码")))
        XCTAssertFalse(APIClient.isExplicitAuthenticationFailure(APIError.http(500)))
        XCTAssertFalse(APIClient.isExplicitAuthenticationFailure(URLError(.timedOut)))
        XCTAssertFalse(APIClient.isExplicitAuthenticationFailure(APIError.invalidResponse))
    }

    func testUserProfileAvatarExperienceAndLegacyCodableCompatibility() throws {
        let current = UserProfile(json: [
            "uid": "42",
            "username": "reader",
            "level_name": "资深读者",
            "level": "4",
            "coin": 8,
            "album_favorites": 20,
            "album_favorites_max": 100,
            "photo": "avatar.png",
            "exp": "1370",
            "nextLevelExp": 2000
        ])
        XCTAssertEqual(current.avatarPath, "/media/users/avatar.png")
        XCTAssertEqual(current.experience, 1370)
        XCTAssertEqual(current.nextLevelExperience, 2000)

        let uidFallback = UserProfile(json: ["uid": "99", "username": "fallback"])
        XCTAssertEqual(uidFallback.avatarPath, "/media/users/99.jpg")

        // Keychain profiles saved before photo/experience were introduced
        // contain only these original non-optional Codable fields.
        let legacy = try JSONSerialization.data(withJSONObject: [
            "id": "legacy-id",
            "username": "legacy-user",
            "levelName": "",
            "level": 2,
            "coin": 0,
            "favoriteCount": 7,
            "favoriteLimit": 50
        ])
        let restored = try JSONDecoder().decode(UserProfile.self, from: legacy)
        XCTAssertNil(restored.photo)
        XCTAssertNil(restored.experience)
        XCTAssertNil(restored.nextLevelExperience)
        XCTAssertEqual(restored.avatarPath, "/media/users/legacy-id.jpg")
    }

    func testOptionalExplanationsAndAutomaticCheckInDefaultOff() throws {
        let suiteName = "JMComicTests.InterfacePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(defaults.bool(forKey: InterfacePreferences.showExplanatoryTextKey))
        XCTAssertFalse(defaults.bool(forKey: DailyCheckInPreferences.automaticCheckInKey))

        defaults.set(true, forKey: InterfacePreferences.showExplanatoryTextKey)
        defaults.set(true, forKey: DailyCheckInPreferences.automaticCheckInKey)
        XCTAssertTrue(defaults.bool(forKey: InterfacePreferences.showExplanatoryTextKey))
        XCTAssertTrue(defaults.bool(forKey: DailyCheckInPreferences.automaticCheckInKey))
    }

    func testMissingKeychainEntitlementUsesOpaqueProtectedFileFallbackAndDeletesBoth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = FixedStatusKeychainAccess(status: OSStatus(-34_018))
        let store = KeychainStore(
            keychain: keychain,
            fallbackDirectory: directory,
            service: "JMComicTests.secure-state"
        )
        let accountsAndValues: [(String, Data)] = [
            ("session.cookies", Data([0x00, 0x01, 0xFE, 0xFF])),
            ("session.profile", Data("profile-binary".utf8)),
            ("session.credentials", Data("credential-binary".utf8))
        ]

        for (account, value) in accountsAndValues {
            XCTAssertEqual(try store.save(value, account: account), .protectedFile)
            XCTAssertEqual(store.load(account: account), value)
        }

        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(storedFiles.count, accountsAndValues.count)
        XCTAssertTrue(storedFiles.allSatisfy { $0.pathExtension == "bin" })
        for file in storedFiles {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            // The simulator accepts Data Protection attributes but does not expose
            // them again through attributesOfItem; a real device does.
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
            }
        }
        for (account, _) in accountsAndValues {
            XCTAssertFalse(storedFiles.contains { $0.lastPathComponent.contains(account) })
        }
        XCTAssertTrue(storedFiles.allSatisfy { !$0.lastPathComponent.contains("session") })

        for (account, _) in accountsAndValues {
            store.delete(account: account)
            XCTAssertNil(store.load(account: account))
        }
        XCTAssertEqual(keychain.deleteCallCount, accountsAndValues.count)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @MainActor
    func testMissingEntitlementFallbackSupportsColdStartCredentialRestore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstLaunchStore = KeychainStore(
            keychain: FixedStatusKeychainAccess(status: OSStatus(-34_018)),
            fallbackDirectory: directory,
            service: "JMComicTests.cold-start"
        )
        XCTAssertTrue(APIClient.persistLoginCredentials(
            username: "test-user",
            password: "test-password",
            store: firstLaunchStore
        ))

        // A new store and APIClient model a terminated/relaunched app. The mock
        // keychain remains unavailable, so credentials must be restored from disk.
        let relaunchedStore = KeychainStore(
            keychain: FixedStatusKeychainAccess(status: OSStatus(-34_018)),
            fallbackDirectory: directory,
            service: "JMComicTests.cold-start"
        )
        let client = APIClient(secureStore: relaunchedStore)
        XCTAssertTrue(client.hasSavedCredentials)
    }

    func testResignedBuildReadsFallbackOnItemNotFoundThenKeychainSaveRemovesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = "session.credentials"
        let fallbackData = Data("fallback credential".utf8)

        let unsignedStore = KeychainStore(
            keychain: FixedStatusKeychainAccess(status: OSStatus(-34_018)),
            fallbackDirectory: directory,
            service: "JMComicTests.resign-migration"
        )
        XCTAssertEqual(try unsignedStore.save(fallbackData, account: account), .protectedFile)

        let newlyEntitledKeychain = MutableKeychainAccess()
        let resignedStore = KeychainStore(
            keychain: newlyEntitledKeychain,
            fallbackDirectory: directory,
            service: "JMComicTests.resign-migration"
        )
        XCTAssertEqual(resignedStore.load(account: account), fallbackData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)

        let migratedData = Data("keychain credential".utf8)
        XCTAssertEqual(try resignedStore.save(migratedData, account: account), .keychain)
        XCTAssertEqual(resignedStore.load(account: account), migratedData)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @MainActor
    func testNonAvailabilityKeychainFailureDoesNotEscapeSuccessfulLoginPersistenceStep() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeychainStore(
            keychain: FixedStatusKeychainAccess(status: errSecAuthFailed),
            fallbackDirectory: directory,
            service: "JMComicTests.no-unsafe-fallback"
        )

        XCTAssertFalse(APIClient.persistLoginCredentials(
            username: "authenticated-user",
            password: "accepted-password",
            store: store
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(KeychainStore.isKeychainUnavailable(errSecAuthFailed))
        XCTAssertTrue(KeychainStore.isKeychainUnavailable(OSStatus(-34_018)))
    }

    func testReaderEdgeDismissRequiresVisibleControlsAndLeftEdgeStart() {
        let decisiveSwipe = CGSize(width: 120, height: 12)
        let projectedSwipe = CGSize(width: 160, height: 14)

        XCTAssertTrue(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: true,
            startX: 12,
            translation: decisiveSwipe,
            predictedEndTranslation: projectedSwipe
        ))
        XCTAssertFalse(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: false,
            startX: 12,
            translation: decisiveSwipe,
            predictedEndTranslation: projectedSwipe
        ))
        XCTAssertFalse(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: true,
            startX: ReaderInteractionPolicy.edgeActivationWidth + 1,
            translation: decisiveSwipe,
            predictedEndTranslation: projectedSwipe
        ))
    }

    func testReaderEdgeDismissRejectsVerticalLeftwardAndShortDrags() {
        XCTAssertFalse(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: true,
            startX: 8,
            translation: CGSize(width: 70, height: 90),
            predictedEndTranslation: CGSize(width: 180, height: 120)
        ))
        XCTAssertFalse(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: true,
            startX: 8,
            translation: CGSize(width: -120, height: 4),
            predictedEndTranslation: CGSize(width: -180, height: 5)
        ))
        XCTAssertFalse(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: true,
            startX: 8,
            translation: CGSize(width: 45, height: 3),
            predictedEndTranslation: CGSize(width: 80, height: 4)
        ))
        XCTAssertTrue(ReaderInteractionPolicy.shouldDismissFromLeftEdge(
            controlsVisible: true,
            startX: 8,
            translation: CGSize(width: 50, height: 3),
            predictedEndTranslation: CGSize(width: 130, height: 4)
        ))
    }

    func testReaderZoomScaleIsBounded() {
        XCTAssertEqual(ReaderInteractionPolicy.clampedZoomScale(0.2), 1)
        XCTAssertEqual(ReaderInteractionPolicy.clampedZoomScale(2.5), 2.5)
        XCTAssertEqual(
            ReaderInteractionPolicy.clampedZoomScale(20),
            ReaderInteractionPolicy.maximumZoomScale
        )
        XCTAssertEqual(
            ReaderInteractionPolicy.continuousContentWidth(viewportWidth: 430, scale: 3),
            1_290
        )
        XCTAssertEqual(
            ReaderInteractionPolicy.continuousContentWidth(viewportWidth: 2_048, scale: 2),
            2_400
        )
    }

    func testContinuousReaderHasNoHorizontalAxisAtNaturalScale() {
        XCTAssertFalse(
            ReaderInteractionPolicy.continuousHorizontalScrollingEnabled(scale: 1)
        )
        XCTAssertFalse(
            ReaderInteractionPolicy.continuousHorizontalScrollingEnabled(
                scale: ReaderInteractionPolicy.continuousHorizontalActivationScale
            )
        )
        XCTAssertTrue(
            ReaderInteractionPolicy.continuousHorizontalScrollingEnabled(scale: 1.02)
        )
        XCTAssertTrue(
            ReaderInteractionPolicy.continuousHorizontalScrollingEnabled(scale: 3)
        )
    }
}

private actor LimiterPeakRecorder {
    private var activeComics = 0
    private var pagesForOneComic = 0

    func observe(_ snapshot: (activeComics: Int, maximumPagesForOneComic: Int)) {
        activeComics = max(activeComics, snapshot.activeComics)
        pagesForOneComic = max(pagesForOneComic, snapshot.maximumPagesForOneComic)
    }

    func peak() -> (activeComics: Int, pagesForOneComic: Int) {
        (activeComics, pagesForOneComic)
    }
}

private final class FixedStatusKeychainAccess: KeychainAccessing {
    let status: OSStatus
    private(set) var deleteCallCount = 0

    init(status: OSStatus) {
        self.status = status
    }

    func save(_ data: Data, service: String, account: String) -> OSStatus {
        status
    }

    func load(service: String, account: String) -> (status: OSStatus, data: Data?) {
        (status, nil)
    }

    func delete(service: String, account: String) -> OSStatus {
        deleteCallCount += 1
        return status
    }
}

private final class MutableKeychainAccess: KeychainAccessing {
    private var values: [String: Data] = [:]

    func save(_ data: Data, service: String, account: String) -> OSStatus {
        values["\(service):\(account)"] = data
        return errSecSuccess
    }

    func load(service: String, account: String) -> (status: OSStatus, data: Data?) {
        guard let data = values["\(service):\(account)"] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data)
    }

    func delete(service: String, account: String) -> OSStatus {
        values.removeValue(forKey: "\(service):\(account)")
        return errSecSuccess
    }
}

/// Synthetic page responses only; never reads a user's account or CDN content.
private final class PageFixtureSecureStore: SecureDataStoring {
    func save(_ data: Data, account: String) throws -> KeychainStore.StorageLocation { .protectedFile }
    func load(account: String) -> Data? { nil }
    func delete(account: String) {}
}

private final class PageFixtureURLProtocol: URLProtocol {
    static var handle: ((PageFixtureURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle?(self) }
    override func stopLoading() {}
    func respond(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
