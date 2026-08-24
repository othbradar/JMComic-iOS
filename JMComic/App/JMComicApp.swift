import SwiftUI

@main
struct JMComicApp: App {
    @StateObject private var api = APIClient()
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var readingProgress = ReadingProgressStore()
    @StateObject private var readingHistory = ReadingHistoryStore()
    @StateObject private var appearance = AppAppearanceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(api)
                .environmentObject(downloads)
                .environmentObject(readingProgress)
                .environmentObject(readingHistory)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.preferredColorScheme)
                .task {
                    await api.bootstrap()
                    await api.autoSignIfEnabled()
                }
        }
    }
}
