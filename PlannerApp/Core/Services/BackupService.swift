import Foundation
import SwiftData

struct PlannerBackupDTO: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let tasks: [TaskBackupDTO]
    let projects: [ProjectBackupDTO]
    let tags: [TagBackupDTO]
    let settings: SettingsBackupDTO?
    // Optional in the wire format for backwards compatibility with v1/v2 backups.
    // The custom decoder below normalizes a missing key to an empty collection.
    let calendarEvents: [CalendarEventBackupDTO]
    let calendarEventExceptions: [CalendarEventExceptionBackupDTO]
    #if os(iOS)
    let habits: [Habit]?
    #endif
}

struct CalendarEventBackupDTO: Codable {
    let id: UUID
    let title: String
    let notes: String
    let start: Date
    let end: Date
    let timeZoneIdentifier: String
    let recurrenceRawValue: String
    let recurrenceEndDate: Date?
    let projectID: UUID?
    let reminderRawValue: Int
    let createdAt: Date
    let updatedAt: Date
}

struct CalendarEventExceptionBackupDTO: Codable {
    let id: UUID
    let eventID: UUID
    let occurrenceDate: Date
    let isDeleted: Bool
    let titleOverride: String?
    let notesOverride: String?
    let startOverride: Date?
    let endOverride: Date?
    let timeZoneIdentifierOverride: String?
    let reminderRawValueOverride: Int?
    let projectOverrideSet: Bool?
    let projectID: UUID?
    let createdAt: Date
    let updatedAt: Date
}

extension PlannerBackupDTO {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, tasks, projects, tags, settings
        #if os(iOS)
        case habits
        #endif
        case calendarEvents, calendarEventExceptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        tasks = try c.decode([TaskBackupDTO].self, forKey: .tasks)
        projects = try c.decode([ProjectBackupDTO].self, forKey: .projects)
        tags = try c.decode([TagBackupDTO].self, forKey: .tags)
        settings = try c.decodeIfPresent(SettingsBackupDTO.self, forKey: .settings)
        calendarEvents = try c.decodeIfPresent([CalendarEventBackupDTO].self, forKey: .calendarEvents) ?? []
        calendarEventExceptions = try c.decodeIfPresent([CalendarEventExceptionBackupDTO].self, forKey: .calendarEventExceptions) ?? []
        #if os(iOS)
        habits = try c.decodeIfPresent([Habit].self, forKey: .habits)
        #endif
    }
}

struct TaskBackupDTO: Codable {
    let id: UUID
    let title: String
    let notes: String
    let status: String
    let priority: String
    let recurrence: String?
    let recurrenceSeriesID: UUID?
    let recurrenceAnchorDate: Date?
    let recurrenceSequence: Int?
    let showInKanban: Bool?
    let scheduled: Date?
    let due: Date?
    let createdAt: Date
    let updatedAt: Date?
    let completedAt: Date?
    let projectID: UUID?
    let tagIDs: [UUID]
    let checklistItems: [ChecklistItemBackupDTO]
    let manualOrder: Double
}

struct ProjectBackupDTO: Codable {
    let id: UUID
    let title: String
    let status: String
    let color: String?
    let deadline: Date?
    let notes: String
    let createdAt: Date
    let updatedAt: Date?
}

struct TagBackupDTO: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
}

struct ChecklistItemBackupDTO: Codable {
    let id: UUID
    let title: String
    let isDone: Bool
    let order: Int
}

struct SettingsBackupDTO: Codable {
    let id: UUID
    let theme: String
    let hideEmptyKanbanColumns: Bool
    let defaultReminderLeadMinutes: Int?
    let createdAt: Date
    let updatedAt: Date?
}

enum BackupError: LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidJSON
    case validationFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Неподдерживаемая версия схемы резервной копии: \(version)."
        case .invalidJSON:
            "Выбранный файл не является корректной JSON-резервной копией планировщика."
        case .validationFailed(let message):
            "Проверка резервной копии не пройдена: \(message)"
        case .saveFailed(let message):
            "Не удалось сохранить импортированную резервную копию: \(message)"
        }
    }
}

@MainActor
enum BackupService {
    private static let supportedSchemaVersion = 3
    private static let readableSchemaVersions: Set<Int> = [1, 2, 3]

