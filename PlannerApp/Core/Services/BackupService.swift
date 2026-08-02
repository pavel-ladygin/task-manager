import Foundation
import SwiftData

struct PlannerBackupDTO: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let tasks: [TaskBackupDTO]
    let projects: [ProjectBackupDTO]
    let tags: [TagBackupDTO]
    let settings: SettingsBackupDTO?
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
    private static let supportedSchemaVersion = 2
    private static let readableSchemaVersions: Set<Int> = [1, 2]

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

        let backup = PlannerBackupDTO(
            schemaVersion: supportedSchemaVersion,
            exportedAt: .now,
            tasks: tasks.map(taskDTO),
            projects: projects.map(projectDTO),
            tags: tags.map(tagDTO),
            settings: settings.map(settingsDTO)
        )

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

        do {
            let existingTasks = try context.fetch(FetchDescriptor<PlannerTask>())
            let existingChecklistItems = try context.fetch(FetchDescriptor<ChecklistItem>())
            let existingProjects = try context.fetch(FetchDescriptor<Project>())
            let existingTags = try context.fetch(FetchDescriptor<Tag>())
            let existingSettings = try context.fetch(FetchDescriptor<AppSettings>())

            existingTasks.forEach { context.delete($0) }
            existingChecklistItems.forEach { context.delete($0) }
            existingProjects.forEach { context.delete($0) }
            existingTags.forEach { context.delete($0) }
            existingSettings.forEach { context.delete($0) }

            restoredProjects.values.forEach { context.insert($0) }
            restoredTags.values.forEach { context.insert($0) }

            if let restoredSettings {
                context.insert(restoredSettings)
            }

            for task in restoredTasks {
                task.checklistItems.forEach(context.insert)
                context.insert(task)
            }

            try context.save()
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
