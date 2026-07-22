import Foundation
import SwiftData

@MainActor
enum SyncService {
    private static let settingsEntityID = "app-settings"

    static func testConnection(settings: AppSettings, token: String) async throws -> SyncStatusResponse {
        try await makeClient(settings: settings, token: token).status()
    }

    static func bootstrap(context: ModelContext, settings: AppSettings, token: String) async throws -> SyncResult {
        let client = try makeClient(settings: settings, token: token)
        let items = try snapshotItems(context: context, settings: settings, includeTombstones: false)
        let response = try await client.bootstrap(SyncPushRequest(deviceID: settings.syncDeviceID, items: items))
        settings.syncLastCursor = response.serverCursor
        settings.syncLastSyncAt = .now
        try context.save()
        return SyncResult(pushed: response.accepted, ignored: response.ignored, pulled: 0, cursor: response.serverCursor)
    }

    static func syncNow(context: ModelContext, settings: AppSettings, token: String) async throws -> SyncResult {
        guard settings.syncEnabled else {
            throw SyncError.disabled
        }

        let client = try makeClient(settings: settings, token: token)
        let items = try snapshotItems(context: context, settings: settings, includeTombstones: true)
        let pushResponse = try await client.push(SyncPushRequest(deviceID: settings.syncDeviceID, items: items))
        try clearTombstones(context: context)

        let pullResponse = try await client.pull(cursor: settings.syncLastCursor)
        try apply(items: pullResponse.items, context: context, settings: settings)

        settings.syncLastCursor = max(pushResponse.serverCursor, pullResponse.serverCursor)
        settings.syncLastSyncAt = .now
        try context.save()

        return SyncResult(
            pushed: pushResponse.accepted,
            ignored: pushResponse.ignored,
            pulled: pullResponse.items.count,
            cursor: settings.syncLastCursor
        )
    }

    private static func makeClient(settings: AppSettings, token: String) throws -> SyncClient {
        guard let baseURL = URL(string: settings.syncServerURL), baseURL.scheme?.hasPrefix("http") == true else {
            throw SyncError.invalidServerURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.missingToken
        }
        guard !settings.syncCertificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.missingCertificateFingerprint
        }

