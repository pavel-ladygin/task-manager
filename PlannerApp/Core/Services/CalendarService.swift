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
        "\(task.id.uuidString)-\(kind.rawValue)-\(day.index)"
    }
}

struct CalendarLayoutItem: Identifiable {
    let placement: CalendarTaskPlacement
    let lane: Int
    let laneCount: Int
    var id: String { placement.id }
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
            .filter(TaskListService.isActive)
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

    static func layoutOverlaps(_ placements: [CalendarTaskPlacement]) -> [CalendarLayoutItem] {
        let sorted = placements.sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            return $0.durationMinutes > $1.durationMinutes
        }
        var result: [CalendarLayoutItem] = []
        var cluster: [CalendarTaskPlacement] = []
        var clusterEnd = -1

        func layoutCluster(_ cluster: [CalendarTaskPlacement]) -> [CalendarLayoutItem] {
            var laneEnds: [Int] = []
            var assigned: [(CalendarTaskPlacement, Int)] = []
            for placement in cluster {
                let start = placement.startMinute
                let end = start + max(1, placement.durationMinutes)
                if let lane = laneEnds.firstIndex(where: { $0 <= start }) {
                    laneEnds[lane] = end
                    assigned.append((placement, lane))
                } else {
                    assigned.append((placement, laneEnds.count))
                    laneEnds.append(end)
                }
            }
            let count = max(1, laneEnds.count)
            return assigned.map { CalendarLayoutItem(placement: $0.0, lane: $0.1, laneCount: count) }
        }

        for placement in sorted {
            if !cluster.isEmpty, placement.startMinute >= clusterEnd {
                result.append(contentsOf: layoutCluster(cluster))
                cluster.removeAll(keepingCapacity: true)
                clusterEnd = -1
            }
            cluster.append(placement)
            clusterEnd = max(clusterEnd, placement.startMinute + max(1, placement.durationMinutes))
        }
        if !cluster.isEmpty { result.append(contentsOf: layoutCluster(cluster)) }
        return result
    }

    static func moving(
        _ placement: CalendarTaskPlacement,
        toDay day: CalendarDay,
        minuteOfDay: Int? = nil,
        calendar: Calendar = .current
    ) -> Date {
        let sourceDate = placement.kind == .scheduled ? placement.task.scheduled : placement.task.due
        let sourceComponents = sourceDate.map { calendar.dateComponents([.hour, .minute], from: $0) }
        let sourceMinute = sourceComponents.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) } ?? placement.startMinute
        let targetMinute = max(0, min(1_439, minuteOfDay ?? sourceMinute))
        return date(for: day, hour: targetMinute / 60, minute: targetMinute % 60, calendar: calendar)
    }

    private static func placements(
        for task: PlannerTask,
        calendar: Calendar,
        week: CalendarWeek
    ) -> [CalendarTaskPlacement] {
        var placements: [CalendarTaskPlacement] = []

        if let scheduled = task.scheduled {
            if let due = task.due, due > scheduled {
                placements.append(contentsOf: rangePlacements(
                    for: task,
                    scheduled: scheduled,
                    due: due,
                    calendar: calendar,
                    week: week
                ))
            } else if let placement = placement(
                for: task,
                kind: .scheduled,
                date: scheduled,
                calendar: calendar,
                week: week,
                durationMinutes: 30
            ) {
                placements.append(placement)
            }
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

    private static func rangePlacements(
        for task: PlannerTask,
        scheduled: Date,
        due: Date,
        calendar: Calendar,
        week: CalendarWeek
    ) -> [CalendarTaskPlacement] {
        week.days.compactMap { day in
            let dayStart = calendar.startOfDay(for: day.date)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  scheduled < nextDay, due > dayStart else { return nil }

            let segmentStart = max(scheduled, dayStart)
            let segmentEnd = min(due, nextDay)
            let startComponents = calendar.dateComponents([.hour, .minute], from: segmentStart)
            let startMinute = segmentStart == dayStart
                ? 0
                : max(0, min(1_439, (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)))
            let endMinute: Int
            if segmentEnd == nextDay {
                endMinute = 1_440
            } else {
                let endComponents = calendar.dateComponents([.hour, .minute], from: segmentEnd)
                endMinute = max(startMinute + 1, min(1_440, (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)))
            }
            let rawDuration = max(1, endMinute - startMinute)
            let duration = min(1_440 - startMinute, max(30, Int(ceil(Double(rawDuration) / 30)) * 30))
            return CalendarTaskPlacement(
                task: task,
                kind: .scheduled,
                day: day,
                startMinute: startMinute,
                durationMinutes: duration,
                isAllDay: startMinute == 0 && endMinute == 1_440
            )
        }
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

    private static func dueRepresentsScheduledEnd(
        for task: PlannerTask,
        due: Date,
        calendar _: Calendar
    ) -> Bool {
        guard let scheduled = task.scheduled else {
            return false
        }

        return due > scheduled
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
