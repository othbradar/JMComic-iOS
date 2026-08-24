import Foundation
import UIKit

private typealias JMField = JMServiceProtocol.Field

struct ChapterTemplateMetadata: Equatable {
    let scrambleID: Int
    let imageDomain: String?

    static func parse(
        _ html: String,
        fallbackScrambleID: Int = JMServiceProtocol.ChapterTemplate.fallbackScrambleID
    ) -> Self {
        let scramble = firstCapture(
            pattern: JMServiceProtocol.ChapterTemplate.scramblePattern,
            in: html
        ).flatMap(Int.init) ?? fallbackScrambleID
        let rawDomain = firstCapture(
            pattern: JMServiceProtocol.ChapterTemplate.imageDomainPattern,
            in: html
        )?.replacingOccurrences(of: #"\/"#, with: "/")
        let domain = rawDomain.map(AppConfiguration.normalize).flatMap { value in
            URL(string: value)?.host == nil ? nil : value
        }
        return Self(scrambleID: scramble, imageDomain: domain)
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum StartupAuthenticationAction: Equatable {
    case refreshSavedCredentials
    case validateRestoredSession
    case invalidateRestoredSession
    case none
}

@MainActor
final class APIClient: ObservableObject {
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isBootstrapping = false
    @Published private(set) var hasSavedCredentials = false
    @Published private(set) var lastError: String?
    @Published private(set) var dailyCheckInStatus: DailyStatus?
    @Published private(set) var isLoadingDailyCheckIn = false
    @Published private(set) var isSigningDailyCheckIn = false
    @Published private(set) var dailyCheckInError: String?
    @Published var configuration: AppConfiguration {
        didSet { configuration.save() }
    }

    private let session: URLSession
    private let secureStore: any SecureDataStoring
    private let cookieAccount = "session.cookies"
    private let profileAccount = "session.profile"
    private let credentialsAccount = "session.credentials"
    private var bootstrapTask: Task<Void, Never>?
    private var hasCompletedBootstrap = false
    private var authenticationGeneration = 0
    private var dailyStatusUserID: String?
    private var dailyStatusAttemptedUserID: String?
    private var dailyStatusTask: Task<DailyStatus, Error>?
    private var dailyStatusOperationID: UUID?
    private var dailyStatusTaskUserID: String?
    private var dailyStatusTaskAuthenticationGeneration: Int?
    private var dailySignTask: Task<String, Error>?
    private var dailySignOperationID: UUID?
    private var dailySignTaskUserID: String?
    private var dailySignTaskAuthenticationGeneration: Int?
    private var restoredSessionCookies: [HTTPCookie] = []
    private var preferredImageDomain: String?
    private let imageRequestGate = AsyncPermitPool(limit: 4)
    private let remoteImageCache = NSCache<NSString, UIImage>()
    private let decodedPageCache = NSCache<NSString, UIImage>()
    private var remoteImageLoads: [String: SharedImageLoad] = [:]
    private var decodedPageLoads: [String: SharedImageLoad] = [:]

    var isLoggedIn: Bool { profile != nil }
    var needsCredentialLogin: Bool { isLoggedIn && !hasSavedCredentials }

    init(secureStore: any SecureDataStoring = KeychainStore.shared) {
        self.secureStore = secureStore
        configuration = .load()
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.httpCookieStorage = .shared
        sessionConfiguration.requestCachePolicy = .reloadRevalidatingCacheData
        sessionConfiguration.httpMaximumConnectionsPerHost = DownloadConcurrencyPreferences.allowedRange.upperBound
        session = URLSession(configuration: sessionConfiguration)
        remoteImageCache.countLimit = 180
        remoteImageCache.totalCostLimit = 96 * 1_024 * 1_024
        decodedPageCache.countLimit = 28
        decodedPageCache.totalCostLimit = 224 * 1_024 * 1_024
        restoreSession()
        hasSavedCredentials = savedCredentials() != nil
    }

    func bootstrap() async {
        if hasCompletedBootstrap { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        isBootstrapping = true
        let generation = authenticationGeneration
        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.performBootstrap(authenticationGeneration: generation)
        }
        bootstrapTask = task
        await task.value
        hasCompletedBootstrap = true
        bootstrapTask = nil
        isBootstrapping = false
    }

    private func performBootstrap(authenticationGeneration generation: Int) async {
        var warnings: [String] = []
        do {
            try await refreshDomains()
        } catch {
            warnings.append("域名自动更新失败，已继续使用内置线路：\(error.localizedDescription)")
        }

        // Domain discovery may replace yesterday's working host. Move the
        // restored AVS onto every current API host before the first validation
        // request, even when /setting itself is temporarily unavailable. This
        // prevents a valid session from looking unauthenticated merely because
        // the cookie is still scoped to an old domain.
        cloneSessionCookiesAcrossDomains()
        persistCookies()
        do {
            _ = try await requestDecoded(
                JMServiceProtocol.Request.setting,
                bypassBootstrap: true
            )
            cloneSessionCookiesAcrossDomains()
            persistCookies()
        } catch {
            warnings.append("会话初始化失败：\(error.localizedDescription)")
        }

        guard generation == authenticationGeneration, !Task.isCancelled else { return }
        let credentials = savedCredentials()
        let restoredProfile = profile
        let action = Self.startupAuthenticationAction(
            hasSavedCredentials: credentials != nil,
            hasRestoredProfile: restoredProfile?.id.isEmpty == false,
            hasUsableAuthenticationCookie: Self.hasUsableAuthenticationCookie(
                HTTPCookieStorage.shared.cookies ?? [],
                now: .now
            )
        )

        switch action {
        case .refreshSavedCredentials:
            guard let credentials else { return }
            do {
                // A daily/status request can still succeed shortly before an
                // AVS stops being accepted by the favorites API. Refresh the
                // login exactly once in this process's single-flight bootstrap
                // so all later business requests start with a new credential.
                let user = try await authenticate(
                    username: credentials.username,
                    password: credentials.password,
                    bypassBootstrap: true,
                    authenticationGeneration: generation
                )
                do {
                    _ = try await fetchAndStoreDailyStatus(
                        userID: user.id,
                        authenticationGeneration: generation,
                        bypassBootstrap: true,
                        force: true
                    )
                } catch is CancellationError {
                    return
                } catch {
                    warnings.append("签到状态加载失败：\(error.localizedDescription)")
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == authenticationGeneration else { return }
                // A temporary line failure must not erase the restored profile
                // or yesterday's cookie. Only a decisive authentication error
                // proves that keeping the restored session would be misleading.
                if Self.isExplicitAuthenticationFailure(error) {
                    invalidateRestoredSession()
                }
                warnings.append("启动刷新登录凭证失败：\(error.localizedDescription)")
            }
        case .validateRestoredSession:
            guard let restoredProfile else { return }
            prepareDailyState(for: restoredProfile.id)
            do {
                _ = try await fetchAndStoreDailyStatus(
                    userID: restoredProfile.id,
                    authenticationGeneration: generation,
                    bypassBootstrap: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == authenticationGeneration else { return }
                if Self.isExplicitAuthenticationFailure(error) {
                    invalidateRestoredSession()
                }
                warnings.append("签到状态加载失败：\(error.localizedDescription)")
            }
        case .invalidateRestoredSession:
            invalidateRestoredSession()
        case .none:
            break
        }
        lastError = warnings.last
    }

    func refreshDomains() async throws {
        let previouslyWorkingAPI = configuration.apiDomains.first
        let previouslyWorkingImage = preferredImageDomain ?? configuration.imageDomains.first
        let configURLs = JMServiceAddresses.lineConfigurationMirrorURLs

        // 线路发现不得使用 URLSession.shared 的默认长超时，否则冷启动重登会把
        // 整个 App 门控几分钟。上游密文与三个 config 镜像并行，config 取首个有效响应。
        let discoveryConfiguration = URLSessionConfiguration.ephemeral
        discoveryConfiguration.timeoutIntervalForRequest = 3
        discoveryConfiguration.timeoutIntervalForResource = 4
        discoveryConfiguration.waitsForConnectivity = false
        discoveryConfiguration.httpMaximumConnectionsPerHost = 3
        let discoverySession = URLSession(configuration: discoveryConfiguration)
        defer { discoverySession.finishTasksAndInvalidate() }

        async let upstreamData = Self.discoveryData(
            from: JMServiceAddresses.encryptedUpstreamURL,
            session: discoverySession
        )
        async let lineData = Self.firstValidLineConfigurationData(
            from: configURLs,
            session: discoverySession
        )
        let (upstreamResult, lineResult) = await (upstreamData, lineData)

        var updated = false
        var upstreamAPIDomains: [String] = []
        if let upstreamResult,
           let decrypted = try? decryptRawCipher(
               upstreamResult,
               secret: JMServiceProtocol.Signing.domainServerSecret
           ),
           let root = try? JSONSerialization.jsonObject(with: decrypted) as? JSONDictionary {
            let serverValue = JMServiceProtocol.DiscoveryKey.encryptedServerCandidates
                .lazy
                .compactMap { root[$0] }
                .first
            upstreamAPIDomains = extractDomains(serverValue)
        }

        var lineAPIDomains: [String] = []
        if let lineResult, let text = String(data: lineResult, encoding: .utf8) {
            let values = parseLineConfiguration(text)
            lineAPIDomains = values[JMServiceProtocol.DiscoveryKey.apiDomains]?.split(separator: ",").map {
                AppConfiguration.normalize(String($0))
            } ?? []
            let images = values[JMServiceProtocol.DiscoveryKey.imageDomains]?.split(separator: ",").map {
                AppConfiguration.normalize(String($0))
            } ?? []
            if !images.isEmpty {
                var discoveredImages = Self.uniqueDomains(images)
                if let previouslyWorkingImage,
                   let index = discoveredImages.firstIndex(of: previouslyWorkingImage), index > 0 {
                    discoveredImages.remove(at: index)
                    discoveredImages.insert(previouslyWorkingImage, at: 0)
                }
                configuration.imageDomains = discoveredImages
                preferredImageDomain = configuration.imageDomains.first
            }
            if let version = values[JMServiceProtocol.DiscoveryKey.clientVersion], !version.isEmpty {
                configuration.appVersion = version
            }
            updated = true
        }
        let apiDomains = upstreamAPIDomains.isEmpty ? lineAPIDomains : upstreamAPIDomains
        if !apiDomains.isEmpty {
            var discoveredAPI = Self.uniqueDomains(apiDomains)
            if let previouslyWorkingAPI,
               let index = discoveredAPI.firstIndex(of: previouslyWorkingAPI), index > 0 {
                discoveredAPI.remove(at: index)
                discoveredAPI.insert(previouslyWorkingAPI, at: 0)
            }
            configuration.apiDomains = discoveredAPI
            updated = true
        }
        guard updated else { throw APIError.invalidResponse }
        cloneSessionCookiesAcrossDomains()
        persistCookies()
    }

    func home(page: Int = 0) async throws -> [HomeSection] {
        let value = try await requestDecoded(JMServiceProtocol.Request.promote(page: page))
        return (value as? [JSONDictionary] ?? []).map(HomeSection.init)
    }

    func latest(page: Int = 0) async throws -> [ComicSummary] {
        let value = try await requestDecoded(JMServiceProtocol.Request.latest(page: page))
        if let list = value as? [JSONDictionary] { return list.map { ComicSummary(json: $0) } }
        if let dict = value as? JSONDictionary {
            return (
                dict[JMServiceResponseSchema.Home.content] as? [JSONDictionary]
                    ?? dict[JMServiceResponseSchema.Favorite.list] as? [JSONDictionary]
                    ?? []
            ).map {
                ComicSummary(json: $0)
            }
        }
        return []
    }

    func search(
        _ query: String,
        page: Int = 1,
        order: String = JMServiceProtocol.Value.defaultOrder
    ) async throws -> (Int, [ComicSummary]) {
        let value = try await requestDecoded(
            JMServiceProtocol.Request.search(query: query, page: page, order: order)
        )
        guard let dict = value as? JSONDictionary else { throw APIError.invalidResponse }
        return (
            dict.int(JMServiceResponseSchema.Favorite.total),
            dict.dictionaries(JMServiceResponseSchema.Home.content).map { ComicSummary(json: $0) }
        )
    }

    func comic(id: String) async throws -> ComicDetail {
        let value = try await requestDecoded(JMServiceProtocol.Request.album(id: id))
        guard let dict = value as? JSONDictionary else { throw APIError.invalidResponse }
        return ComicDetail(json: dict)
    }

    func chapter(id: String) async throws -> ChapterDetail {
        async let chapterValue = requestDecoded(JMServiceProtocol.Request.chapter(id: id))
        async let templateValue = chapterTemplateMetadata(chapterID: id)
        guard let dict = try await chapterValue as? JSONDictionary else { throw APIError.invalidResponse }
        let metadata = try await templateValue
        if let imageDomain = metadata.imageDomain {
            // `app_img_shunt` selects a server-side route.  The returned
            // `imghost` is the host that actually implements that route, so it
            // must feed the reader/download fallback list instead of being a
            // cosmetic setting only.
            recordSuccessfulImageDomain(imageDomain)
        }
        return ChapterDetail(json: dict, scrambleID: metadata.scrambleID)
    }

    func login(username: String, password: String) async throws -> UserProfile {
        await bootstrap()
        cancelDailyStatusOperation()
        cancelDailyCheckInOperation()
        authenticationGeneration &+= 1
        let generation = authenticationGeneration
        let user = try await authenticate(
            username: username,
            password: password,
            bypassBootstrap: true,
            authenticationGeneration: generation
        )
        hasSavedCredentials = Self.persistLoginCredentials(
            username: username,
            password: password,
            store: secureStore,
            account: credentialsAccount
        )
        if !hasSavedCredentials {
            // Authentication has already succeeded and `profile` is live. A local
            // persistence failure must never be reported to LoginView as a failed login.
            lastError = "已登录，但本机无法保存自动重登凭证"
        }
        return user
    }

    /// Non-throwing by design: this runs only after the server has accepted the
    /// credentials. It is internal so tests can inject a failing secure store and
    /// prove that local storage errors are reduced to a persistence result.
    static func persistLoginCredentials(
        username: String,
        password: String,
        store: any SecureDataStoring,
        account: String = "session.credentials"
    ) -> Bool {
        do {
            let credentials = LoginCredentials(username: username, password: password)
            let data = try JSONEncoder().encode(credentials)
            _ = try store.save(data, account: account)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func refreshSavedLogin() async throws -> UserProfile {
        guard let credentials = savedCredentials() else {
            throw APIError.server("没有可用的已保存凭证，请先退出并重新登录一次")
        }
        await bootstrap()
        cancelDailyStatusOperation()
        cancelDailyCheckInOperation()
        authenticationGeneration &+= 1
        let generation = authenticationGeneration
        let user = try await authenticate(
            username: credentials.username,
            password: credentials.password,
            bypassBootstrap: true,
            authenticationGeneration: generation
        )
        await refreshDailyCheckInStatus(force: true)
        return user
    }

    private func authenticate(
        username: String,
        password: String,
        bypassBootstrap: Bool,
        authenticationGeneration generation: Int
    ) async throws -> UserProfile {
        let value = try await requestDecoded(
            JMServiceProtocol.Request.login(username: username, password: password),
            bypassBootstrap: bypassBootstrap
        )
        guard let dict = value as? JSONDictionary else { throw APIError.invalidResponse }
        let user = UserProfile(json: dict)
        guard !user.id.isEmpty else { throw APIError.server("登录失败，请检查账号和密码") }
        guard generation == authenticationGeneration, !Task.isCancelled else {
            // URLSession 可能已在响应抵达时接收 Set-Cookie；退出后的旧响应不得复活会话。
            if profile == nil { clearSessionCookiesAndProfile() }
            throw CancellationError()
        }
        if let avs = dict[JMServiceProtocol.ResponseField.authenticationCookieValue] as? String {
            for domain in configuration.apiDomains.compactMap({ URL(string: $0)?.host }) {
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .name: JMServiceProtocol.authenticationCookieName,
                    .value: avs,
                    .domain: domain,
                    .path: JMServiceProtocol.authenticationCookiePath,
                    .secure: true
                ]
                if let cookie = HTTPCookie(properties: properties) { HTTPCookieStorage.shared.setCookie(cookie) }
            }
        }
        cloneSessionCookiesAcrossDomains()
        if profile?.id != user.id {
            resetDailyCheckInState(for: user.id)
        } else {
            prepareDailyState(for: user.id)
        }
        profile = user
        persistCookies()
        if let data = try? JSONEncoder().encode(user) {
            _ = try? secureStore.save(data, account: profileAccount)
        }
        return user
    }

    func logout() {
        cancelDailyStatusOperation()
        cancelDailyCheckInOperation()
        authenticationGeneration &+= 1
        bootstrapTask?.cancel()
        profile = nil
        clearSessionCookiesAndProfile()
        secureStore.delete(account: credentialsAccount)
        hasSavedCredentials = false
        resetDailyCheckInState(for: nil)
    }

    func favorites(
        folderID: String = JMServiceProtocol.Value.allFavoritesFolder,
        page: Int = 1,
        order: String = JMServiceProtocol.Value.defaultOrder
    ) async throws -> FavoritePage {
        let value = try await requestDecoded(
            JMServiceProtocol.Request.favorites(folderID: folderID, page: page, order: order)
        )
        guard let dict = value as? JSONDictionary else { throw APIError.invalidResponse }
        return FavoritePage(json: dict)
    }

    /// Explicit UI refresh. The account page reads the published snapshot and
    /// never calls this from `onAppear`, so switching tabs cannot create traffic.
    func refreshDailyCheckInStatus(force: Bool = true) async {
        await bootstrap()
        guard let userID = profile?.id, !userID.isEmpty else {
            resetDailyCheckInState(for: nil)
            return
        }
        let generation = authenticationGeneration
        do {
            _ = try await fetchAndStoreDailyStatus(
                userID: userID,
                authenticationGeneration: generation,
                bypassBootstrap: true,
                force: force
            )
        } catch is CancellationError {
            return
        } catch {
            // `fetchAndStoreDailyStatus` publishes only if this is still the
            // same account generation, preventing a late response after logout.
        }
    }

    @discardableResult
    func signCurrentDaily() async throws -> String {
        guard let userID = profile?.id, !userID.isEmpty else {
            throw APIError.server("签到信息不完整")
        }
        let callerGeneration = authenticationGeneration
        if let dailySignTask,
           dailySignTaskUserID == userID,
           dailySignTaskAuthenticationGeneration == callerGeneration {
            return try await dailySignTask.value
        }
        if let dailyStatusTask,
           dailyStatusTaskUserID == userID,
           dailyStatusTaskAuthenticationGeneration == callerGeneration {
            // A status GET that started before this mutation must finish first;
            // otherwise the post-check could accidentally reuse stale data.
            _ = try await dailyStatusTask.value
        }
        guard callerGeneration == authenticationGeneration,
              profile?.id == userID else { throw CancellationError() }
        if let dailySignTask,
           dailySignTaskUserID == userID,
           dailySignTaskAuthenticationGeneration == callerGeneration {
            return try await dailySignTask.value
        }
        if DailyCheckInSubmissionPolicy.needsFreshStatus(
            userID: userID,
            statusUserID: dailyStatusUserID,
            status: dailyCheckInStatus
        ) {
            await refreshDailyCheckInStatus(force: true)
        }
        guard callerGeneration == authenticationGeneration,
              profile?.id == userID else { throw CancellationError() }
        // Two stale-month callers can share the refresh above. Re-check after
        // that suspension so only the first resumed caller creates the POST.
        if let dailySignTask,
           dailySignTaskUserID == userID,
           dailySignTaskAuthenticationGeneration == callerGeneration {
            return try await dailySignTask.value
        }
        guard dailyStatusUserID == userID,
              let status = dailyCheckInStatus,
              status.isCurrentMonth,
              !status.isSignedToday,
              status.dailyID > 0 else {
            throw APIError.server("签到信息不完整")
        }
        let generation = callerGeneration
        let operationID = UUID()
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let message: String
            do {
                message = try await self.statusMessage(
                    JMServiceProtocol.Request.dailyCheckIn(
                        userID: userID,
                        dailyID: status.dailyID
                    )
                )
            } catch {
                if generation == self.authenticationGeneration,
                   self.profile?.id == userID,
                   !Self.isCancellation(error) {
                    self.dailyCheckInError = error.localizedDescription
                }
                throw error
            }
            guard generation == self.authenticationGeneration,
                  self.profile?.id == userID,
                  !Task.isCancelled else { throw CancellationError() }
            self.dailyCheckInError = nil
            if self.dailyStatusUserID == userID,
               let currentStatus = self.dailyCheckInStatus {
                // The POST has already succeeded. Mark today immediately so a
                // failed verification GET cannot re-enable a duplicate submit.
                self.dailyCheckInStatus = currentStatus.markingSigned()
            }
            // Any GET that somehow began while the POST was in flight predates
            // the mutation. Cancel it so the verification below is guaranteed
            // to start after the successful submission.
            self.cancelDailyStatusOperation()
            // A successful mutation is one of the few non-manual reasons to
            // reload: both account and detail pages share the updated calendar.
            await self.refreshDailyCheckInStatus(force: true)
            guard generation == self.authenticationGeneration,
                  self.profile?.id == userID,
                  !Task.isCancelled else { throw CancellationError() }
            return message
        }
        dailySignTask = task
        dailySignOperationID = operationID
        dailySignTaskUserID = userID
        dailySignTaskAuthenticationGeneration = generation
        isSigningDailyCheckIn = true
        do {
            let message = try await task.value
            finishDailyCheckInOperation(operationID)
            return message
        } catch {
            finishDailyCheckInOperation(operationID)
            throw error
        }
    }

    /// Runs once after cold-start bootstrap (and once after a newly authenticated
    /// account). It reuses the shared startup snapshot instead of issuing another
    /// GET /daily when the account page appears.
    func autoSignIfEnabled(defaults: UserDefaults = .standard) async {
        guard defaults.bool(forKey: DailyCheckInPreferences.automaticCheckInKey) else {
            dailyCheckInError = nil
            return
        }
        guard let userID = profile?.id, !userID.isEmpty else { return }
        if DailyStatusRefreshPolicy.shouldLoad(
            userID: userID,
            attemptedUserID: dailyStatusAttemptedUserID,
            force: false
        ) {
            await refreshDailyCheckInStatus(force: false)
        }
        guard dailyStatusUserID == userID,
              let status = dailyCheckInStatus,
              !status.isSignedToday else { return }
        guard status.dailyID > 0 else {
            dailyCheckInError = "签到信息不完整"
            return
        }
        do {
            _ = try await signCurrentDaily()
        } catch is CancellationError {
            return
        } catch {
            guard profile?.id == userID else { return }
            dailyCheckInError = error.localizedDescription
        }
    }

    /// Used after manual login without delaying dismissal of the login screen.
    /// It establishes the first snapshot for that newly selected account, then
    /// applies the optional automatic check-in against the same snapshot.
    func prepareDailyCheckInAfterLogin() async {
        await refreshDailyCheckInStatus(force: true)
        await autoSignIfEnabled()
    }

    private func fetchAndStoreDailyStatus(
        userID: String,
        authenticationGeneration generation: Int,
        bypassBootstrap: Bool,
        force: Bool = false
    ) async throws -> DailyStatus {
        guard !userID.isEmpty else { throw APIError.server("用户信息不完整") }
        prepareDailyState(for: userID)

        if let dailyStatusTask,
           dailyStatusTaskUserID == userID,
           dailyStatusTaskAuthenticationGeneration == generation {
            return try await dailyStatusTask.value
        }

        guard DailyStatusRefreshPolicy.shouldLoad(
            userID: userID,
            attemptedUserID: dailyStatusAttemptedUserID,
            force: force
        ) else {
            guard let dailyCheckInStatus else { throw APIError.invalidResponse }
            return dailyCheckInStatus
        }

        cancelDailyStatusOperation()
        dailyStatusAttemptedUserID = userID
        isLoadingDailyCheckIn = true
        let operationID = UUID()
        let task = Task { @MainActor [weak self] () throws -> DailyStatus in
            guard let self else { throw CancellationError() }
            do {
                let value = try await self.requestDecoded(
                    JMServiceProtocol.Request.daily(userID: userID),
                    bypassBootstrap: bypassBootstrap
                )
                guard let dict = value as? JSONDictionary else {
                    throw APIError.invalidResponse
                }
                let status = DailyStatus(json: dict)
                guard self.dailyStatusOperationID == operationID,
                      generation == self.authenticationGeneration,
                      self.profile?.id == userID,
                      !Task.isCancelled else { throw CancellationError() }
                self.dailyStatusUserID = userID
                self.dailyCheckInStatus = status
                self.dailyCheckInError = nil
                self.finishDailyStatusOperation(operationID)
                return status
            } catch {
                let ownsOperation = self.dailyStatusOperationID == operationID
                if ownsOperation {
                    if generation == self.authenticationGeneration,
                       self.profile?.id == userID,
                       !Self.isCancellation(error) {
                        self.dailyCheckInError = error.localizedDescription
                    }
                    self.finishDailyStatusOperation(operationID)
                }
                guard generation == self.authenticationGeneration,
                      self.profile?.id == userID,
                      !Task.isCancelled else { throw CancellationError() }
                throw error
            }
        }
        dailyStatusTask = task
        dailyStatusOperationID = operationID
        dailyStatusTaskUserID = userID
        dailyStatusTaskAuthenticationGeneration = generation
        return try await task.value
    }

    private func prepareDailyState(for userID: String) {
        guard dailyStatusUserID != userID else { return }
        resetDailyCheckInState(for: userID)
    }

    private func resetDailyCheckInState(for userID: String?) {
        cancelDailyStatusOperation()
        dailyStatusUserID = userID
        dailyStatusAttemptedUserID = nil
        dailyCheckInStatus = nil
        isLoadingDailyCheckIn = false
        dailyCheckInError = nil
    }

    private func finishDailyStatusOperation(_ operationID: UUID) {
        guard dailyStatusOperationID == operationID else { return }
        dailyStatusTask = nil
        dailyStatusOperationID = nil
        dailyStatusTaskUserID = nil
        dailyStatusTaskAuthenticationGeneration = nil
        isLoadingDailyCheckIn = false
    }

    private func cancelDailyStatusOperation() {
        dailyStatusTask?.cancel()
        dailyStatusTask = nil
        dailyStatusOperationID = nil
        dailyStatusTaskUserID = nil
        dailyStatusTaskAuthenticationGeneration = nil
        isLoadingDailyCheckIn = false
    }

    private func finishDailyCheckInOperation(_ operationID: UUID) {
        guard dailySignOperationID == operationID else { return }
        dailySignTask = nil
        dailySignOperationID = nil
        dailySignTaskUserID = nil
        dailySignTaskAuthenticationGeneration = nil
        isSigningDailyCheckIn = false
    }

    private func cancelDailyCheckInOperation() {
        dailySignTask?.cancel()
        dailySignTask = nil
        dailySignOperationID = nil
        dailySignTaskUserID = nil
        dailySignTaskAuthenticationGeneration = nil
        isSigningDailyCheckIn = false
    }

    private func invalidateRestoredSession() {
        cancelDailyStatusOperation()
        cancelDailyCheckInOperation()
        profile = nil
        clearSessionCookiesAndProfile()
        restoredSessionCookies = []
        resetDailyCheckInState(for: nil)
    }

    nonisolated static func hasUsableAuthenticationCookie(
        _ cookies: [HTTPCookie],
        now: Date
    ) -> Bool {
        cookies.contains { cookie in
            cookie.name.caseInsensitiveCompare(JMServiceProtocol.authenticationCookieName) == .orderedSame
                && !cookie.value.isEmpty
                && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        }
    }

    nonisolated static func startupAuthenticationAction(
        hasSavedCredentials: Bool,
        hasRestoredProfile: Bool,
        hasUsableAuthenticationCookie: Bool
    ) -> StartupAuthenticationAction {
        if hasSavedCredentials { return .refreshSavedCredentials }
        guard hasRestoredProfile else { return .none }
        return hasUsableAuthenticationCookie
            ? .validateRestoredSession
            : .invalidateRestoredSession
    }

    nonisolated static func isExplicitAuthenticationFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        if case .http(let status) = apiError {
            return status == 401 || status == 403
        }
        guard case .server(let message) = apiError else { return false }
        let normalized = message.lowercased()
        return [
            "请先登录", "请登录", "未登录", "登录失效", "登入失效",
            "登录失败", "密码错误", "账号或密码",
            "会话失效", "凭证失效", "身份认证失败", "认证失效",
            "unauthorized", "authentication failed", "authentication expired",
            "login required", "not logged in", "session expired", "invalid session",
            "invalid credential", "cookie expired"
        ].contains { normalized.contains($0) }
    }

    @discardableResult
    func toggleFavorite(comicID: String) async throws -> String {
        try await statusMessage(JMServiceProtocol.Request.toggleFavorite(comicID: comicID))
    }

    @discardableResult
    func createFavoriteFolder(name: String) async throws -> String {
        try await statusMessage(JMServiceProtocol.Request.createFavoriteFolder(name: name))
    }

    @discardableResult
    func deleteFavoriteFolder(id: String) async throws -> String {
        try await statusMessage(JMServiceProtocol.Request.deleteFavoriteFolder(id: id))
    }

    @discardableResult
    func moveFavorite(comicID: String, folderID: String) async throws -> String {
        try await statusMessage(
            JMServiceProtocol.Request.moveFavorite(comicID: comicID, folderID: folderID)
        )
    }

    func comments(comicID: String, page: Int = 1) async throws -> CommentPage {
        let value = try await requestDecoded(
            JMServiceProtocol.Request.comicComments(comicID: comicID, page: page)
        )
        guard let dict = value as? JSONDictionary else { throw APIError.invalidResponse }
        return CommentPage(json: dict)
    }

    /// Logged-in user's comment history. Upstream selects the history branch
    /// with `mode=undefined&uid=...`; no album ID is sent.
    func userComments(userID: String, page: Int = 1) async throws -> CommentPage {
        let normalizedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw APIError.server("请先登录") }
        await bootstrap()
        guard profile?.id == normalizedID else { throw APIError.server("请先登录") }
        let generation = authenticationGeneration
        let value = try await requestDecoded(
            JMServiceProtocol.Request.userComments(
                userID: normalizedID,
                page: max(1, page)
            ),
            bypassBootstrap: true
        )
        guard generation == authenticationGeneration,
              profile?.id == normalizedID,
              !Task.isCancelled else { throw CancellationError() }
        guard let dict = value as? JSONDictionary else { throw APIError.invalidResponse }
        return CommentPage(json: dict)
    }

    @discardableResult
    func sendComment(comicID: String, content: String, replyingTo commentID: String? = nil) async throws -> String {
        let form = try Self.commentSubmissionForm(
            comicID: comicID,
            content: content,
            replyingTo: commentID
        )
        let value = try await requestDecoded(
            JMServiceProtocol.Request.comment(
                comicID: form[JMField.albumID] ?? "",
                content: form[JMField.comment] ?? "",
                commentID: form[JMField.commentID]
            )
        )
        return try Self.commentSubmissionMessage(from: value)
    }

    /// Current JM mobile clients submit this multipart field even when the UI
    /// does not expose a spoiler toggle.  Omitting it can yield HTTP/API code
    /// 200 with a decrypted business failure, which older code misreported as
    /// a successful comment.
    nonisolated static func commentSubmissionForm(
        comicID: String,
        content: String,
        replyingTo commentID: String? = nil
    ) throws -> [String: String] {
        let normalizedComicID = comicID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericComicID = Int(normalizedComicID), numericComicID > 0 else {
            throw APIError.server("无效的漫画 ID")
        }
        guard !normalizedContent.isEmpty else {
            throw APIError.server("评论内容不能为空")
        }
        var form = [
            JMField.comment: normalizedContent,
            JMField.albumID: String(numericComicID),
            JMField.commentStatus: JMServiceProtocol.Value.visibleComment
        ]
        if let commentID {
            let normalizedCommentID = commentID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let numericCommentID = Int(normalizedCommentID), numericCommentID > 0 else {
                throw APIError.server("无效的回复 ID")
            }
            form[JMField.commentID] = String(numericCommentID)
        }
        return form
    }

    nonisolated static func commentSubmissionMessage(from value: Any) throws -> String {
        guard let dict = value as? JSONDictionary else {
            throw APIError.invalidResponse
        }
        let status = dict.string(JMServiceProtocol.ResponseField.status)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rawMessage = dict.string(JMServiceProtocol.ResponseField.operationMessage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == JMServiceProtocol.ResponseValue.successStatus else {
            throw APIError.server(rawMessage.isEmpty ? "评论提交失败" : rawMessage)
        }
        return rawMessage.isEmpty ? "评论已发送" : rawMessage
    }

    nonisolated static func multipartFormData(
        _ form: [String: String],
        boundary: String
    ) -> Data {
        var data = Data()
        func append(_ text: String) {
            data.append(contentsOf: text.utf8)
        }
        for (name, value) in form.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("\(JMServiceProtocol.Header.contentDisposition): "
                   + "\(JMServiceProtocol.Header.multipartDisposition(fieldName: name))\r\n")
            append("\(JMServiceProtocol.Header.contentType): "
                   + "\(JMServiceProtocol.Header.multipartTextContentType)\r\n")
            append("\(JMServiceProtocol.Header.contentTransferEncoding): "
                   + "\(JMServiceProtocol.Header.binaryTransferEncoding)\r\n\r\n")
            append(value)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return data
    }

    func imageData(path: String, preferredDomain: String? = nil) async throws -> Data {
        return try await prioritizedImageData(
            path: path,
            preferredDomain: preferredDomain,
            priority: .utility
        )
    }

    private func prioritizedImageData(
        path: String,
        preferredDomain: String?,
        priority: TaskPriority
    ) async throws -> Data {
        await bootstrap()
        try Task.checkCancellation()
        try await imageRequestGate.acquire(
            priority: priority,
            limit: DownloadConcurrencyPreferences.cachedImageRequests()
        )
        do {
            try Task.checkCancellation()
            let data = try await imageDataUsingAcquiredSlot(path: path, preferredDomain: preferredDomain)
            await imageRequestGate.release()
            return data
        } catch {
            await imageRequestGate.release()
            throw error
        }
    }

    /// 调用前必须已获取 imageRequestGate；封面后缀回退在同一 slot 内完成，避免递归死锁。
    private func imageDataUsingAcquiredSlot(path: String, preferredDomain: String?) async throws -> Data {
        try Task.checkCancellation()
        if path.hasPrefix("http"), let url = URL(string: path) {
            do {
                return try await fetchImage(url: url)
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        var domains = Self.uniqueDomains(configuration.imageDomains)
        if let preferredDomain, !preferredDomain.isEmpty {
            let normalized = AppConfiguration.normalize(preferredDomain)
            domains.removeAll { $0 == normalized }
            domains.insert(normalized, at: 0)
        } else if let preferredImageDomain {
            domains.removeAll { $0 == preferredImageDomain }
            domains.insert(preferredImageDomain, at: 0)
        }

        if let result = await firstImageData(path: path, domains: domains) {
            recordSuccessfulImageDomain(result.domain)
            return result.data
        }
        try Task.checkCancellation()
        if let fallbackPath = JMServiceProtocol.MediaPath.fallbackAlbumCoverPath(for: path) {
            return try await imageDataUsingAcquiredSlot(
                path: fallbackPath,
                preferredDomain: preferredDomain
            )
        }
        throw APIError.noAvailableDomain
    }

    /// 通用封面/头像加载：共享内存缓存与进行中请求，避免 SwiftUI 重建视图时重复下载。
    func displayImage(path: String) async throws -> UIImage {
        try Task.checkCancellation()
        let key = path as NSString
        if let cached = remoteImageCache.object(forKey: key) { return cached }
        if let load = remoteImageLoads[path] {
            return try await load.task.value
        }

        let loadID = UUID()
        let task = Task { @MainActor [weak self] () throws -> UIImage in
            guard let self else { throw CancellationError() }
            return try await self.performRemoteImageLoad(path: path, loadID: loadID)
        }
        remoteImageLoads[path] = SharedImageLoad(id: loadID, task: task)
        return try await task.value
    }

    /// 阅读页加载：解扰与像素解码在后台执行，并跨 SwiftUI 页面生命周期合并请求。
    func decodedPageImage(chapter: ChapterDetail, index: Int) async throws -> UIImage {
        guard chapter.images.indices.contains(index) else { throw APIError.invalidResponse }
        try Task.checkCancellation()
        let filename = chapter.images[index]
        let cacheKey = "\(chapter.id)|\(chapter.scrambleID)|\(filename)"
        if let cached = decodedPageCache.object(forKey: cacheKey as NSString) { return cached }
        if let load = decodedPageLoads[cacheKey] {
            return try await load.task.value
        }

        let loadID = UUID()
        let task = Task { @MainActor [weak self] () throws -> UIImage in
            guard let self else { throw CancellationError() }
            return try await self.performDecodedPageLoad(
                chapter: chapter,
                index: index,
                cacheKey: cacheKey,
                loadID: loadID
            )
        }
        decodedPageLoads[cacheKey] = SharedImageLoad(id: loadID, task: task)
        return try await task.value
    }

    func prefetchDecodedPages(chapter: ChapterDetail, after index: Int, count: Int = 2) {
        guard count > 0 else { return }
        let upperBound = min(chapter.images.count, index + count + 1)
        guard index + 1 < upperBound else { return }
        for candidate in (index + 1)..<upperBound {
            let filename = chapter.images[candidate]
            let cacheKey = "\(chapter.id)|\(chapter.scrambleID)|\(filename)"
            guard decodedPageCache.object(forKey: cacheKey as NSString) == nil,
                  decodedPageLoads[cacheKey] == nil else { continue }
            Task { @MainActor [weak self] in
                _ = try? await self?.decodedPageImage(chapter: chapter, index: candidate)
            }
        }
    }

    private func performRemoteImageLoad(path: String, loadID: UUID) async throws -> UIImage {
        defer {
            if remoteImageLoads[path]?.id == loadID { remoteImageLoads[path] = nil }
        }
        let data = try await imageData(path: path)
        let image = try await Task.detached(priority: .utility) {
            try ImageScrambler.rasterImage(from: data)
        }.value
        remoteImageCache.setObject(image, forKey: path as NSString, cost: Self.memoryCost(of: image))
        return image
    }

    private func performDecodedPageLoad(
        chapter: ChapterDetail,
        index: Int,
        cacheKey: String,
        loadID: UUID
    ) async throws -> UIImage {
        defer {
            if decodedPageLoads[cacheKey]?.id == loadID { decodedPageLoads[cacheKey] = nil }
        }
        let filename = chapter.images[index]
        let data = try await prioritizedImageData(
            path: chapter.pagePath(at: index),
            preferredDomain: nil,
            priority: .userInitiated
        )
        let image = try await Task.detached(priority: .userInitiated) {
            try ImageScrambler.decodeImage(
                data,
                scrambleID: chapter.scrambleID,
                photoID: chapter.id,
                filename: filename
            )
        }.value
        decodedPageCache.setObject(image, forKey: cacheKey as NSString, cost: Self.memoryCost(of: image))
        return image
    }

    func decodedPageData(chapter: ChapterDetail, index: Int) async throws -> Data {
        let filename = chapter.images[index]
        let data = try await imageData(path: chapter.pagePath(at: index))
        return try await Task.detached(priority: .userInitiated) {
            try ImageScrambler.decode(data, scrambleID: chapter.scrambleID, photoID: chapter.id, filename: filename)
        }.value
    }

    func updateDomains(api: String?, image: String?) {
        configuration.prioritize(apiDomain: api, imageDomain: image)
        if api != nil {
            cloneSessionCookiesAcrossDomains()
            persistCookies()
        }
    }

    func restoreBuiltInDomains() {
        configuration = .defaults
        preferredImageDomain = nil
        cloneSessionCookiesAcrossDomains()
        persistCookies()
    }

    func selectImageShunt(_ value: Int) {
        configuration.selectImageShunt(value)
        // The next chapter template response will supply the host for this
        // route.  Do not keep a transient preferred host from the old route.
        preferredImageDomain = nil
    }

    private func chapterTemplateMetadata(chapterID: String) async throws -> ChapterTemplateMetadata {
        let data = try await requestRaw(
            JMServiceProtocol.Request.chapterTemplate(
                chapterID: chapterID,
                imageShunt: configuration.imageShunt
            )
        )
        let text = String(decoding: data, as: UTF8.self)
        return ChapterTemplateMetadata.parse(text)
    }

    private func statusMessage(_ specification: JMServiceRequestSpec) async throws -> String {
        let value = try await requestDecoded(specification)
        guard let dict = value as? JSONDictionary else { return "操作成功" }
        guard dict.string(
            JMServiceProtocol.ResponseField.status,
            default: JMServiceProtocol.ResponseValue.successStatus
        ) == JMServiceProtocol.ResponseValue.successStatus else {
            throw APIError.server(dict.string(
                JMServiceProtocol.ResponseField.operationMessage,
                default: "操作失败"
            ))
        }
        return dict.string(JMServiceProtocol.ResponseField.operationMessage, default: "操作成功")
    }

    private func requestDecoded(
        _ specification: JMServiceRequestSpec,
        bypassBootstrap: Bool = false
    ) async throws -> Any {
        // 先等冷启动重登完成，再生成时间戳，避免启动网络较慢时签名过期。
        if !bypassBootstrap { await bootstrap() }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let data = try await requestRaw(
            specification,
            timestamp: timestamp,
            bypassBootstrap: true
        )
        guard let outer = try JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
            throw APIError.invalidResponse
        }
        guard outer.int(JMServiceProtocol.ResponseField.code)
                == JMServiceProtocol.ResponseValue.successCode else {
            throw APIError.server(outer.string(
                JMServiceProtocol.ResponseField.errorMessage,
                default: outer.string(
                    JMServiceProtocol.ResponseField.message,
                    default: "请求失败"
                )
            ))
        }
        guard let encoded = outer[JMServiceProtocol.ResponseField.data] as? String else {
            if let value = outer[JMServiceProtocol.ResponseField.data] { return value }
            throw APIError.invalidResponse
        }
        let decrypted = try JMCrypto.decryptResponse(encoded, timestamp: timestamp)
        return try JSONSerialization.jsonObject(with: decrypted, options: [.fragmentsAllowed])
    }

    private func requestRaw(
        _ specification: JMServiceRequestSpec,
        timestamp: String? = nil,
        bypassBootstrap: Bool = false
    ) async throws -> Data {
        if !bypassBootstrap { await bootstrap() }
        try Task.checkCancellation()
        let timestamp = timestamp ?? String(Int(Date().timeIntervalSince1970))
        var finalError: Error = APIError.noAvailableDomain
        var explicitAuthenticationError: Error?
        for domain in configuration.apiDomains {
            try Task.checkCancellation()
            do {
                guard var components = URLComponents(
                    string: domain + specification.endpoint.rawValue
                ) else { continue }
                components.queryItems = specification.query.sorted(by: { $0.key < $1.key }).map {
                    URLQueryItem(name: $0.key, value: $0.value)
                }
                guard let url = components.url else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = specification.method.rawValue
                for (field, value) in JMCrypto.signedHeaders(
                    timestamp: timestamp,
                    version: configuration.appVersion,
                    contentRequest: specification.signatureScope == .content
                ) { request.setValue(value, forHTTPHeaderField: field) }
                switch specification.bodyEncoding {
                case .none:
                    break
                case .urlEncoded:
                    request.setValue(
                        JMServiceProtocol.Header.urlEncodedContentType,
                        forHTTPHeaderField: JMServiceProtocol.Header.contentType
                    )
                    var body = URLComponents()
                    body.queryItems = specification.form.sorted(by: { $0.key < $1.key }).map {
                        URLQueryItem(name: $0.key, value: $0.value)
                    }
                    request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
                case .multipart:
                    let boundary = JMServiceProtocol.multipartBoundaryPrefix + UUID().uuidString
                    request.setValue(
                        JMServiceProtocol.Header.multipartContentTypePrefix + boundary,
                        forHTTPHeaderField: JMServiceProtocol.Header.contentType
                    )
                    request.httpBody = Self.multipartFormData(specification.form, boundary: boundary)
                }
                request.timeoutInterval = 8
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
                guard !data.isEmpty else { throw APIError.invalidResponse }
                recordSuccessfulAPIDomain(domain)
                return data
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                if explicitAuthenticationError == nil,
                   Self.isExplicitAuthenticationFailure(error) {
                    explicitAuthenticationError = error
                }
                finalError = error
            }
        }
        // Authentication failures are decisive. A later backup-domain timeout
        // must not hide a 401/403 and make bootstrap keep a known-invalid AVS.
        throw explicitAuthenticationError ?? finalError
    }

    private func fetchImage(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(
            JMServiceProtocol.Header.identityEncoding,
            forHTTPHeaderField: JMServiceProtocol.Header.acceptEncoding
        )
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              Self.isLikelyImageData(
                data,
                contentType: http.value(forHTTPHeaderField: JMServiceProtocol.Header.contentType)
              ) else {
            throw APIError.invalidResponse
        }
        return data
    }

    /// 类似 Happy Eyeballs：首线路先发，只在 1.25s 内没有结果时才逐步启动备用 CDN。
    /// 正常线路不会增加请求，而失效 CDN 也不再让每张图串行卡 8×4 秒。
    private func firstImageData(path: String, domains: [String]) async -> ImageFetchResult? {
        let session = session
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return await withTaskGroup(of: ImageFetchResult?.self) { group in
            for (offset, domain) in domains.enumerated() {
                guard let url = URL(string: domain + suffix) else { continue }
                group.addTask {
                    do {
                        if offset > 0 {
                            try await Task.sleep(nanoseconds: UInt64(offset) * 1_250_000_000)
                        }
                        try Task.checkCancellation()
                        var request = URLRequest(url: url)
                        request.setValue(
                            JMServiceProtocol.Header.identityEncoding,
                            forHTTPHeaderField: JMServiceProtocol.Header.acceptEncoding
                        )
                        request.cachePolicy = .returnCacheDataElseLoad
                        request.timeoutInterval = 8
                        let (data, response) = try await session.data(for: request)
                        guard let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              Self.isLikelyImageData(
                                data,
                                contentType: http.value(
                                    forHTTPHeaderField: JMServiceProtocol.Header.contentType
                                )
                              ) else { return nil }
                        return ImageFetchResult(domain: domain, data: data)
                    } catch {
                        return nil
                    }
                }
            }
            while let candidate = await group.next() {
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }
            return nil
        }
    }

    private func recordSuccessfulAPIDomain(_ domain: String) {
        let normalized = AppConfiguration.normalize(domain)
        guard configuration.apiDomains.first != normalized else { return }
        configuration.prioritize(apiDomain: normalized)
    }

    private func recordSuccessfulImageDomain(_ domain: String) {
        let normalized = AppConfiguration.normalize(domain)
        guard preferredImageDomain != normalized else { return }
        preferredImageDomain = normalized
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isCancellation(underlying) { return true }
        return false
    }

    /// CDN 有时会以 HTTP 200 返回防火墙 HTML；这种响应不能赢得线路竞速。
    nonisolated static func isLikelyImageData(_ data: Data, contentType: String?) -> Bool {
        guard !data.isEmpty else { return false }
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true } // JPEG
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true } // PNG
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return true }
        if bytes.count >= 12,
           String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
           String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" { return true }
        if bytes.starts(with: [0x42, 0x4D]) || // BMP
           bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) ||
           bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true } // TIFF
        if bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self).lowercased()
            if ["avif", "avis", "heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
                return true
            }
        }

        let textPrefix = String(decoding: data.prefix(96), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\u{FEFF}")
            ))
            .lowercased()
        // A blocked CDN may return an arbitrary HTML fragment or JSON body
        // while incorrectly retaining `image/*`. Reject all text-shaped
        // payloads before consulting Content-Type, not only full <html> pages.
        if textPrefix.hasPrefix("<") || textPrefix.hasPrefix("{") ||
           textPrefix.hasPrefix("[") { return false }
        return contentType?.lowercased().hasPrefix("image/") == true
    }

    nonisolated private static func discoveryData(from url: URL, session: URLSession) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    nonisolated private static func firstValidLineConfigurationData(
        from urls: [URL],
        session: URLSession
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            for url in urls {
                group.addTask {
                    guard let data = await discoveryData(from: url, session: session),
                          let text = String(data: data, encoding: .utf8),
                          text.contains("\(JMServiceProtocol.DiscoveryKey.apiDomains)=")
                            || text.contains("\(JMServiceProtocol.DiscoveryKey.imageDomains)=") else {
                        return nil
                    }
                    return data
                }
            }
            while let data = await group.next() {
                if let data {
                    group.cancelAll()
                    return data
                }
            }
            return nil
        }
    }

    nonisolated private static func uniqueDomains(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        return domains.compactMap { value in
            let normalized = AppConfiguration.normalize(value)
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    nonisolated private static func memoryCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? Int.max : max(1, cost)
    }

    private func decryptRawCipher(_ data: Data, secret: String) throws -> Data {
        let encoded = String(decoding: data, as: UTF8.self)
            .drop(while: { !$0.isASCII })
        return try JMCrypto.decryptResponse(String(encoded), timestamp: "", secret: secret)
    }

    private func extractDomains(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            if let string = item as? String { return string }
            if let row = item as? [Any] { return row.first as? String }
            return nil
        }.filter { $0.contains(".") }.map(AppConfiguration.normalize)
    }

    private func parseLineConfiguration(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    private func persistCookies() {
        let hosts = Set(configuration.apiDomains.compactMap { URL(string: $0)?.host })
        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter { cookie in
            hosts.contains { cookie.domain.contains($0) || $0.contains(cookie.domain) }
        }
        restoredSessionCookies = cookies
        if let data = try? JSONEncoder().encode(cookies.map(CookieRecord.init)) {
            _ = try? secureStore.save(data, account: cookieAccount)
        }
    }

    private func cloneSessionCookiesAcrossDomains() {
        let hosts = configuration.apiDomains.compactMap { URL(string: $0)?.host }
        var source = (HTTPCookieStorage.shared.cookies ?? []).filter { cookie in
            hosts.contains { cookie.domain.contains($0) || $0.contains(cookie.domain) }
        }
        // Domain discovery can replace every host. Keep restored cookies as the
        // trusted source for that one migration, otherwise a valid AVS would be
        // stranded on yesterday's host and appear to be missing.
        source.append(contentsOf: restoredSessionCookies)
        for cookie in source where !cookie.name.lowercased().hasPrefix("__cf") {
            for host in hosts where !cookie.domain.contains(host) {
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: cookie.name,
                    .value: cookie.value,
                    .domain: host,
                    .path: cookie.path,
                    .secure: cookie.isSecure
                ]
                if let expires = cookie.expiresDate { properties[.expires] = expires }
                if let clone = HTTPCookie(properties: properties) { HTTPCookieStorage.shared.setCookie(clone) }
            }
        }
    }

    private func restoreSession() {
        if let data = secureStore.load(account: cookieAccount),
           let records = try? JSONDecoder().decode([CookieRecord].self, from: data) {
            restoredSessionCookies = records.compactMap(\.cookie)
            restoredSessionCookies.forEach(HTTPCookieStorage.shared.setCookie)
        }
        if let data = secureStore.load(account: profileAccount) {
            profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        }
    }

    private func clearSessionCookiesAndProfile() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        secureStore.delete(account: cookieAccount)
        secureStore.delete(account: profileAccount)
        restoredSessionCookies = []
    }

    private func savedCredentials() -> LoginCredentials? {
        guard let data = secureStore.load(account: credentialsAccount) else { return nil }
        return try? JSONDecoder().decode(LoginCredentials.self, from: data)
    }
}

