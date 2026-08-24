/// Upstream JSON field names used to map JM responses into the app's domain models.
///
/// Keep wire-schema literals here. User-facing fallback text and local persistence
/// keys belong to their respective feature and storage layers instead.
enum JMServiceResponseSchema {
    enum Comic {
        static let id = "id"
        static let legacyAlbumID = "AID"
        static let name = "name"
        static let title = "title"
        static let authors = "author"
        static let tags = "tags"
        static let works = "works"
        static let actors = "actors"
        static let summary = "description"
        static let likes = "likes"
        static let totalViews = "total_views"
        static let commentTotal = "comment_total"
        static let isFavorite = "is_favorite"
        static let series = "series"
        static let relatedList = "related_list"
    }

    enum Chapter {
        static let id = "id"
        static let sort = "sort"
        static let name = "name"
        static let seriesID = "series_id"
        static let images = "images"
    }

    enum Home {
        static let title = "title"
        static let content = "content"
    }

    enum Profile {
        static let userID = "uid"
        static let username = "username"
        static let levelName = "level_name"
        static let level = "level"
        static let coin = "coin"
        static let favoriteCount = "album_favorites"
        static let favoriteLimit = "album_favorites_max"
        static let photo = "photo"
        static let experience = "exp"
        static let nextLevelExperience = "nextLevelExp"
    }

    enum Favorite {
        static let folderID = "FID"
        static let fallbackID = "id"
        static let name = "name"
        static let count = "count"
        static let total = "total"
        static let list = "list"
        static let folderList = "folder_list"
    }

    enum Comment {
        static let id = "CID"
        static let albumID = "AID"
        static let comicName = "name"
        static let albumName = "album_name"
        static let alternateComicName = "comic_name"
        static let title = "title"
        static let userID = "UID"
        static let username = "username"
        static let nickname = "nickname"
        static let photo = "photo"
        static let content = "content"
        static let likes = "likes"
        static let addedAt = "addtime"
        static let experienceInfo = "expinfo"
        static let levelName = "level_name"
        static let replies = "replys"
        static let total = "total"
        static let list = "list"
    }

    enum Daily {
        static let date = "date"
        static let signed = "signed"
        static let bonus = "bonus"
        static let dailyID = "daily_id"
        static let eventName = "event_name"
        static let currentProgress = "currentProgress"
        static let threeDaysCoin = "three_days_coin"
        static let threeDaysExperience = "three_days_exp"
        static let sevenDaysCoin = "seven_days_coin"
        static let sevenDaysExperience = "seven_days_exp"
        static let records = "record"
    }
}