        return SyncClient(
            baseURL: baseURL,
            token: token,
            certificateFingerprint: settings.syncCertificateFingerprint
        )
    }

    private static func snapshotItems(
        context: ModelContext,
        settings: AppSettings,
        includeTombstones: Bool
    ) throws -> [SyncItemDTO] {
        var items: [SyncItemDTO] = []
        let encoder = syncEncoder()

        let projects = try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)]))
        let tags = try context.fetch(FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.createdAt)]))
        let tasks = try context.fetch(FetchDescriptor<PlannerTask>(sortBy: [SortDescriptor(\.createdAt)]))

        for project in projects {
            items.append(try item(
                type: .project,
                entityID: project.id.uuidString,
                payload: projectDTO(project),
                updatedAt: project.updatedAt,
                deviceID: settings.syncDeviceID,
                encoder: encoder
            ))
        }

        for tag in tags {
            items.append(try item(
                type: .tag,
                entityID: tag.id.uuidString,
                payload: tagDTO(tag),
                updatedAt: tag.createdAt,
                deviceID: settings.syncDeviceID,
                encoder: encoder
            ))
        }

        items.append(try item(
            type: .settings,
            entityID: settingsEntityID,
            payload: settingsDTO(settings),
            updatedAt: settings.updatedAt,
            deviceID: settings.syncDeviceID,
            encoder: encoder
        ))

        for task in tasks {
            items.append(try item(
                type: .task,
                entityID: task.id.uuidString,
                payload: taskDTO(task),
                updatedAt: task.updatedAt,
                deviceID: settings.syncDeviceID,
                encoder: encoder
            ))
        }

        if includeTombstones {
            let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
            for tombstone in tombstones {
                guard let entityType = tombstone.syncEntityType else {
                    continue
                }
                items.append(SyncItemDTO(
                    entityType: entityType.rawValue,
                    entityID: tombstone.entityID.uuidString,
                    payloadJSON: nil,
                    clientUpdatedAt: tombstone.clientUpdatedAt,
                    serverUpdatedAt: nil,
                    deletedAt: tombstone.clientUpdatedAt,
                    version: 1,
                    sourceDeviceID: settings.syncDeviceID
                ))
            }
        }

        return items
    }

    private static func item<T: Encodable>(
        type: SyncEntityType,
        entityID: String,
        payload: T,
        updatedAt: Date,
        deviceID: String,
        encoder: JSONEncoder
    ) throws -> SyncItemDTO {
        let data = try encoder.encode(payload)
        return SyncItemDTO(
            entityType: type.rawValue,
            entityID: entityID,
            payloadJSON: String(data: data, encoding: .utf8),
            clientUpdatedAt: updatedAt,
            serverUpdatedAt: nil,
            deletedAt: nil,
            version: 1,
            sourceDeviceID: deviceID
        )
    }

    private static func apply(
        items: [SyncItemDTO],
        context: ModelContext,
        settings: AppSettings
    ) throws {
        let decoder = syncDecoder()

        for item in items where item.entityType != SyncEntityType.task.rawValue {
            try applyNonTask(item, context: context, settings: settings, decoder: decoder)
        }

        for item in items where item.entityType == SyncEntityType.task.rawValue {
            try applyTask(item, context: context, decoder: decoder)
        }
    }

    private static func applyNonTask(
        _ item: SyncItemDTO,
        context: ModelContext,
        settings: AppSettings,
        decoder: JSONDecoder
    ) throws {
        guard let type = SyncEntityType(rawValue: item.entityType) else {
            return
        }

        if item.deletedAt != nil {
            try applyDelete(type: type, entityID: item.entityID, clientUpdatedAt: item.clientUpdatedAt, context: context)
            return
        }

        guard let payloadData = item.payloadJSON?.data(using: .utf8) else {
            return
        }

        switch type {
        case .project:
            let dto = try decoder.decode(ProjectBackupDTO.self, from: payloadData)
            try upsertProject(dto, context: context)
        case .tag:
            let dto = try decoder.decode(TagBackupDTO.self, from: payloadData)
            try upsertTag(dto, context: context)
        case .settings:
            let dto = try decoder.decode(SettingsBackupDTO.self, from: payloadData)
            applySettings(dto, settings: settings)
        case .task:
            break
        }
    }

    private static func applyTask(
        _ item: SyncItemDTO,
        context: ModelContext,
        decoder: JSONDecoder
    ) throws {
        if item.deletedAt != nil {
            try applyDelete(type: .task, entityID: item.entityID, clientUpdatedAt: item.clientUpdatedAt, context: context)
            return
        }

        guard let payloadData = item.payloadJSON?.data(using: .utf8) else {
            return
        }

        let dto = try decoder.decode(TaskBackupDTO.self, from: payloadData)
        try upsertTask(dto, context: context)
    }

    private static func applyDelete(
        type: SyncEntityType,
        entityID: String,
        clientUpdatedAt: Date,
        context: ModelContext
    ) throws {
        guard let uuid = UUID(uuidString: entityID) else {
            return
        }

        switch type {
        case .task:
            if let task = try fetchTasks(context).first(where: { $0.id == uuid }),
               task.updatedAt <= clientUpdatedAt {
                NotificationService.cancelNotifications(for: task)
                task.checklistItems.forEach { context.delete($0) }
                context.delete(task)
            }
        case .project:
            if let project = try fetchProjects(context).first(where: { $0.id == uuid }),
               project.updatedAt <= clientUpdatedAt {
                let tasks = try fetchTasks(context)
                tasks.filter { $0.project?.id == project.id }.forEach { $0.project = nil }
                context.delete(project)
            }
        case .tag:
            if let tag = try fetchTags(context).first(where: { $0.id == uuid }) {
                let tasks = try fetchTasks(context)
                tasks.forEach { task in
                    task.tags.removeAll { $0.id == tag.id }
                }
                context.delete(tag)
            }
        case .settings:
            break
        }
    }

    private static func upsertProject(_ dto: ProjectBackupDTO, context: ModelContext) throws {
        if let project = try fetchProjects(context).first(where: { $0.id == dto.id }) {
            let incomingUpdatedAt = dto.updatedAt ?? dto.createdAt
            guard project.updatedAt <= incomingUpdatedAt else {
                return
            }
            project.title = dto.title
            project.statusRawValue = dto.status
            project.colorRawValue = dto.color ?? ProjectColorPreset.ocean.rawValue
            project.deadline = dto.deadline
            project.notes = dto.notes
            project.createdAt = dto.createdAt
            project.updatedAt = incomingUpdatedAt
        } else {
            context.insert(Project(
                id: dto.id,
                title: dto.title,
                status: ProjectStatus(rawValue: dto.status) ?? .active,
                color: ProjectColorPreset(rawValue: dto.color ?? ProjectColorPreset.ocean.rawValue) ?? .ocean,
                deadline: dto.deadline,
                notes: dto.notes,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt ?? dto.createdAt
            ))
        }
    }

    private static func upsertTag(_ dto: TagBackupDTO, context: ModelContext) throws {
        if let tag = try fetchTags(context).first(where: { $0.id == dto.id }) {
            tag.title = dto.title
            tag.createdAt = dto.createdAt
        } else {
            context.insert(Tag(id: dto.id, title: dto.title, createdAt: dto.createdAt))
        }
    }

    private static func upsertTask(_ dto: TaskBackupDTO, context: ModelContext) throws {
        let projects = try fetchProjects(context)
        let tags = try fetchTags(context)
        let project = dto.projectID.flatMap { projectID in projects.first { $0.id == projectID } }
        let taskTags = dto.tagIDs.compactMap { tagID in tags.first { $0.id == tagID } }
        let incomingUpdatedAt = dto.updatedAt ?? dto.createdAt

        if let task = try fetchTasks(context).first(where: { $0.id == dto.id }) {
            guard task.updatedAt <= incomingUpdatedAt else {
                return
            }

            task.title = dto.title
            task.notes = dto.notes
            task.statusRawValue = dto.status
            task.priorityRawValue = dto.priority
            task.recurrenceRawValue = dto.recurrence ?? TaskRecurrence.none.rawValue
            task.scheduled = dto.scheduled
            task.due = dto.due
            task.createdAt = dto.createdAt
            task.updatedAt = incomingUpdatedAt
            task.completedAt = dto.completedAt
            task.project = project
            task.tags = taskTags
            task.manualOrder = dto.manualOrder
            task.checklistItems.forEach { context.delete($0) }
            task.checklistItems = dto.checklistItems.map { checklistDTO in
                let item = ChecklistItem(
                    id: checklistDTO.id,
                    title: checklistDTO.title,
                    isDone: checklistDTO.isDone,
                    order: checklistDTO.order
                )
                context.insert(item)
                return item
            }
            syncNotifications(for: task, context: context)
        } else {
            let checklistItems = dto.checklistItems.map { checklistDTO in
                ChecklistItem(
                    id: checklistDTO.id,
                    title: checklistDTO.title,
                    isDone: checklistDTO.isDone,
                    order: checklistDTO.order
                )
            }
            checklistItems.forEach(context.insert)

            let task = PlannerTask(
                id: dto.id,
                title: dto.title,
                notes: dto.notes,
                status: TaskStatus(rawValue: dto.status) ?? .inbox,
                priority: Priority(rawValue: dto.priority) ?? .none,
                recurrence: TaskRecurrence(rawValue: dto.recurrence ?? TaskRecurrence.none.rawValue) ?? .none,
                scheduled: dto.scheduled,
                due: dto.due,
                createdAt: dto.createdAt,
                updatedAt: incomingUpdatedAt,
                completedAt: dto.completedAt,
                project: project,
                tags: taskTags,
                checklistItems: checklistItems,
                manualOrder: dto.manualOrder
            )
            context.insert(task)
            syncNotifications(for: task, context: context)
        }
    }

    private static func applySettings(_ dto: SettingsBackupDTO, settings: AppSettings) {
        let incomingUpdatedAt = dto.updatedAt ?? dto.createdAt
        guard settings.updatedAt <= incomingUpdatedAt else {
            return
        }

        settings.theme = dto.theme
        settings.hideEmptyKanbanColumns = dto.hideEmptyKanbanColumns
        settings.defaultReminderLeadMinutes = dto.defaultReminderLeadMinutes ?? settings.defaultReminderLeadMinutes
        settings.updatedAt = incomingUpdatedAt
    }

    private static func clearTombstones(context: ModelContext) throws {
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        tombstones.forEach { context.delete($0) }
    }

    private static func taskDTO(_ task: PlannerTask) -> TaskBackupDTO {
        TaskBackupDTO(
            id: task.id,
            title: task.title,
            notes: task.notes,
            status: task.status.rawValue,
            priority: task.priority.rawValue,
            recurrence: task.recurrence.rawValue,
            scheduled: task.scheduled,
            due: task.due,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt,
            projectID: task.project?.id,
            tagIDs: task.tags.map(\.id),
            checklistItems: task.checklistItems.sorted { $0.order < $1.order }.map {
                ChecklistItemBackupDTO(id: $0.id, title: $0.title, isDone: $0.isDone, order: $0.order)
            },
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
        TagBackupDTO(id: tag.id, title: tag.title, createdAt: tag.createdAt)
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

    private static func syncEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func syncDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func fetchTasks(_ context: ModelContext) throws -> [PlannerTask] {
        try context.fetch(FetchDescriptor<PlannerTask>())
    }

    private static func fetchProjects(_ context: ModelContext) throws -> [Project] {
        try context.fetch(FetchDescriptor<Project>())
    }

    private static func fetchTags(_ context: ModelContext) throws -> [Tag] {
        try context.fetch(FetchDescriptor<Tag>())
    }

    private static func syncNotifications(for task: PlannerTask, context: ModelContext) {
        guard let settings = try? PlannerDataService.ensureAppSettings(context: context) else {
            NotificationService.cancelNotifications(for: task)
            return
        }

        if TaskListService.isActive(task) {
            NotificationService.rescheduleNotifications(for: task, settings: settings)
        } else {
            NotificationService.cancelNotifications(for: task)
        }
    }
}
