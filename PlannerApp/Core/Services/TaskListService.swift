import Foundation

enum UpcomingSectionKind: String, CaseIterable, Identifiable {
    case today
    case tomorrow
    case thisWeek
    case nextWeek
    case later
    case noDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            "Сегодня"
        case .tomorrow:
            "Завтра"
        case .thisWeek:
            "Эта неделя"
        case .nextWeek:
            "Следующая неделя"
        case .later:
            "Позже"
        case .noDate:
            "Без даты"
        }
    }
}

enum UpcomingRange: String, CaseIterable, Identifiable {
    case nextWeek
    case nextFourWeeks
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nextWeek:
            "7 дней"
        case .nextFourWeeks:
            "4 недели"
        case .all:
            "Все"
        }
    }
}

struct UpcomingSection: Identifiable {
    let kind: UpcomingSectionKind
    let tasks: [PlannerTask]

    var id: String { kind.id }
    var title: String { kind.title }
}

struct ProjectProgress {
    let totalTasks: Int
    let closedTasks: Int

    var fraction: Double {
        guard totalTasks > 0 else {
            return 0
        }

        return Double(closedTasks) / Double(totalTasks)
    }
}

enum TaskListService {
    static func inboxTasks(
        from tasks: [PlannerTask],
        searchText: String
    ) -> [PlannerTask] {
        tasks
            .filter { $0.status == .inbox }
            .filter { matchesSearch($0, searchText: searchText) }
            .sorted(by: comparePriorityDescendingThenCreatedAscending)
    }

    static func todayTasks(
        from tasks: [PlannerTask],
        searchText: String,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [PlannerTask] {
        let todayEnd = endOfDay(for: now, calendar: calendar)

        return tasks
            .filter(isActive)
            .filter { task in
                (task.scheduled.map { $0 <= todayEnd } ?? false)
                    || (task.due.map { $0 <= todayEnd } ?? false)
            }
            .filter { matchesSearch($0, searchText: searchText) }
            .sorted(by: comparePriorityDescendingThenDueThenScheduled)
    }

    static func upcomingSections(
        from tasks: [PlannerTask],
        searchText: String,
        range: UpcomingRange = .nextWeek,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [UpcomingSection] {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let dayAfterTomorrowStart = calendar.date(byAdding: .day, value: 2, to: todayStart) ?? todayStart
        let thisWeekEnd = endOfWeek(containing: now, calendar: calendar)
        let nextWeekEnd = calendar.date(byAdding: DateComponents(day: 8, second: -1), to: todayStart) ?? now
        let rangeEnd = upcomingRangeEnd(for: range, from: todayStart, calendar: calendar)

        let activeTasks = tasks
            .filter(isActive)
            .filter { matchesSearch($0, searchText: searchText) }

        let datedTasks = activeTasks.compactMap { task -> (task: PlannerTask, date: Date)? in
            guard let date = upcomingDate(for: task, from: todayStart, through: rangeEnd) else {
                return nil
            }

            return (task, date)
        }

        let todayTasks = datedTasks
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .map(\.task)
            .sorted(by: compareUpcoming)

        let tomorrowTasks = datedTasks
            .filter { calendar.isDate($0.date, inSameDayAs: tomorrowStart) }
            .map(\.task)
            .sorted(by: compareUpcoming)

        let thisWeekTasks = datedTasks
            .filter { item in
                item.date >= dayAfterTomorrowStart && item.date <= thisWeekEnd
            }
            .map(\.task)
            .sorted(by: compareUpcoming)

        let nextWeekTasks = datedTasks
            .filter { item in
                item.date > thisWeekEnd && item.date <= nextWeekEnd
            }
            .map(\.task)
            .sorted(by: compareUpcoming)

        let laterTasks = datedTasks
            .filter { $0.date > nextWeekEnd }
            .map(\.task)
            .sorted(by: compareUpcoming)

        let noDateTasks = activeTasks
            .filter { $0.scheduled == nil && $0.due == nil }
            .sorted(by: comparePriorityDescendingThenCreatedAscending)

        return [
            UpcomingSection(kind: .today, tasks: todayTasks),
            UpcomingSection(kind: .tomorrow, tasks: tomorrowTasks),
            UpcomingSection(kind: .thisWeek, tasks: thisWeekTasks),
            UpcomingSection(kind: .nextWeek, tasks: nextWeekTasks),
            UpcomingSection(kind: .later, tasks: laterTasks),
            UpcomingSection(kind: .noDate, tasks: noDateTasks)
        ].filter { !$0.tasks.isEmpty }
    }

    static func completedTasks(
        from tasks: [PlannerTask],
        searchText: String
    ) -> [PlannerTask] {
        tasks
            .filter { $0.status == .done || $0.status == .cancelled }
            .filter { matchesSearch($0, searchText: searchText) }
            .sorted(by: compareCompletedDescending)
    }

    static func tasks(
        for project: Project,
        tasks: [PlannerTask],
        searchText: String
    ) -> [PlannerTask] {
        tasks
            .filter { $0.project?.id == project.id }
            .filter { matchesSearch($0, searchText: searchText) }
            .sorted(by: compareProjectTask)
    }

    static func progress(
        for project: Project,
        tasks: [PlannerTask]
    ) -> ProjectProgress {
        let projectTasks = tasks.filter { $0.project?.id == project.id }
        let closedTasks = projectTasks.filter { $0.status == .done || $0.status == .cancelled }

        return ProjectProgress(
            totalTasks: projectTasks.count,
            closedTasks: closedTasks.count
        )
    }

    static func activeProjects(
        from projects: [Project],
        searchText: String
    ) -> [Project] {
        projects
            .filter { $0.status == .active }
            .filter { matchesSearch($0, searchText: searchText) }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    static func matchesSearch(_ task: PlannerTask, searchText: String) -> Bool {
        let query = normalizedSearchText(searchText)
        guard !query.isEmpty else {
            return true
        }

        return task.title.localizedCaseInsensitiveContains(query)
            || task.notes.localizedCaseInsensitiveContains(query)
            || (task.project?.title.localizedCaseInsensitiveContains(query) ?? false)
    }

    static func matchesSearch(_ project: Project, searchText: String) -> Bool {
        let query = normalizedSearchText(searchText)
        guard !query.isEmpty else {
            return true
        }

        return project.title.localizedCaseInsensitiveContains(query)
            || project.notes.localizedCaseInsensitiveContains(query)
    }

    static func isActive(_ task: PlannerTask) -> Bool {
        task.status != .done && task.status != .cancelled
    }

    private static func normalizedSearchText(_ searchText: String) -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endOfDay(for date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date)) ?? date
    }

    private static func endOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let week = CalendarService.week(containing: date, calendar: calendar)
        return calendar.date(byAdding: DateComponents(day: 7, second: -1), to: week.startOfWeek) ?? date
    }

