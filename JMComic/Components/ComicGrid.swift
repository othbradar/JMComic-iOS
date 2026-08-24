import SwiftUI

/// Every destination that can be pushed from more than one root tab uses a
/// value route.  The owning root `NavigationStack` can therefore observe its
/// path directly and give the interactive-pop gesture exclusive ownership as
/// soon as any secondary page is present.
enum AppNavigationRoute: Hashable {
    case comic(ComicSummary)
    case search(String)
    case login
    case settings
    case myComments
    case dailyCheckIn
    case readingHistory
}

private struct AppNavigationDestination: View {
    let route: AppNavigationRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case let .comic(comic):
            ComicDetailView(comicID: comic.id, initialComic: comic)
        case let .search(query):
            SearchView(initialQuery: query)
        case .login:
            LoginView()
        case .settings:
            SettingsView()
        case .myComments:
            MyCommentsView()
        case .dailyCheckIn:
            DailyCheckInDetailView()
        case .readingHistory:
            ReadingHistoryListView()
        }
    }
}

extension View {
    /// Register once on the first page inside each root navigation stack.
    /// Descendants can then push `AppNavigationRoute` values without owning a
    /// separate hidden stack or an unobservable closure-style link.
    func appNavigationDestinations() -> some View {
        navigationDestination(for: AppNavigationRoute.self) { route in
            AppNavigationDestination(route: route)
        }
    }
}

struct ComicGrid: View {
    enum CoverSource {
        case remote
        case favorite(accountID: String, relativePaths: [String: String])
    }

    let comics: [ComicSummary]
    var minimumWidth: CGFloat = 150
    var coverSource: CoverSource = .remote

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth, maximum: 220), spacing: 16)], spacing: 22) {
            ForEach(comics) { comic in
                NavigationLink(value: AppNavigationRoute.comic(comic)) {
                    VStack(alignment: .leading, spacing: 8) {
                        cover(for: comic)
                        Text(comic.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(comic.authorText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func cover(for comic: ComicSummary) -> some View {
        switch coverSource {
        case .remote:
            ComicCoverView(comic: comic)
        case let .favorite(accountID, relativePaths):
            FavoriteComicCoverView(
                accountID: accountID,
                comic: comic,
                storedRelativePath: relativePaths[comic.id]
            )
        }
    }
}

struct RetryView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry).buttonStyle(.borderedProminent)
        }
    }
}
