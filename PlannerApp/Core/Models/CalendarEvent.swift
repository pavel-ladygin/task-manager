import Foundation
import SwiftData

enum CalendarEventRecurrence: String, CaseIterable, Codable, Hashable, Identifiable {
    case none, daily, weekdays, weekly, biweekly, monthly, yearly
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: "Без повтора"
        case .daily: "Каждый день"
        case .weekdays: "По будням"
        case .weekly: "Каждую неделю"
        case .biweekly: "Через неделю"
        case .monthly: "Раз в месяц"
        case .yearly: "Раз в год"
        }
    }
}

enum CalendarEventReminder: Int, CaseIterable, Codable, Hashable, Identifiable {
    case none = -1, atStart = 0, fiveMinutes = 5, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .none: "Без напоминания"
        case .atStart: "В момент начала"
        case .fiveMinutes: "За 5 минут"
        case .fifteenMinutes: "За 15 минут"
        case .thirtyMinutes: "За 30 минут"
        case .oneHour: "За час"
        }
    }
}

@Model final class CalendarEvent {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var start: Date = Date.now
    var end: Date = Date.now.addingTimeInterval(1800)
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var recurrenceRawValue: String = CalendarEventRecurrence.none.rawValue
    var recurrenceEndDate: Date?
    var reminderRawValue: Int = CalendarEventReminder.fifteenMinutes.rawValue
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var project: PlannerSchemaV2.Project?

    init(id: UUID = UUID(), title: String, notes: String = "", start: Date,
         end: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
         recurrence: CalendarEventRecurrence = .none, recurrenceEndDate: Date? = nil,
         reminder: CalendarEventReminder = .fifteenMinutes, project: PlannerSchemaV2.Project? = nil,
         createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.title = title; self.notes = notes; self.start = start; self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier; self.recurrenceRawValue = recurrence.rawValue
        self.recurrenceEndDate = recurrenceEndDate; self.reminderRawValue = reminder.rawValue
        self.project = project; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Wire-format convenience initializer used by backup/sync importers.
    convenience init(id: UUID = UUID(), title: String, notes: String = "", start: Date, end: Date,
                     timeZoneIdentifier: String = TimeZone.current.identifier, recurrenceRawValue: String,
                     recurrenceEndDate: Date? = nil, reminder: CalendarEventReminder = .fifteenMinutes,
                     project: PlannerSchemaV2.Project? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.init(id: id, title: title, notes: notes, start: start, end: end,
                  timeZoneIdentifier: timeZoneIdentifier,
                  recurrence: CalendarEventRecurrence(rawValue: recurrenceRawValue) ?? .none,
                  recurrenceEndDate: recurrenceEndDate, reminder: reminder, project: project,
                  createdAt: createdAt, updatedAt: updatedAt)
    }

    var recurrence: CalendarEventRecurrence {
        get { CalendarEventRecurrence(rawValue: recurrenceRawValue) ?? .none }
        set { recurrenceRawValue = newValue.rawValue }
    }
    var reminder: CalendarEventReminder {
        get { CalendarEventReminder(rawValue: reminderRawValue) ?? .fifteenMinutes }
        set { reminderRawValue = newValue.rawValue }
    }
}

@Model final class CalendarEventException {
    @Attribute(.unique) var id: UUID = UUID()
    var eventID: UUID = UUID()
    var occurrenceDate: Date = Date.now
    var isSkipped: Bool = false
    var titleOverride: String?
    var notesOverride: String?
    var startOverride: Date?
    var endOverride: Date?
    var timeZoneIdentifierOverride: String?
    var reminderRawValueOverride: Int?
    /// Distinguishes “inherit project” from an explicit nil project.
    var projectOverrideSet: Bool = false
    var project: PlannerSchemaV2.Project?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(id: UUID = UUID(), eventID: UUID, occurrenceDate: Date, isDeleted: Bool = false,
         titleOverride: String? = nil, notesOverride: String? = nil, startOverride: Date? = nil,
         endOverride: Date? = nil, timeZoneIdentifierOverride: String? = nil,
         reminderOverride: CalendarEventReminder? = nil, projectOverrideSet: Bool = false,
         project: PlannerSchemaV2.Project? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.eventID = eventID; self.occurrenceDate = occurrenceDate; self.isSkipped = isDeleted
        self.titleOverride = titleOverride; self.notesOverride = notesOverride; self.startOverride = startOverride
        self.endOverride = endOverride; self.timeZoneIdentifierOverride = timeZoneIdentifierOverride
        self.reminderRawValueOverride = reminderOverride?.rawValue; self.projectOverrideSet = projectOverrideSet
        self.project = project; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
