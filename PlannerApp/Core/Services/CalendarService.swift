import Foundation

enum CalendarPlacementKind: String, Identifiable {
    case scheduled
    case due

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scheduled:
            "Запланировано"
        case .due:
            "Срок"
        }
    }
}

struct CalendarDay: Identifiable, Hashable {
    let index: Int
    let date: Date
    let title: String
    let subtitle: String

    var id: Int { index }
}

struct CalendarWeek {
    let startOfWeek: Date
    let days: [CalendarDay]
}

struct CalendarTaskPlacement: Identifiable {
    let task: PlannerTask
    let kind: CalendarPlacementKind
    let day: CalendarDay
    let startMinute: Int
    let durationMinutes: Int
    let isAllDay: Bool

    var id: String {
        "\(task.id.uuidString)-\(kind.rawValue)"
    }
}

enum CalendarService {
    private static let russianDayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let russianDaySubtitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    static func currentWeek(
        calendar: Calendar = .current,
        now: Date = .now
    ) -> CalendarWeek {
        week(containing: now, calendar: calendar)
    }

    static func week(
        containing date: Date,
        calendar: Calendar = .current
    ) -> CalendarWeek {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysFromMonday = (weekday + 5) % 7
        let startOfWeek = calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay

        let days = (0..<7).compactMap { index -> CalendarDay? in
            guard let dayDate = calendar.date(byAdding: .day, value: index, to: startOfWeek) else {
                return nil
            }

            return CalendarDay(
                index: index,
                date: dayDate,
                title: dayTitle(for: dayDate),
                subtitle: daySubtitle(for: dayDate)
            )
        }

        return CalendarWeek(startOfWeek: startOfWeek, days: days)
    }

    static func placements(
        from tasks: [PlannerTask],
        searchText: String,
        calendar: Calendar = .current,
        week: CalendarWeek
    ) -> [CalendarTaskPlacement] {
        tasks
            .filter { TaskListService.matchesSearch($0, searchText: searchText) }
            .flatMap { task in
                placements(for: task, calendar: calendar, week: week)
            }
            .sorted(by: comparePlacements)
    }

    static func date(
        for day: CalendarDay,
        hour: Int,
        minute: Int,
        calendar: Calendar = .current
    ) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: day.date
        ) ?? day.date
    }

    static func isAllDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)

        return (components.hour ?? 0) == 0
            && (components.minute ?? 0) == 0
            && (components.second ?? 0) == 0
            && (components.nanosecond ?? 0) == 0
    }

    private static func placements(
        for task: PlannerTask,
        calendar: Calendar,
        week: CalendarWeek
    ) -> [CalendarTaskPlacement] {
        var placements: [CalendarTaskPlacement] = []

        if let scheduled = task.scheduled,
           let placement = placement(
            for: task,
            kind: .scheduled,
            date: scheduled,
            calendar: calendar,
            week: week,
            durationMinutes: durationMinutes(for: task, scheduled: scheduled, calendar: calendar)
           ) {
            placements.append(placement)
        }

        if let due = task.due,
           !dueRepresentsScheduledEnd(for: task, due: due, calendar: calendar),
           let placement = placement(
            for: task,
            kind: .due,
            date: due,
            calendar: calendar,
            week: week,
            durationMinutes: 30
           ) {
            placements.append(placement)
        }

        return placements
    }

    private static func placement(
        for task: PlannerTask,
        kind: CalendarPlacementKind,
        date: Date,
        calendar: Calendar,
        week: CalendarWeek,
        durationMinutes: Int
    ) -> CalendarTaskPlacement? {
        guard let day = week.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
            return nil
        }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let startMinute = max(0, min(1_439, (hour * 60) + minute))
        let isAllDay = isAllDay(date, calendar: calendar)

        return CalendarTaskPlacement(
            task: task,
            kind: kind,
            day: day,
            startMinute: startMinute,
            durationMinutes: durationMinutes,
            isAllDay: isAllDay
        )
    }

    private static func durationMinutes(
        for task: PlannerTask,
        scheduled: Date,
        calendar: Calendar
    ) -> Int {
        guard
            let due = task.due,
            dueRepresentsScheduledEnd(for: task, due: due, calendar: calendar)
        else {
            return 30
        }

        let components = calendar.dateComponents([.hour, .minute], from: scheduled)
        let startMinute = max(0, min(1_439, ((components.hour ?? 0) * 60) + (components.minute ?? 0)))
        let rawDuration = max(1, Int(due.timeIntervalSince(scheduled) / 60))
        let roundedDuration = max(30, Int(ceil(Double(rawDuration) / 30.0)) * 30)
        return min(1_440 - startMinute, roundedDuration)
    }

    private static func dueRepresentsScheduledEnd(
        for task: PlannerTask,
        due: Date,
        calendar: Calendar
    ) -> Bool {
        guard let scheduled = task.scheduled else {
            return false
        }

        return due > scheduled && calendar.isDate(due, inSameDayAs: scheduled)
    }

    private static func comparePlacements(_ lhs: CalendarTaskPlacement, _ rhs: CalendarTaskPlacement) -> Bool {
        if lhs.day.index != rhs.day.index {
            return lhs.day.index < rhs.day.index
        }

        if lhs.isAllDay != rhs.isAllDay {
            return lhs.isAllDay
        }

        if lhs.startMinute != rhs.startMinute {
            return lhs.startMinute < rhs.startMinute
        }

        return lhs.task.createdAt < rhs.task.createdAt
    }

    private static func dayTitle(for date: Date) -> String {
        russianDayTitleFormatter.string(from: date)
    }

    private static func daySubtitle(for date: Date) -> String {
        russianDaySubtitleFormatter.string(from: date)
    }
}
