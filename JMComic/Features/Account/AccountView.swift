import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var history: ReadingHistoryStore
    @State private var dailyMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let profile = api.profile {
                    AccountProfileHeader(profile: profile)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 84, weight: .thin))
                            .foregroundStyle(.secondary)
                        Text("未登录")
                            .font(.title2.bold())
                        NavigationLink(value: AppNavigationRoute.login) {
                            Label("登录 JMComic", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }

                if api.profile != nil {
                    NavigationLink(value: AppNavigationRoute.myComments) {
                        HStack(spacing: 12) {
                            Label("我的评论", systemImage: "bubble.left.and.bubble.right")
                                .font(.title3.bold())
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .accountCardStyle()
                    }
                    .buttonStyle(.plain)
                }

                if api.profile != nil {
                    DailyCheckInCard(
                        status: api.dailyCheckInStatus,
                        isLoading: api.isLoadingDailyCheckIn,
                        isSigning: api.isSigningDailyCheckIn,
                        message: dailyMessage,
                        error: api.dailyCheckInError,
                        refresh: {
                            dailyMessage = nil
                            Task { await api.refreshDailyCheckInStatus(force: true) }
                        },
                        sign: { signDaily() }
                    )
                }

                RecentReadingSection()

                if let historyError = history.error {
                    Label(historyError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("我的")
        .toolbar {
            RootPageTrailingActions {
                NavigationLink(value: AppNavigationRoute.settings) {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .appPageBackground()
        .task(id: api.profile?.id) {
            await history.refreshRecent()
        }
        .onChange(of: api.profile?.id) { _, _ in dailyMessage = nil }
    }

    private func signDaily() {
        guard api.dailyCheckInStatus?.isSignedToday == false,
              !api.isSigningDailyCheckIn else { return }
        dailyMessage = nil
        Task {
            do {
                dailyMessage = try await api.signCurrentDaily()
            } catch is CancellationError {
                return
            } catch {
                // The shared API state exposes the actionable error in the card.
            }
        }
    }
}

private struct AccountProfileHeader: View {
    let profile: UserProfile

    private var levelTitle: String {
        let name = profile.levelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Lv. \(profile.level)" : "Lv. \(profile.level) · \(name)"
    }

    private var experienceTitle: String? {
        guard let experience = profile.experience else { return nil }
        if let next = profile.nextLevelExperience, next > 0 {
            return "经验 \(experience) / \(next)"
        }
        return "经验 \(experience)"
    }

    var body: some View {
        VStack(spacing: 12) {
            ProfileAvatar(profile: profile)
                .frame(width: 104, height: 104)

            Text(profile.username)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            Text(levelTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            if let experienceTitle {
                Text(experienceTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

private struct ProfileAvatar: View {
    @EnvironmentObject private var api: APIClient
    let profile: UserProfile
    @State private var image: UIImage?

    private var initials: String {
        String(profile.username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
            Text(initials.isEmpty ? "JM" : initials)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 3))
        .shadow(color: .black.opacity(0.13), radius: 12, y: 5)
        .task(id: profile.avatarPath) {
            guard !profile.avatarPath.isEmpty else { return }
            image = try? await api.displayImage(path: profile.avatarPath)
        }
        .accessibilityLabel("用户头像")
    }
}

private struct DailyCheckInCard: View {
    let status: DailyStatus?
    let isLoading: Bool
    let isSigning: Bool
    let message: String?
    let error: String?
    let refresh: () -> Void
    let sign: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                NavigationLink(value: AppNavigationRoute.dailyCheckIn) {
                    HStack(spacing: 12) {
                        Label("每日签到", systemImage: "calendar.badge.checkmark")
                            .font(.title3.bold())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看本月签到情况")

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isSigning)
                .accessibilityLabel("刷新签到状态")
            }

            HStack(spacing: 14) {
                Image(systemName: status?.isSignedToday == true ? "checkmark.seal.fill" : "gift.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(status?.isSignedToday == true ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusText)
                        .font(.headline)
                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 12)

                Button(status?.isSignedToday == true ? "已签到" : "签到", action: sign)
                    .buttonStyle(.borderedProminent)
                    .disabled(status == nil || status?.isSignedToday == true || isLoading || isSigning)
            }
        }
        .accountCardStyle()
        .overlay(alignment: .center) {
            if isLoading || isSigning {
                ProgressView()
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var statusText: String {
        if isSigning { return "正在签到…" }
        if isLoading { return "正在读取签到状态…" }
        if status?.isSignedToday == true { return "今日已签到" }
        if status != nil { return "今日尚未签到" }
        return "签到状态暂时不可用"
    }
}

struct DailyCheckInDetailView: View {
    @EnvironmentObject private var api: APIClient
    @State private var operationMessage: String?
    @State private var isToolbarRefreshing = false
    @State private var isPullRefreshing = false

    var body: some View {
        Group {
            if let status = api.dailyCheckInStatus {
                ScrollView {
                    VStack(spacing: 18) {
                        DailyCalendarCard(status: status)
                        DailyStreakCard(status: status)
                        DailyRewardAndActionCard(
                            status: status,
                            isRefreshing: api.isLoadingDailyCheckIn,
                            isSigning: api.isSigningDailyCheckIn,
                            message: operationMessage,
                            error: api.dailyCheckInError,
                            sign: sign
                        )
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .overlay {
                    if api.isLoadingDailyCheckIn,
                       !isToolbarRefreshing,
                       !isPullRefreshing,
                       !api.isSigningDailyCheckIn {
                        ProgressView()
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .accessibilityLabel("正在刷新本月签到情况")
                    }
                }
                .refreshable {
                    guard !api.isLoadingDailyCheckIn,
                          !api.isSigningDailyCheckIn else { return }
                    isPullRefreshing = true
                    await refresh()
                    isPullRefreshing = false
                }
            } else if api.isLoadingDailyCheckIn {
                AppLoadingView(accessibilityText: "正在载入本月签到情况")
            } else {
                RetryView(
                    title: "无法载入签到情况",
                    message: api.dailyCheckInError ?? "点击重试读取本月签到记录"
                ) {
                    Task { await refresh() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("每日签到")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if api.profile != nil, api.dailyCheckInStatus != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: refreshFromToolbar) {
                        if isToolbarRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(api.isLoadingDailyCheckIn || api.isSigningDailyCheckIn)
                    .accessibilityLabel("刷新本月签到情况")
                }
            }
        }
        .appPageBackground()
        .onChange(of: api.profile?.id) { _, _ in
            operationMessage = nil
            isToolbarRefreshing = false
            isPullRefreshing = false
        }
    }

    private func refresh() async {
        guard !api.isLoadingDailyCheckIn,
              !api.isSigningDailyCheckIn else { return }
        operationMessage = nil
        await api.refreshDailyCheckInStatus(force: true)
    }

    private func sign() {
        guard api.dailyCheckInStatus?.isSignedToday == false,
              !api.isLoadingDailyCheckIn,
              !api.isSigningDailyCheckIn else { return }
        operationMessage = nil
        Task {
            do {
                operationMessage = try await api.signCurrentDaily()
            } catch is CancellationError {
                return
            } catch {
                // APIClient publishes the actionable error for both screens.
            }
        }
    }

    private func refreshFromToolbar() {
        guard !api.isLoadingDailyCheckIn,
              !api.isSigningDailyCheckIn,
              !isToolbarRefreshing else { return }
        isToolbarRefreshing = true
        Task {
            await refresh()
            isToolbarRefreshing = false
        }
    }
}

private struct DailyCalendarCard: View {
    let status: DailyStatus

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 7
    )

    private var layout: DailyMonthLayout {
        DailyMonthLayout(year: status.calendarYear, month: status.calendarMonth)
    }

    private var monthTitle: String {
        let month = String(format: "%04d-%02d", status.calendarYear, status.calendarMonth)
        let event = status.eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        return event.isEmpty ? month : "\(month) 【\(event)】"
    }

    private var days: [Int] {
        guard layout.numberOfDays > 0 else { return [] }
        return Array(1...layout.numberOfDays)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(monthTitle)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<layout.leadingEmptyDays, id: \.self) { _ in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in
                    DailyCalendarDayCell(
                        day: day,
                        record: status.recordsByDay[day],
                        isToday: isToday(day)
                    )
                }
            }

            HStack(spacing: 18) {
                Label("已签到", systemImage: "checkmark")
                Label("额外奖励", systemImage: "star.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accountCardStyle()
    }

    private func isToday(_ day: Int) -> Bool {
        let components = DailyCalendarSystem.current.dateComponents(
            [.year, .month, .day],
            from: .now
        )
        return components.year == status.calendarYear
            && components.month == status.calendarMonth
            && components.day == day
    }
}

private struct DailyCalendarDayCell: View {
    let day: Int
    let record: DailyRecord?
    let isToday: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isToday ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055))

            Text("\(day)")
                .font(.subheadline.weight(isToday ? .bold : .regular))

            if record?.signed == true {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }

            if record?.bonus == true {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = ["\(day) 日"]
        parts.append(record?.signed == true ? "已签到" : "未签到")
        if record?.bonus == true { parts.append("额外奖励日") }
        if isToday { parts.append("今天") }
        return parts.joined(separator: "，")
    }
}

private struct DailyStreakCard: View {
    let status: DailyStatus

    private var progress: Int {
        min(max(status.longestSignedStreak, 0), 7)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("本月进度", systemImage: "calendar")
                .font(.title3.bold())

            HStack(alignment: .firstTextBaseline) {
                Text("已签到 \(status.signedDayCount) 天")
                    .font(.headline)
                Spacer()
                Text("最长连续 \(status.longestSignedStreak) 天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    VStack(spacing: 6) {
                        Image(systemName: day <= progress ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(day <= progress ? Color.accentColor : Color.secondary.opacity(0.45))
                        Text("\(day)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("七日连续进度，最长连续 \(progress) 天")
        }
        .accountCardStyle()
    }
}

private struct DailyRewardAndActionCard: View {
    let status: DailyStatus
    let isRefreshing: Bool
    let isSigning: Bool
    let message: String?
    let error: String?
    let sign: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("连续签到奖励", systemImage: "gift.fill")
                .font(.title3.bold())

            Label(
                "连续 3 天额外获得 \(status.threeDaysCoin) 金币、\(status.threeDaysExperience) 经验",
                systemImage: "3.circle.fill"
            )
            Label(
                "连续 7 天额外获得 \(status.sevenDaysCoin) 金币、\(status.sevenDaysExperience) 经验",
                systemImage: "7.circle.fill"
            )

            if let message, !message.isEmpty {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(action: sign) {
                HStack(spacing: 8) {
                    if isSigning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: status.isSignedToday ? "checkmark" : "calendar.badge.plus")
                    }
                    Text(buttonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(
                status.isSignedToday
                    || status.dailyID <= 0
                    || isRefreshing
                    || isSigning
            )
        }
        .accountCardStyle()
    }

    private var buttonTitle: String {
        if isSigning { return "签到中…" }
        return status.isSignedToday ? "今日已签到" : "签到"
    }
}

private struct RecentReadingSection: View {
    @EnvironmentObject private var history: ReadingHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: AppNavigationRoute.readingHistory) {
                HStack(spacing: 12) {
                    Label("最近浏览", systemImage: "clock.arrow.circlepath")
                        .font(.title3.bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看全部最近浏览")

            if history.recent.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.title2)
                    Text("还没有本地阅读记录")
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(history.recent.prefix(8)) { entry in
                            NavigationLink(value: AppNavigationRoute.comic(entry.comic)) {
                                VStack(alignment: .leading, spacing: 7) {
                                    ReadingHistoryComicCoverView(entry: entry)
                                        .frame(width: 104, height: 145)
                                    Text(entry.comic.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2)
                                        .frame(width: 104, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                // 封面条自己处理水平滚动，不把同一手势上报为根 Tab 切换。
                .rootTabSwipeExclusion()
            }
        }
        .accountCardStyle()
    }
}

private extension View {
    func accountCardStyle() -> some View {
        padding(18)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
    }
}

private struct ReadingHistoryRow: View {
    let entry: ReadingHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            ReadingHistoryComicCoverView(entry: entry)
                .frame(width: 48, height: 67)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.comic.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(entry.chapterTitle) · 第 \(entry.pageIndex + 1) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.lastViewedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ReadingHistoryListView: View {
    private static let pageSize = 40

    @EnvironmentObject private var history: ReadingHistoryStore
    @State private var entries: [ReadingHistoryEntry] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var showClearConfirmation = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink(value: AppNavigationRoute.comic(entry.comic)) {
                    ReadingHistoryRow(entry: entry)
                }
                .onAppear {
                    if entry.id == entries.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .overlay {
            if entries.isEmpty && !isLoading {
                ContentUnavailableView("还没有观看记录", systemImage: "clock")
            }
        }
        .navigationTitle("最近观看")
        .appPageBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { showClearConfirmation = true } label: {
                    Label("清空", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .task { if entries.isEmpty { await loadMore() } }
        .confirmationDialog("清空所有本地观看记录？", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive) {
                Task {
                    do {
                        try await history.clear()
                        entries = []
                        hasMore = false
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("读取历史失败", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("好") {}
        } message: {
            Text(error ?? "未知错误")
        }
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await history.page(offset: entries.count, limit: Self.pageSize)
            entries.append(contentsOf: next)
            hasMore = next.count == Self.pageSize
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var appearance: AppAppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var apiDomain = ""
    @State private var imageDomain = ""
    @State private var notice: String?
    @State private var isRefreshingCredentials = false
    @State private var showLogoutConfirmation = false
    @AppStorage(InterfacePreferences.showExplanatoryTextKey)
    private var showsExplanatoryText = false
    @AppStorage(DailyCheckInPreferences.automaticCheckInKey)
    private var automaticCheckIn = false
    @AppStorage(DownloadConcurrencyPreferences.cachedImageRequestsKey)
    private var cachedImageRequests = DownloadConcurrencyPreferences.defaultCachedImageRequests
    @AppStorage(DownloadConcurrencyPreferences.simultaneousComicsKey)
    private var simultaneousComics = DownloadConcurrencyPreferences.defaultSimultaneousComics
    @AppStorage(DownloadConcurrencyPreferences.pageDownloadsPerComicKey)
    private var pageDownloadsPerComic = DownloadConcurrencyPreferences.defaultPageDownloadsPerComic

    var body: some View {
        Form {
            Section("账号") {
                if let profile = api.profile {
                    LabeledContent("当前用户", value: profile.username)
                    if api.hasSavedCredentials {
                        Button {
                            refreshCredentials()
                        } label: {
                            HStack {
                                Label("重新登录刷新凭证", systemImage: "arrow.clockwise.shield")
                                Spacer()
                                if isRefreshingCredentials || api.isBootstrapping {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isRefreshingCredentials || api.isBootstrapping)
                    } else {
                        Label {
                            Text("当前是旧版保留的会话，没有可用于自动刷新的凭证。请退出后重新登录一次。")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                    }
                    if let lastError = api.lastError {
                        Label(lastError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button("退出登录", role: .destructive) {
                        showLogoutConfirmation = true
                    }
                    .disabled(isRefreshingCredentials || api.isBootstrapping)
                } else {
                    NavigationLink(value: AppNavigationRoute.login) {
                        Label("登录 JMComic", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                Toggle("自动签到", isOn: $automaticCheckIn)
                    .onChange(of: automaticCheckIn) { _, _ in
                        Task { await api.autoSignIfEnabled() }
                    }
                if showsExplanatoryText {
                    Text("开启后会在 App 启动会话恢复完成后检查当日状态，只在未签到时提交一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("外观") {
                Picker("显示模式", selection: $appearance.colorMode) {
                    ForEach(AppColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AppPalette.allCases) { palette in
                            Button {
                                appearance.palette = palette
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .fill(palette.swatch(for: colorScheme))
                                            .frame(width: 42, height: 42)
                                            .overlay(Circle().stroke(.primary.opacity(0.18)))
                                        if appearance.palette == palette {
                                            Image(systemName: "checkmark")
                                                .font(.headline.bold())
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    Text(palette.title)
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                }
                                .frame(width: 58)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("页面颜色：\(palette.title)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Toggle("显示说明文字", isOn: $showsExplanatoryText)
                if showsExplanatoryText {
                    Text("显示文件位置、收藏同步方式、兼容性等辅助说明。错误、实时进度和危险操作提示不受该开关影响。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("线路") {
                Picker("API 接口", selection: selectedAPIDomain) {
                    ForEach(api.configuration.apiDomains, id: \.self) { domain in
                        Text(Self.domainTitle(domain)).tag(domain)
                    }
                }
                .pickerStyle(.menu)

                Picker("图片线路", selection: imageShuntSelection) {
                    ForEach(AppConfiguration.availableImageShunts, id: \.self) { route in
                        Text("线路 \(route)").tag(route)
                    }
                }
                .pickerStyle(.menu)

                DisclosureGroup("添加自定义域名") {
                    TextField("API 域名", text: $apiDomain)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("图片 CDN 域名", text: $imageDomain)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("保存并优先使用") {
                        api.updateDomains(
                            api: apiDomain.isEmpty ? nil : apiDomain,
                            image: imageDomain.isEmpty ? nil : imageDomain
                        )
                        syncFields()
                        notice = "线路已保存"
                    }
                }

                Button("从上游更新线路") {
                    Task {
                        do {
                            try await api.refreshDomains()
                            syncFields()
                            notice = "线路已更新"
                        } catch {
                            notice = error.localizedDescription
                        }
                    }
                }
                Button("恢复内置线路") {
                    api.restoreBuiltInDomains()
                    syncFields()
                    notice = "已恢复内置线路"
                }
                if showsExplanatoryText {
                    Text("API 接口决定业务请求域名；图片线路 1–4 会作为 app_img_shunt 发送，并使用该线路返回的图片主机。线路失效时仍会自动尝试备用 CDN。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("网络与下载并发") {
                Stepper(
                    "缓存图片并发数：\(cachedImageRequests)",
                    value: $cachedImageRequests,
                    in: DownloadConcurrencyPreferences.allowedRange
                )
                Stepper(
                    "同时下载漫画数：\(simultaneousComics)",
                    value: $simultaneousComics,
                    in: DownloadConcurrencyPreferences.allowedRange
                )
                Stepper(
                    "单部漫画图片并发数：\(pageDownloadsPerComic)",
                    value: $pageDownloadsPerComic,
                    in: DownloadConcurrencyPreferences.allowedRange
                )
                if showsExplanatoryText {
                    Text("三项都限制为 1–5。缓存图片并发影响封面和在线阅读；另外两项限制实际下载传输。下载统一使用普通 dataTask，不再调用容易在侧载环境报 Cannot create file 的系统后台下载。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("兼容性") {
                LabeledContent("最低系统", value: "iOS / iPadOS 18")
                LabeledContent("构建 SDK", value: "iOS / iPadOS 26")
                if showsExplanatoryText {
                    Text("布局会自动适配 iPhone、iPad 分屏与自由窗口，不依赖固定屏幕尺寸。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("设置")
        .appPageBackground()
        .onAppear {
            normalizeConcurrencySettings()
            syncFields()
        }
        .confirmationDialog("确定退出当前账号？", isPresented: $showLogoutConfirmation) {
            Button("退出登录", role: .destructive) {
                api.logout()
                notice = "已退出登录"
            }
            Button("取消", role: .cancel) {}
        }
        .alert("提示", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("好") {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func syncFields() {
        apiDomain = api.configuration.apiDomains.first ?? ""
        imageDomain = api.configuration.imageDomains.first ?? ""
    }

    private var selectedAPIDomain: Binding<String> {
        Binding(
            get: { api.configuration.apiDomains.first ?? "" },
            set: { api.updateDomains(api: $0, image: nil) }
        )
    }

    private var imageShuntSelection: Binding<Int> {
        Binding(
            get: { api.configuration.imageShunt },
            set: { api.selectImageShunt($0) }
        )
    }

    private static func domainTitle(_ domain: String) -> String {
        URL(string: domain)?.host ?? domain
    }

    private func normalizeConcurrencySettings() {
        cachedImageRequests = DownloadConcurrencyPreferences.bounded(cachedImageRequests)
        simultaneousComics = DownloadConcurrencyPreferences.bounded(simultaneousComics)
        pageDownloadsPerComic = DownloadConcurrencyPreferences.bounded(pageDownloadsPerComic)
    }

    private func refreshCredentials() {
        isRefreshingCredentials = true
        Task {
            do {
                _ = try await api.refreshSavedLogin()
                notice = "登录凭证已刷新"
            } catch {
                notice = error.localizedDescription
            }
            isRefreshingCredentials = false
        }
    }
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var error: String?
    @AppStorage(InterfacePreferences.showExplanatoryTextKey)
    private var showsExplanatoryText = false

    var body: some View {
        Form {
            Section("JMComic 账号") {
                TextField("用户名或邮箱", text: $username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password).textContentType(.password)
            }
            Section {
                Button {
                    submit()
                } label: {
                    HStack {
                        Spacer()
                        if isLoggingIn { ProgressView().padding(.trailing, 6) }
                        Text("登录")
                        Spacer()
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || isLoggingIn)
            } footer: {
                if showsExplanatoryText {
                    Text("账号凭证与服务端会话仅保存在本机安全存储中。保存凭证后，每次新启动 App 会自动登录一次换取新的会话；同一进程内切换页面不会重复登录。")
                }
            }
        }
        .navigationTitle("登录")
        .appPageBackground()
        .alert("登录失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") {}
        } message: { Text(error ?? "") }
    }

    private func submit() {
        isLoggingIn = true
        Task {
            do {
                _ = try await api.login(username: username, password: password)
                // Establish the new account's shared daily snapshot without
                // delaying dismissal of the login screen.
                Task { await api.prepareDailyCheckInAfterLogin() }
                password = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isLoggingIn = false
            }
        }
    }
}
