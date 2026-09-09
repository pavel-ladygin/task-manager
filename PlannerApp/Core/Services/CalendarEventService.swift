import Foundation
import SwiftData

struct CalendarEventOccurrence: Identifiable {
    let eventID: UUID
    let occurrenceDate: Date
    let start: Date
    let end: Date
    let title: String
    let notes: String
    let project: PlannerSchemaV2.Project?
    let reminder: CalendarEventReminder
    let isException: Bool
    var id: String { CalendarEventService.occurrenceKey(eventID: eventID, occurrenceDate: occurrenceDate) }
}

enum CalendarEventServiceError: LocalizedError, Equatable {
    case emptyTitle
    case invalidRange
    case invalidRecurrenceEnd
    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Укажите название события."
        case .invalidRange: "Время окончания должно быть позже времени начала."
        case .invalidRecurrenceEnd: "Дата окончания повтора должна быть не раньше начала события."
        }
    }
}

@MainActor enum CalendarEventService {
    static func validate(title: String, start: Date, end: Date, recurrenceEndDate: Date? = nil) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarEventServiceError.emptyTitle }
        guard end > start else { throw CalendarEventServiceError.invalidRange }
        guard recurrenceEndDate == nil || recurrenceEndDate! >= start else { throw CalendarEventServiceError.invalidRecurrenceEnd }
    }

    @discardableResult
    static func create(title: String, notes: String = "", start: Date, end: Date,
                       timeZoneIdentifier: String = TimeZone.current.identifier,
                       recurrence: CalendarEventRecurrence = .none, recurrenceEndDate: Date? = nil,
                       reminder: CalendarEventReminder = .fifteenMinutes, project: Project? = nil,
                       context: ModelContext) throws -> CalendarEvent {
        try validate(title: title, start: start, end: end, recurrenceEndDate: recurrenceEndDate)
        let event = CalendarEvent(title: title, notes: notes, start: start, end: end,
                                  timeZoneIdentifier: timeZoneIdentifier, recurrence: recurrence,
                                  recurrenceEndDate: recurrenceEndDate, reminder: reminder, project: project)
        context.insert(event)
        try SyncService.enqueueUpsert(event: event, context: context)
        try context.save()
        NotificationService.rescheduleNotifications(for: event, exceptions: [])
        return event
    }

    static func update(_ event: CalendarEvent, title: String, notes: String, start: Date, end: Date,
                       timeZoneIdentifier: String, recurrence: CalendarEventRecurrence,
                       recurrenceEndDate: Date?, reminder: CalendarEventReminder, project: Project?,
                       context: ModelContext) throws {
        try validate(title: title, start: start, end: end, recurrenceEndDate: recurrenceEndDate)
        let scheduleChanged = event.start != start
            || event.end != end
            || event.timeZoneIdentifier != timeZoneIdentifier
            || event.recurrence != recurrence
            || event.recurrenceEndDate != recurrenceEndDate
        if scheduleChanged {
            let staleExceptions = try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.eventID == event.id }
            for exception in staleExceptions {
                try SyncService.enqueueDelete(type: .calendarEventException, entityID: exception.id, context: context)
                context.delete(exception)
            }
        }
        event.title = title; event.notes = notes; event.start = start; event.end = end
        event.timeZoneIdentifier = timeZoneIdentifier; event.recurrence = recurrence
        event.recurrenceEndDate = recurrenceEndDate; event.reminder = reminder; event.project = project
        event.updatedAt = .now
        try SyncService.enqueueUpsert(event: event, context: context)
        try context.save()
        let exceptions = try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.eventID == event.id }
        NotificationService.rescheduleNotifications(for: event, exceptions: exceptions)
    }

    static func deleteSeries(_ event: CalendarEvent, context: ModelContext) throws {
        NotificationService.cancelNotifications(for: event)
        let id = event.id
        let exceptions = try context.fetch(FetchDescriptor<CalendarEventException>())
            .filter { $0.eventID == id }
        for exception in exceptions {
            try SyncService.enqueueDelete(type: .calendarEventException, entityID: exception.id, context: context)
            context.delete(exception)
        }
        try SyncService.enqueueDelete(type: .calendarEvent, entityID: event.id, context: context)
        context.delete(event); try context.save()
    }

    static func deleteOccurrence(of event: CalendarEvent, on occurrenceDate: Date, context: ModelContext) throws {
        let exception = try exception(for: event, occurrenceDate: occurrenceDate, context: context)
        exception.isSkipped = true; exception.updatedAt = .now
        try SyncService.enqueueUpsert(exception: exception, context: context)
        try context.save()
        let exceptions = try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.eventID == event.id }
        NotificationService.rescheduleNotifications(for: event, exceptions: exceptions)
    }

    /// Applies edits to one generated occurrence while preserving the series.
    /// `projectOverrideSet` must be true when the occurrence intentionally has
    /// no project; false means it inherits the series project.
    static func updateOccurrence(of event: CalendarEvent, on occurrenceDate: Date,
                                 title: String? = nil, notes: String? = nil,
                                 start: Date? = nil, end: Date? = nil,
                                 reminder: CalendarEventReminder? = nil,
                                 projectOverrideSet: Bool = false, project: Project? = nil,
                                 context: ModelContext) throws {
        let currentStart = start ?? occurrenceDate
        let currentEnd = end ?? currentStart.addingTimeInterval(event.end.timeIntervalSince(event.start))
        try validate(title: title ?? event.title, start: currentStart, end: currentEnd)
        let exception = try exception(for: event, occurrenceDate: occurrenceDate, context: context)
        exception.isSkipped = false; exception.titleOverride = title; exception.notesOverride = notes
        exception.startOverride = start; exception.endOverride = end
        exception.reminderRawValueOverride = reminder?.rawValue
        exception.projectOverrideSet = projectOverrideSet; exception.project = project
        exception.updatedAt = .now
        try SyncService.enqueueUpsert(exception: exception, context: context)
        try context.save()
        let exceptions = try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.eventID == event.id }
        NotificationService.rescheduleNotifications(for: event, exceptions: exceptions)
    }

    @discardableResult
    static func exception(for event: CalendarEvent, occurrenceDate: Date, context: ModelContext) throws -> CalendarEventException {
        let targetKey = occurrenceTimestamp(occurrenceDate)
        if let existing = try context.fetch(FetchDescriptor<CalendarEventException>()).first(where: {
            $0.eventID == event.id && occurrenceTimestamp($0.occurrenceDate) == targetKey
        }) { return existing }
        let result = CalendarEventException(eventID: event.id, occurrenceDate: occurrenceDate)
        context.insert(result)
        try SyncService.enqueueUpsert(exception: result, context: context)
        return result
    }

    static func unlink(project: Project, context: ModelContext) throws {
        let events = try context.fetch(FetchDescriptor<CalendarEvent>()).filter { $0.project?.id == project.id }
        events.forEach { $0.project = nil; $0.updatedAt = .now }
        let exceptions = try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.project?.id == project.id }
        exceptions.forEach { $0.project = nil; $0.updatedAt = .now }
        for event in events { try SyncService.enqueueUpsert(event: event, context: context) }
        for exception in exceptions { try SyncService.enqueueUpsert(exception: exception, context: context) }
        try context.save()
    }

    static func occurrences(for event: CalendarEvent, from lowerBound: Date, to upperBound: Date,
                           exceptions: [CalendarEventException] = [], calendar: Calendar? = nil) -> [CalendarEventOccurrence] {
        guard upperBound > lowerBound, event.end > event.start else { return [] }
        var recurrenceCalendar = calendar ?? Calendar(identifier: .gregorian)
        recurrenceCalendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        let duration = event.end.timeIntervalSince(event.start)
        var matching: [Int64: CalendarEventException] = [:]
        for exception in exceptions where exception.eventID == event.id {
            let key = occurrenceTimestamp(exception.occurrenceDate)
            if let current = matching[key], current.updatedAt >= exception.updatedAt { continue }
            matching[key] = exception
        }
        var dates: [Date] = []
        if event.recurrence == .none { dates = [event.start] }
        else {
            for sequence in 0...10_000 {
                guard let date = occurrenceDate(event: event, sequence: sequence, calendar: recurrenceCalendar) else { break }
                if let end = event.recurrenceEndDate, date > end { break }
                if date > upperBound { break }
                if date >= lowerBound.addingTimeInterval(-duration) { dates.append(date) }
            }
        }
        return dates.compactMap { occurrenceDate in
            let exception = matching[occurrenceTimestamp(occurrenceDate)]
            if exception?.isSkipped == true { return nil }
            let start = exception?.startOverride ?? occurrenceDate
            let end = exception?.endOverride ?? start.addingTimeInterval(duration)
            guard end > lowerBound && start < upperBound else { return nil }
            let project = exception?.projectOverrideSet == true ? exception?.project : event.project
            let reminder = exception.flatMap { $0.reminderRawValueOverride.flatMap(CalendarEventReminder.init(rawValue:)) } ?? event.reminder
            return CalendarEventOccurrence(eventID: event.id, occurrenceDate: occurrenceDate, start: start, end: end,
                                           title: exception?.titleOverride ?? event.title,
                                           notes: exception?.notesOverride ?? event.notes,
                                           project: project, reminder: reminder,
                                           isException: exception != nil)
        }
    }

    private static func occurrenceDate(event: CalendarEvent, sequence: Int, calendar: Calendar) -> Date? {
        let recurrence: TaskRecurrence
        switch event.recurrence {
        case .none: recurrence = .none
        case .daily: recurrence = .daily
        case .weekdays: recurrence = .weekdays
        case .weekly: recurrence = .weekly
        case .biweekly: recurrence = .biweekly
        case .monthly: recurrence = .monthly
        case .yearly: recurrence = .yearly
        }
        return RecurrenceService.occurrenceDate(recurrence: recurrence, anchor: event.start, sequence: sequence, calendar: calendar)
    }

    nonisolated static func occurrenceKey(eventID: UUID, occurrenceDate: Date) -> String {
        "\(eventID.uuidString):\(occurrenceTimestamp(occurrenceDate))"
    }

    nonisolated private static func occurrenceTimestamp(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