    private struct BackupVersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func exportData(context: ModelContext) throws -> Data {
        let tasks = try context.fetch(FetchDescriptor<PlannerTask>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        let projects = try context.fetch(FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        let tags = try context.fetch(FetchDescriptor<Tag>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        let settings = try context.fetch(FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )).first
        let calendarEvents = try context.fetch(FetchDescriptor<CalendarEvent>())
        let calendarEventExceptions = try context.fetch(FetchDescriptor<CalendarEventException>())

        #if os(iOS)
        let backup = PlannerBackupDTO(
            schemaVersion: supportedSchemaVersion,
            exportedAt: .now,
            tasks: tasks.map(taskDTO),
            projects: projects.map(projectDTO),
            tags: tags.map(tagDTO),
            settings: settings.map(settingsDTO),
            calendarEvents: calendarEvents.map(calendarEventDTO),
            calendarEventExceptions: calendarEventExceptions.map(calendarEventExceptionDTO),
            habits: HabitStore.persistedHabits()
        )
        #else
        let backup = PlannerBackupDTO(
            schemaVersion: supportedSchemaVersion,
            exportedAt: .now,
            tasks: tasks.map(taskDTO),
            projects: projects.map(projectDTO),
            tags: tags.map(tagDTO),
            settings: settings.map(settingsDTO),
            calendarEvents: calendarEvents.map(calendarEventDTO),
            calendarEventExceptions: calendarEventExceptions.map(calendarEventExceptionDTO)
        )
        #endif

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func importData(_ data: Data, context: ModelContext) throws {
        let backup = try decodeBackup(data)
        try validate(backup)

        let restoredProjects = Dictionary(uniqueKeysWithValues: backup.projects.map { dto in
            let project = Project(
                id: dto.id,
                title: normalizedTitle(dto.title),
                status: ProjectStatus(rawValue: dto.status) ?? .active,
                color: ProjectColorPreset(rawValue: dto.color ?? ProjectColorPreset.ocean.rawValue) ?? .ocean,
                deadline: dto.deadline,
                notes: dto.notes,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt ?? dto.createdAt
            )
            return (dto.id, project)
        })

        let restoredTags = Dictionary(uniqueKeysWithValues: backup.tags.map { dto in
            let tag = Tag(
                id: dto.id,
                title: normalizedTitle(dto.title),
                createdAt: dto.createdAt
            )
            return (dto.id, tag)
        })

        let restoredSettings = backup.settings.map { dto in
            AppSettings(
                id: dto.id,
                theme: dto.theme,
                hideEmptyKanbanColumns: dto.hideEmptyKanbanColumns,
                defaultReminderLeadMinutes: dto.defaultReminderLeadMinutes ?? 15,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt ?? dto.createdAt
            )
        }

        let restoredTasks = backup.tasks.map { dto in
            let checklistItems = dto.checklistItems.map { itemDTO in
                ChecklistItem(
                    id: itemDTO.id,
                    title: normalizedTitle(itemDTO.title),
                    isDone: itemDTO.isDone,
                    order: itemDTO.order
                )
            }

            return PlannerTask(
                id: dto.id,
                title: normalizedTitle(dto.title),
                notes: dto.notes,
                status: TaskStatus(rawValue: dto.status) ?? .inbox,
                priority: Priority(rawValue: dto.priority) ?? .none,
                recurrence: TaskRecurrence(rawValue: dto.recurrence ?? TaskRecurrence.none.rawValue) ?? .none,
                recurrenceSeriesID: dto.recurrenceSeriesID,
                recurrenceAnchorDate: dto.recurrenceAnchorDate,
                recurrenceSequence: dto.recurrenceSequence ?? 0,
                showInKanban: dto.showInKanban ?? true,
                scheduled: dto.scheduled,
                due: dto.due,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt ?? dto.createdAt,
                completedAt: normalizedCompletedAt(for: dto),
                project: dto.projectID.flatMap { restoredProjects[$0] },
                tags: dto.tagIDs.compactMap { restoredTags[$0] },
                checklistItems: checklistItems,
                manualOrder: dto.manualOrder
            )
        }

        let restoredEvents = backup.calendarEvents.map { dto in
            CalendarEvent(id: dto.id, title: normalizedTitle(dto.title), notes: dto.notes,
                          start: dto.start, end: dto.end,
                          timeZoneIdentifier: dto.timeZoneIdentifier,
                          recurrence: CalendarEventRecurrence(rawValue: dto.recurrenceRawValue) ?? .none,
                          recurrenceEndDate: dto.recurrenceEndDate,
                          reminder: CalendarEventReminder(rawValue: dto.reminderRawValue) ?? .fifteenMinutes,
                          project: dto.projectID.flatMap { restoredProjects[$0] },
                          createdAt: dto.createdAt, updatedAt: dto.updatedAt)
        }
        let restoredEventIDs = Set(restoredEvents.map(\.id))
        let restoredExceptions = backup.calendarEventExceptions.compactMap { dto -> CalendarEventException? in
            guard restoredEventIDs.contains(dto.eventID) else { return nil }
            return CalendarEventException(id: dto.id, eventID: dto.eventID, occurrenceDate: dto.occurrenceDate,
                                          isDeleted: dto.isDeleted, titleOverride: dto.titleOverride,
                                          notesOverride: dto.notesOverride, startOverride: dto.startOverride,
                                          endOverride: dto.endOverride,
                                          timeZoneIdentifierOverride: dto.timeZoneIdentifierOverride,
                                          reminderOverride: dto.reminderRawValueOverride.flatMap(CalendarEventReminder.init(rawValue:)),
                                          projectOverrideSet: dto.projectOverrideSet ?? false,
                                          project: dto.projectID.flatMap { restoredProjects[$0] },
                                          createdAt: dto.createdAt, updatedAt: dto.updatedAt)
        }

        do {
            let existingTasks = try context.fetch(FetchDescriptor<PlannerTask>())
            let existingChecklistItems = try context.fetch(FetchDescriptor<ChecklistItem>())
            let existingProjects = try context.fetch(FetchDescriptor<Project>())
            let existingTags = try context.fetch(FetchDescriptor<Tag>())
            let existingSettings = try context.fetch(FetchDescriptor<AppSettings>())
            let existingEvents = try context.fetch(FetchDescriptor<CalendarEvent>())
            let existingExceptions = try context.fetch(FetchDescriptor<CalendarEventException>())

            existingTasks.forEach { context.delete($0) }
            existingChecklistItems.forEach { context.delete($0) }
            existingProjects.forEach { context.delete($0) }
            existingTags.forEach { context.delete($0) }
            existingSettings.forEach { context.delete($0) }
            existingExceptions.forEach { context.delete($0) }
            existingEvents.forEach { context.delete($0) }

            restoredProjects.values.forEach { context.insert($0) }
            restoredTags.values.forEach { context.insert($0) }

            if let restoredSettings {
                context.insert(restoredSettings)
            }

            for task in restoredTasks {
                task.checklistItems.forEach(context.insert)
                context.insert(task)
            }
            restoredEvents.forEach { context.insert($0) }
            restoredExceptions.forEach { context.insert($0) }

            try context.save()
            #if os(iOS)
            HabitStore.replacePersistedHabits(backup.habits ?? [])
            #endif
        } catch let error as BackupError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw BackupError.saveFailed(error.localizedDescription)
        }
    }

    static func validate(_ backup: PlannerBackupDTO) throws {
        guard readableSchemaVersions.contains(backup.schemaVersion) else {
            throw BackupError.unsupportedSchemaVersion(backup.schemaVersion)
        }

        let projectIDs = try uniqueIDs(backup.projects.map(\.id), entityName: "проектах")
        let tagIDs = try uniqueIDs(backup.tags.map(\.id), entityName: "тегах")
        _ = try uniqueIDs(backup.tasks.map(\.id), entityName: "задачах")
        let eventIDs = try uniqueIDs(backup.calendarEvents.map(\.id), entityName: "событиях календаря")
        _ = try uniqueIDs(backup.calendarEventExceptions.map(\.id), entityName: "исключениях календаря")

        for project in backup.projects {
            try validateTitle(project.title, entityName: "проекта")
            guard ProjectStatus(rawValue: project.status) != nil else {
                throw BackupError.validationFailed("Неизвестный статус проекта: \(project.status).")
            }

            if let color = project.color,
               ProjectColorPreset(rawValue: color) == nil {
                throw BackupError.validationFailed("Неизвестный цвет проекта: \(color).")
            }
        }

        for tag in backup.tags {
            try validateTitle(tag.title, entityName: "тега")
        }

        #if os(iOS)
        for habit in backup.habits ?? [] {
            try validateTitle(habit.title, entityName: "привычки")
        }
        #endif

        for task in backup.tasks {
            try validateTitle(task.title, entityName: "задачи")

            guard TaskStatus(rawValue: task.status) != nil else {
                throw BackupError.validationFailed("Неизвестный статус задачи: \(task.status).")
            }

            guard Priority(rawValue: task.priority) != nil else {
                throw BackupError.validationFailed("Неизвестный приоритет задачи: \(task.priority).")
            }

            if let recurrence = task.recurrence,
               TaskRecurrence(rawValue: recurrence) == nil {
                throw BackupError.validationFailed("Неизвестная периодичность задачи: \(recurrence).")
            }

            if let projectID = task.projectID, !projectIDs.contains(projectID) {
                throw BackupError.validationFailed("Задача «\(task.title)» ссылается на отсутствующий проект.")
            }

            for tagID in task.tagIDs where !tagIDs.contains(tagID) {
                throw BackupError.validationFailed("Задача «\(task.title)» ссылается на отсутствующий тег.")
            }

            _ = try uniqueIDs(task.checklistItems.map(\.id), entityName: "пунктах чеклиста")

            for item in task.checklistItems {
                try validateTitle(item.title, entityName: "пункта чеклиста")
            }
        }

        for event in backup.calendarEvents {
            try validateTitle(event.title, entityName: "события календаря")
            guard event.end > event.start else {
                throw BackupError.validationFailed("Событие «\(event.title)» заканчивается не позже начала.")
            }
            guard CalendarEventRecurrence(rawValue: event.recurrenceRawValue) != nil else {
                throw BackupError.validationFailed("Неизвестная периодичность события «\(event.title)».")
            }
            guard CalendarEventReminder(rawValue: event.reminderRawValue) != nil else {
                throw BackupError.validationFailed("Неизвестное напоминание события «\(event.title)».")
            }
            if let projectID = event.projectID, !projectIDs.contains(projectID) {
                throw BackupError.validationFailed("Событие «\(event.title)» ссылается на отсутствующий проект.")
            }
        }
        for exception in backup.calendarEventExceptions {
            guard eventIDs.contains(exception.eventID) else {
                throw BackupError.validationFailed("Исключение календаря ссылается на отсутствующее событие.")
            }
            if let start = exception.startOverride, let end = exception.endOverride, end <= start {
                throw BackupError.validationFailed("Изменённое событие календаря заканчивается не позже начала.")
            }
            if let projectID = exception.projectID, !projectIDs.contains(projectID) {
                throw BackupError.validationFailed("Исключение календаря ссылается на отсутствующий проект.")
            }
        }

        let checklistIDs = backup.tasks.flatMap { task in
            task.checklistItems.map(\.id)
        }
        _ = try uniqueIDs(checklistIDs, entityName: "пунктах чеклиста")

        if let settings = backup.settings,
           AppTheme(rawValue: settings.theme) == nil {
            throw BackupError.validationFailed("Неизвестная тема настроек: \(settings.theme).")
        }

        if let reminderLead = backup.settings?.defaultReminderLeadMinutes,
           reminderLead < 0 {
            throw BackupError.validationFailed("Время напоминания заранее не может быть отрицательным.")
        }
    }

    private static func decodeBackup(_ data: Data) throws -> PlannerBackupDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let envelope = try decoder.decode(BackupVersionEnvelope.self, from: data)
            guard readableSchemaVersions.contains(envelope.schemaVersion) else {
                throw BackupError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            return try decoder.decode(PlannerBackupDTO.self, from: data)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalidJSON
        }
    }