private actor AsyncPermitPool {
    private struct Waiter {
        let id: UUID
        let priority: TaskPriority
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var limit: Int
    private var inUse = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(priority: TaskPriority, limit requestedLimit: Int) async throws {
        try Task.checkCancellation()
        limit = DownloadConcurrencyPreferences.bounded(requestedLimit)
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                    drain()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        inUse = max(0, inUse - 1)
        drain()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func drain() {
        while inUse < limit, !waiters.isEmpty {
            var selected = 0
            for index in waiters.indices.dropFirst()
            where waiters[index].priority.rawValue > waiters[selected].priority.rawValue {
                selected = index
            }
            let waiter = waiters.remove(at: selected)
            inUse += 1
            waiter.continuation.resume(returning: true)
        }
    }
}

private struct SharedImageLoad {
    let id: UUID
    let task: Task<UIImage, Error>
}

private struct ImageFetchResult: Sendable {
    let domain: String
    let data: Data
}

private struct LoginCredentials: Codable {
    let username: String
    let password: String
}

private struct CookieRecord: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var expires: Date?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        secure = cookie.isSecure
        expires = cookie.expiresDate
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}

enum APIError: LocalizedError {
    case noAvailableDomain
    case invalidResponse
    case http(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noAvailableDomain: return "没有可用的 API 线路，请在设置中更新域名"
        case .invalidResponse: return "服务器返回的数据无效"
        case .http(let code): return "网络请求失败（HTTP \(code)）"
        case .server(let message): return message.isEmpty ? "服务器拒绝了请求" : message
        }
    }
}