    private static func upcomingRangeEnd(
        for range: UpcomingRange,
        from todayStart: Date,
        calendar: Calendar
    ) -> Date? {
        switch range {
        case .nextWeek:
            calendar.date(byAdding: DateComponents(day: 8, second: -1), to: todayStart)
        case .nextFourWeeks:
            calendar.date(byAdding: DateComponents(day: 29, second: -1), to: todayStart)
        case .all:
            nil
        }
    }

    private static func upcomingDate(
        for task: PlannerTask,
        from start: Date,
        through end: Date?
    ) -> Date? {
        [task.scheduled, task.due]
            .compactMap { $0 }
            .filter { date in
                guard date >= start else {
                    return false
                }

                if let end {
                    return date <= end
                }

                return true
            }
            .min()
    }

    private static func comparePriorityDescendingThenCreatedAscending(
        _ lhs: PlannerTask,
        _ rhs: PlannerTask
    ) -> Bool {
        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder > rhs.priority.sortOrder
        }

        return lhs.createdAt < rhs.createdAt
    }

    private static func comparePriorityDescendingThenDueThenScheduled(
        _ lhs: PlannerTask,
        _ rhs: PlannerTask
    ) -> Bool {
        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder > rhs.priority.sortOrder
        }

        if let result = compareOptionalDatesAscending(lhs.due, rhs.due) {
            return result
        }

        if let result = compareOptionalDatesAscending(lhs.scheduled, rhs.scheduled) {
            return result
        }

        return lhs.createdAt < rhs.createdAt
    }

    private static func compareUpcoming(_ lhs: PlannerTask, _ rhs: PlannerTask) -> Bool {
        if let result = compareOptionalDatesAscending(listDate(for: lhs), listDate(for: rhs)) {
            return result
        }

        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder > rhs.priority.sortOrder
        }

        return lhs.createdAt < rhs.createdAt
    }

    private static func listDate(for task: PlannerTask) -> Date? {
        [task.scheduled, task.due].compactMap { $0 }.min()
    }

    private static func compareCompletedDescending(_ lhs: PlannerTask, _ rhs: PlannerTask) -> Bool {
        if let result = compareOptionalDatesDescending(lhs.completedAt, rhs.completedAt) {
            return result
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.createdAt > rhs.createdAt
    }

    private static func compareProjectTask(_ lhs: PlannerTask, _ rhs: PlannerTask) -> Bool {
        if isActive(lhs) != isActive(rhs) {
            return isActive(lhs)
        }

        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder > rhs.priority.sortOrder
        }

        if let result = compareOptionalDatesAscending(lhs.due, rhs.due) {
            return result
        }

        return lhs.createdAt < rhs.createdAt
    }

    private static func compareOptionalDatesAscending(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return nil
        }
    }

    private static func compareOptionalDatesDescending(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return nil
        }
    }
}