    private static func taskDTO(_ task: PlannerTask) -> TaskBackupDTO {
        TaskBackupDTO(
            id: task.id,
            title: task.title,
            notes: task.notes,
            status: task.status.rawValue,
            priority: task.priority.rawValue,
            recurrence: task.recurrence.rawValue,
            recurrenceSeriesID: task.recurrenceSeriesID,
            recurrenceAnchorDate: task.recurrenceAnchorDate,
            recurrenceSequence: task.recurrenceSequence,
            showInKanban: task.showInKanban,
            scheduled: task.scheduled,
            due: task.due,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt,
            projectID: task.project?.id,
            tagIDs: task.tags.map(\.id),
            checklistItems: task.checklistItems
                .sorted { $0.order < $1.order }
                .map(checklistItemDTO),
            manualOrder: task.manualOrder
        )
    }

    private static func projectDTO(_ project: Project) -> ProjectBackupDTO {
        ProjectBackupDTO(
            id: project.id,
            title: project.title,
            status: project.status.rawValue,
            color: project.colorPreset.rawValue,
            deadline: project.deadline,
            notes: project.notes,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    private static func tagDTO(_ tag: Tag) -> TagBackupDTO {
        TagBackupDTO(
            id: tag.id,
            title: tag.title,
            createdAt: tag.createdAt
        )
    }

    private static func checklistItemDTO(_ item: ChecklistItem) -> ChecklistItemBackupDTO {
        ChecklistItemBackupDTO(
            id: item.id,
            title: item.title,
            isDone: item.isDone,
            order: item.order
        )
    }

    private static func settingsDTO(_ settings: AppSettings) -> SettingsBackupDTO {
        SettingsBackupDTO(
            id: settings.id,
            theme: settings.theme,
            hideEmptyKanbanColumns: settings.hideEmptyKanbanColumns,
            defaultReminderLeadMinutes: settings.defaultReminderLeadMinutes,
            createdAt: settings.createdAt,
            updatedAt: settings.updatedAt
        )
    }

    private static func calendarEventDTO(_ event: CalendarEvent) -> CalendarEventBackupDTO {
        CalendarEventBackupDTO(id: event.id, title: event.title, notes: event.notes,
                               start: event.start, end: event.end,
                               timeZoneIdentifier: event.timeZoneIdentifier,
                               recurrenceRawValue: event.recurrenceRawValue,
                               recurrenceEndDate: event.recurrenceEndDate,
                               projectID: event.project?.id,
                               reminderRawValue: event.reminderRawValue,
                               createdAt: event.createdAt, updatedAt: event.updatedAt)
    }

    private static func calendarEventExceptionDTO(_ exception: CalendarEventException) -> CalendarEventExceptionBackupDTO {
        CalendarEventExceptionBackupDTO(id: exception.id, eventID: exception.eventID,
                                        occurrenceDate: exception.occurrenceDate,
                                        isDeleted: exception.isSkipped,
                                        titleOverride: exception.titleOverride,
                                        notesOverride: exception.notesOverride,
                                        startOverride: exception.startOverride,
                                        endOverride: exception.endOverride,
                                        timeZoneIdentifierOverride: exception.timeZoneIdentifierOverride,
                                        reminderRawValueOverride: exception.reminderRawValueOverride,
                                        projectOverrideSet: exception.projectOverrideSet,
                                        projectID: exception.project?.id,
                                        createdAt: exception.createdAt, updatedAt: exception.updatedAt)
    }

    private static func normalizedCompletedAt(for task: TaskBackupDTO) -> Date? {
        guard TaskStatus(rawValue: task.status) == .done else {
            return nil
        }

        return task.completedAt ?? task.updatedAt ?? task.createdAt
    }

    private static func validateTitle(_ title: String, entityName: String) throws {
        guard !normalizedTitle(title).isEmpty else {
            throw BackupError.validationFailed("У \(entityName) пустое название.")
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueIDs(_ ids: [UUID], entityName: String) throws -> Set<UUID> {
        var uniqueIDs = Set<UUID>()

        for id in ids {
            guard uniqueIDs.insert(id).inserted else {
                throw BackupError.validationFailed("Повторяющийся ID в \(entityName): \(id.uuidString).")
            }
        }

        return uniqueIDs
    }
}
