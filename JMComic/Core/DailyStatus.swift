import Foundation

enum DailyCheckInPreferences {
    static let automaticCheckInKey = "jm.account.automatic-daily-check-in"
}

enum DailyCalendarSystem {
    static var current: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

/// Keeps the account page read-only with respect to the network. A status is
/// loaded once for the active account (normally during cold-start bootstrap),
/// then only an explicit refresh, a new account, or a successful check-in may
/// request it again.
enum DailyStatusRefreshPolicy {
    static func shouldLoad(
        userID: String?,
        attemptedUserID: String?,
        force: Bool
    ) -> Bool {
        guard let userID, !userID.isEmpty else { return false }
        return force || attemptedUserID != userID
    }
}

enum DailyCheckInSubmissionPolicy {
    static func needsFreshStatus(
        userID: String,
        statusUserID: String?,
        status: DailyStatus?,
        now: Date = .now,
        calendar: Calendar = DailyCalendarSystem.current
    ) -> Bool {
        guard !userID.isEmpty,
              statusUserID == userID,
              let status else { return true }
        return !status.belongsToMonth(containing: now, calendar: calendar)
    }
}

struct DailyRecord: Identifiable, Hashable {
    let date: Int
    let signed: Bool
    let bonus: Bool

    var id: Int { date }

    init(json: JSONDictionary, fallbackDate: Int? = nil) {
        let explicitDate = Self.dayNumber(
            from: json.string(JMServiceResponseSchema.Daily.date)
        )
        date = explicitDate ?? fallbackDate ?? 0
        signed = json.bool(JMServiceResponseSchema.Daily.signed)
        bonus = json.bool(JMServiceResponseSchema.Daily.bonus)
    }

    init(date: Int, signed: Bool, bonus: Bool) {
        self.date = date
        self.signed = signed
        self.bonus = bonus
    }

    private static func dayNumber(from rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Int(trimmed), (1...31).contains(direct) {
            return direct
        }

        // Some compatible servers return an ISO-like date instead of a plain
        // day number. Prefer the third numeric component (yyyy-MM-dd) and keep
        // the sequential fallback for the mobile API variant that omits date.
        let components = trimmed
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        if components.count >= 3, (1...31).contains(components[2]) {
            return components[2]
        }
        return nil
    }
}

struct DailyStatus: Hashable {
    let dailyID: Int
    let eventName: String
    let currentProgress: String
    let threeDaysCoin: Int
    let threeDaysExperience: Int
    let sevenDaysCoin: Int
    let sevenDaysExperience: Int
    private(set) var records: [DailyRecord]
    let calendarYear: Int
    let calendarMonth: Int

    init(
        json: JSONDictionary,
        referenceDate: Date = .now,
        calendar: Calendar = DailyCalendarSystem.current
    ) {
        let components = calendar.dateComponents([.year, .month], from: referenceDate)
        calendarYear = components.year ?? 0
        calendarMonth = components.month ?? 0
        dailyID = json.int(JMServiceResponseSchema.Daily.dailyID)
        eventName = json.string(
            JMServiceResponseSchema.Daily.eventName,
            default: "每日签到"
        )
        currentProgress = json.string(JMServiceResponseSchema.Daily.currentProgress)
        threeDaysCoin = json.int(JMServiceResponseSchema.Daily.threeDaysCoin)
        threeDaysExperience = json.int(JMServiceResponseSchema.Daily.threeDaysExperience)
        sevenDaysCoin = json.int(JMServiceResponseSchema.Daily.sevenDaysCoin)
        sevenDaysExperience = json.int(JMServiceResponseSchema.Daily.sevenDaysExperience)

        let nested = json[JMServiceResponseSchema.Daily.records] as? [[JSONDictionary]] ?? []
        let flat = nested.flatMap { $0 }
        let fallback = json[JMServiceResponseSchema.Daily.records] as? [JSONDictionary] ?? []
        let rawRecords = flat.isEmpty ? fallback : flat
        let monthDayCount = DailyMonthLayout(
            year: calendarYear,
            month: calendarMonth,
            calendar: calendar
        ).numberOfDays
        let maximumValidDay = monthDayCount > 0 ? monthDayCount : 31
        var seenDates: Set<Int> = []
        records = rawRecords
            .enumerated()
            .map { index, record in
                DailyRecord(json: record, fallbackDate: index + 1)
            }
            .filter {
                (1...maximumValidDay).contains($0.date)
                    && seenDates.insert($0.date).inserted
            }
            .sorted { $0.date < $1.date }
    }

    var isSignedToday: Bool {
        isSigned(on: .now)
    }

    var isCurrentMonth: Bool {
        belongsToMonth(containing: .now)
    }

    func belongsToMonth(
        containing date: Date,
        calendar: Calendar = DailyCalendarSystem.current
    ) -> Bool {
        let components = calendar.dateComponents([.year, .month], from: date)
        return components.year == calendarYear && components.month == calendarMonth
    }

    func isSigned(
        on date: Date,
        calendar: Calendar = DailyCalendarSystem.current
    ) -> Bool {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard belongsToMonth(containing: date, calendar: calendar),
              let day = components.day else { return false }
        return records.first(where: { $0.date == day })?.signed == true
    }

    var signedDayCount: Int {
        records.lazy.filter(\.signed).count
    }

    var recordsByDay: [Int: DailyRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.date, $0) })
    }

    /// Matches the upstream monthly calendar: scan records in day order, reset
    /// on a gap or unsigned day, and retain the longest consecutive segment.
    var longestSignedStreak: Int {
        var longest = 0
        var current = 0
        var previousSignedDay: Int?

        for record in records.sorted(by: { $0.date < $1.date }) {
            guard record.signed else {
                current = 0
                previousSignedDay = nil
                continue
            }
            if let previousSignedDay, record.date == previousSignedDay + 1 {
                current += 1
            } else {
                current = 1
            }
            previousSignedDay = record.date
            longest = max(longest, current)
        }
        return longest
    }

    func markingSigned(
        on date: Date = .now,
        calendar: Calendar = DailyCalendarSystem.current
    ) -> DailyStatus {
        guard belongsToMonth(containing: date, calendar: calendar),
              let day = calendar.dateComponents([.day], from: date).day else {
            return self
        }

        var updated = self
        if let index = updated.records.firstIndex(where: { $0.date == day }) {
            let existing = updated.records[index]
            updated.records[index] = DailyRecord(
                date: day,
                signed: true,
                bonus: existing.bonus
            )
        } else {
            updated.records.append(DailyRecord(date: day, signed: true, bonus: false))
            updated.records.sort { $0.date < $1.date }
        }
        return updated
    }
}

struct DailyMonthLayout: Hashable {
    let numberOfDays: Int
    let leadingEmptyDays: Int

    init(
        year: Int,
        month: Int,
        calendar: Calendar = DailyCalendarSystem.current
    ) {
        guard let firstDay = calendar.date(
            from: DateComponents(year: year, month: month, day: 1)
        ), let dayRange = calendar.range(of: .day, in: .month, for: firstDay) else {
            numberOfDays = 0
            leadingEmptyDays = 0
            return
        }
        numberOfDays = dayRange.count
        // Calendar weekday is 1-based with Sunday == 1. The UI intentionally
        // mirrors the upstream Sunday-first monthly grid.
        leadingEmptyDays = calendar.component(.weekday, from: firstDay) - 1
    }
}
