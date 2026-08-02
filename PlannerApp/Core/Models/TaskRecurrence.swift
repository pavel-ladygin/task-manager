import Foundation

enum TaskRecurrence: String, CaseIterable, Codable, Hashable, Identifiable {
    case none
    case daily
    case weekdays
    case weekly
    case biweekly
    case monthly
    case yearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "Без повтора"
        case .daily:
            "Каждый день"
        case .weekdays:
            "По будням"
        case .weekly:
            "Каждую неделю"
        case .biweekly:
            "Через неделю"
        case .monthly:
            "Раз в месяц"
        case .yearly:
            "Раз в год"
        }
    }
}

enum RecurrenceCalculationError: LocalizedError {
    case missingAnchor
    case unableToCalculate

    var errorDescription: String? {
        switch self {
        case .missingAnchor:
            "Для повторяющейся задачи укажите дату планирования или срок."
        case .unableToCalculate:
            "Не удалось рассчитать следующую дату повторения."
        }
    }
}

enum RecurrenceService {
    static func nextOccurrence(
        recurrence: TaskRecurrence,
        anchor: Date,
        after date: Date,
        startingSequence: Int,
        calendar: Calendar = .current
    ) throws -> (date: Date, sequence: Int) {
        guard recurrence != .none else {
            throw RecurrenceCalculationError.unableToCalculate
        }

        var sequence = max(1, startingSequence)
        // The cap protects a corrupt series from an unbounded loop while still
        // covering more than 27 years of daily occurrences.
        while sequence <= 10_000 {
            if let candidate = occurrenceDate(
                recurrence: recurrence,
                anchor: anchor,
                sequence: sequence,
                calendar: calendar
            ), candidate > date {
                return (candidate, sequence)
            }
            sequence += 1
        }

        throw RecurrenceCalculationError.unableToCalculate
    }

    static func occurrenceDate(
        recurrence: TaskRecurrence,
        anchor: Date,
        sequence: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let sequence = max(0, sequence)
        switch recurrence {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: sequence, to: anchor)
        case .weekdays:
            return addingWeekdays(sequence, to: anchor, calendar: calendar)
        case .weekly:
            return calendar.date(byAdding: .day, value: sequence * 7, to: anchor)
        case .biweekly:
            return calendar.date(byAdding: .day, value: sequence * 14, to: anchor)
        case .monthly:
            return clampedDate(anchor: anchor, addingMonths: sequence, calendar: calendar)
        case .yearly:
            return clampedDate(anchor: anchor, addingYears: sequence, calendar: calendar)
        }
    }

    private static func addingWeekdays(
        _ count: Int,
        to anchor: Date,
        calendar: Calendar
    ) -> Date? {
        guard count > 0 else { return anchor }
        var result = anchor
        var remaining = count
        while remaining > 0 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: result) else { return nil }
            result = next
            let weekday = calendar.component(.weekday, from: result)
            if weekday != 1 && weekday != 7 {
                remaining -= 1
            }
        }
        return result
    }

    private static func clampedDate(
        anchor: Date,
        addingMonths months: Int,
        calendar: Calendar
    ) -> Date? {
        let anchorComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: anchor
        )
        guard
            let anchorYear = anchorComponents.year,
            let anchorMonth = anchorComponents.month,
            let anchorDay = anchorComponents.day
        else { return nil }

        let absoluteMonth = (anchorYear * 12) + (anchorMonth - 1) + months
        let year = absoluteMonth / 12
        let month = (absoluteMonth % 12) + 1
        return date(
            year: year,
            month: month,
            preferredDay: anchorDay,
            time: anchorComponents,
            calendar: calendar
        )
    }

    private static func clampedDate(
        anchor: Date,
        addingYears years: Int,
        calendar: Calendar
    ) -> Date? {
        let anchorComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: anchor
        )
        guard
            let anchorYear = anchorComponents.year,
            let month = anchorComponents.month,
            let day = anchorComponents.day
        else { return nil }

        return date(
            year: anchorYear + years,
            month: month,
            preferredDay: day,
            time: anchorComponents,
            calendar: calendar
        )
    }

    private static func date(
        year: Int,
        month: Int,
        preferredDay: Int,
        time: DateComponents,
        calendar: Calendar
    ) -> Date? {
        var firstDayComponents = DateComponents()
        firstDayComponents.calendar = calendar
        firstDayComponents.timeZone = calendar.timeZone
        firstDayComponents.year = year
        firstDayComponents.month = month
        firstDayComponents.day = 1
        guard
            let firstDay = calendar.date(from: firstDayComponents),
            let dayRange = calendar.range(of: .day, in: .month, for: firstDay)
        else { return nil }

        var components = firstDayComponents
        components.day = min(preferredDay, dayRange.count)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond
        return calendar.date(from: components)
    }
}
