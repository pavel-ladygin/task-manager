import CryptoKit
import Foundation
import SwiftData

enum SyncConflictResolution {
    case keepServer
    case keepLocal
    case duplicateLocal
}

@MainActor
enum SyncService {
    private static let settingsEntityID = "app-settings"
    private static var isSyncing = false

    static func testConnection(settings: AppSettings, token: String) async throws -> SyncStatusResponse {
        let response = try await makeClient(settings: settings, token: token).status()
        guard response.protocolVersion == 2 else { throw SyncError.protocolMismatch }
        return response
    }

    static func bootstrap(context: ModelContext, settings: AppSettings, token: String) async throws -> SyncResult {
        guard !isSyncing else { throw SyncError.syncInProgress }
        isSyncing = true
        defer { isSyncing = false }

        let client = try makeClient(settings: settings, token: token)
        let status = try await client.status()
        guard status.protocolVersion == 2 else { throw SyncError.protocolMismatch }
        guard status.isEmpty else { throw SyncError.server("Сервер уже инициализирован. Переподключите устройство через обычную синхронизацию.") }

        try resetLocalSyncMetadata(context: context)
        let payloads = try localPayloads(context: context, settings: settings)
        let mutations = payloads.map { payload in
            SyncMutationDTO(
                mutationID: UUID().uuidString,
                entityType: payload.type.rawValue,
                entityID: payload.entityID,
                operation: SyncMutationOperation.upsert.rawValue,
                payload: payload.value,
                baseRevision: 0,
                createdAt: .now
            )
        }
        let response = try await client.initialize(SyncMutationRequest(deviceID: settings.syncDeviceID, mutations: mutations))
        for (mutation, result) in zip(mutations, response.results) where result.status != "conflict" {
            let hash = payloads.first { $0.type.rawValue == mutation.entityType && $0.entityID == mutation.entityID }?.hash ?? ""
            try updateState(
                typeRawValue: mutation.entityType,
                entityID: mutation.entityID,
                revision: result.serverRevision,
                payloadHash: hash,
                context: context
            )
        }
        settings.syncLastCursor = response.serverCursor
        settings.syncLastSyncAt = .now
        try context.save()
        return SyncResult(pushed: response.results.count, ignored: 0, pulled: 0, cursor: response.serverCursor)
    }

    static func syncNow(context: ModelContext, settings: AppSettings, token: String) async throws -> SyncResult {
        guard settings.syncEnabled else { throw SyncError.disabled }
        guard !isSyncing else { throw SyncError.syncInProgress }
        isSyncing = true
        defer { isSyncing = false }

        let client = try makeClient(settings: settings, token: token)
        let status = try await client.status()
        guard status.protocolVersion == 2 else { throw SyncError.protocolMismatch }
        guard !status.isEmpty else { throw SyncError.serverNotInitialized }

        var pulled = try await pullAll(client: client, context: context, settings: settings)
        try prepareOutbox(context: context, settings: settings)

        var pushed = 0
        var conflicts = 0
        let pending = try context.fetch(FetchDescriptor<SyncOutboxItem>(sortBy: [SortDescriptor(\.createdAt)]))
        if !pending.isEmpty {
            pending.forEach { $0.attemptCount += 1 }
            try context.save()
            let request = SyncMutationRequest(
                deviceID: settings.syncDeviceID,
                mutations: try pending.map(mutationDTO)
            )
            let response = try await client.mutations(request)
            for result in response.results {
                guard let item = pending.first(where: { $0.mutationID.uuidString == result.mutationID }) else { continue }
                switch result.status {
                case "accepted", "duplicate":
                    let hash = item.operation == SyncMutationOperation.delete.rawValue
                        ? "deleted"
                        : hashString(item.payloadJSON ?? "")
                    try updateState(
                        typeRawValue: item.entityType,
                        entityID: item.entityID,
                        revision: result.serverRevision,
                        payloadHash: hash,
                        context: context
                    )
                    context.delete(item)
                    pushed += 1
                case "conflict":
                    let serverJSON = try result.current?.payload.map(jsonString)
                    if let type = SyncEntityType(rawValue: item.entityType) {
                        context.insert(SyncConflict(
                            entityType: type,
                            entityID: item.entityID,
                            localPayloadJSON: item.payloadJSON,
                            serverPayloadJSON: serverJSON,
                            serverRevision: result.serverRevision
                        ))
                    }
                    context.delete(item)
                    // The conflict response is authoritative. Remove the pending
                    // mutation before applying it so the pending-mutation guard
                    // used by normal pulls does not suppress the server version.
                    if let current = result.current {
                        try apply(changes: [current], context: context, settings: settings, respectPendingMutations: false)
                    }
                    conflicts += 1
                default:
                    break
                }
            }
            try context.save()
        }

        pulled += try await pullAll(client: client, context: context, settings: settings)
        settings.syncLastSyncAt = .now
        try context.save()
        return SyncResult(pushed: pushed, ignored: conflicts, pulled: pulled, cursor: settings.syncLastCursor)
    }

    /// Replays only calendar-only entities without changing the normal sync
    /// cursor. This recovers events skipped by an older app while leaving
    /// tasks and projects untouched.
    static func reloadCalendarEvents(context: ModelContext, settings: AppSettings, token: String) async throws -> Int {
        guard settings.syncEnabled else { throw SyncError.disabled }
        guard !isSyncing else { throw SyncError.syncInProgress }
        isSyncing = true
        defer { isSyncing = false }

        let client = try makeClient(settings: settings, token: token)
        var historyCursor: Int64 = 0
        var imported = 0
        while true {
            let response = try await client.changes(after: historyCursor)
            let calendarChanges = response.changes.filter {
                $0.entityType == SyncEntityType.calendarEvent.rawValue
                    || $0.entityType == SyncEntityType.calendarEventException.rawValue
            }
            if !calendarChanges.isEmpty {
                do {
                    try apply(changes: calendarChanges, context: context, settings: settings)
                    try context.save()
                    imported += calendarChanges.count
                } catch {
                    context.rollback()
                    throw error
                }
            }
            guard response.hasMore, let latestRevision = response.changes.map(\.revision).max() else { break }
            historyCursor = latestRevision
        }
        return imported
    }

    static func resolve(
        _ conflict: SyncConflict,
        resolution: SyncConflictResolution,
        context: ModelContext
    ) throws {
        guard conflict.resolvedAt == nil, let type = SyncEntityType(rawValue: conflict.entityType) else { return }
        switch resolution {
        case .keepServer:
            break
        case .keepLocal:
            guard let payloadJSON = conflict.localPayloadJSON else { break }
            try applyLocalPayload(payloadJSON, type: type, context: context)
            context.insert(SyncOutboxItem(
                entityType: type,
                entityID: conflict.entityID,
                operation: .upsert,
                payloadJSON: payloadJSON,
                baseRevision: conflict.serverRevision
            ))
        case .duplicateLocal:
            guard let payloadJSON = conflict.localPayloadJSON else { break }
            try duplicateLocalPayload(payloadJSON, type: type, context: context)
        }
        conflict.resolvedAt = .now
        try context.save()
    }

    /// Adds or coalesces an upsert without saving the context. The caller then
    /// persists the edited model and the durable outbox item together.
    static func enqueueUpsert(task: PlannerTask, context: ModelContext) throws {
        let payload = try localPayload(type: .task, id: task.id.uuidString, dto: taskDTO(task))
        try enqueue(payload: payload, context: context)
    }

    static func enqueueUpsert(project: Project, context: ModelContext) throws {
        let payload = try localPayload(type: .project, id: project.id.uuidString, dto: projectDTO(project))
        try enqueue(payload: payload, context: context)
    }

    static func enqueueUpsert(settings: AppSettings, context: ModelContext) throws {
        let payload = try localPayload(type: .settings, id: settingsEntityID, dto: settingsDTO(settings))
        try enqueue(payload: payload, context: context)
    }

    static func enqueueUpsert(event: CalendarEvent, context: ModelContext) throws {
        let payload = try localPayload(type: .calendarEvent, id: event.id.uuidString, dto: calendarEventDTO(event))
        try enqueue(payload: payload, context: context)
    }

    static func enqueueUpsert(exception: CalendarEventException, context: ModelContext) throws {
        let payload = try localPayload(type: .calendarEventException, id: exception.id.uuidString, dto: calendarEventExceptionDTO(exception))
        try enqueue(payload: payload, context: context)
    }

    static func enqueueDelete(type: SyncEntityType, entityID: UUID, context: ModelContext) throws {
        let rawID = entityID.uuidString
        let pending = try context.fetch(FetchDescriptor<SyncOutboxItem>()).filter {
            $0.entityType == type.rawValue && $0.entityID == rawID
        }
        let state = try context.fetch(FetchDescriptor<SyncEntityState>()).first {
            $0.entityType == type.rawValue && $0.entityID == rawID
        }

        // A local-only entity can disappear together with its unsent upsert.
        if state == nil, !pending.isEmpty, pending.allSatisfy({ $0.attemptCount == 0 }) {
            pending.forEach(context.delete)
            return
        }
        if let editable = pending.first(where: { $0.attemptCount == 0 }) {
            editable.operation = SyncMutationOperation.delete.rawValue
            editable.payloadJSON = nil
            editable.baseRevision = state?.serverRevision ?? 0
            return
        }
        context.insert(SyncOutboxItem(
            entityType: type,
            entityID: rawID,
            operation: .delete,
            payloadJSON: nil,
            baseRevision: state?.serverRevision ?? 0
        ))
    }

    private static func pullAll(
        client: SyncClient,
        context: ModelContext,
        settings: AppSettings
    ) async throws -> Int {
        var total = 0
        while true {
            let response = try await client.changes(after: settings.syncLastCursor)
            guard !response.changes.isEmpty else {
                settings.syncLastCursor = response.serverCursor
                try context.save()
                return total
            }
            do {
                try apply(changes: response.changes, context: context, settings: settings)
                settings.syncLastCursor = response.changes.map(\.revision).max() ?? settings.syncLastCursor
                try context.save()
                total += response.changes.count
            } catch {
                context.rollback()
                throw error
            }
            if !response.hasMore {
                settings.syncLastCursor = response.serverCursor
                try context.save()
                return total
            }
        }
    }

    private struct LocalPayload {
        let type: SyncEntityType
        let entityID: String
        let json: String
        let value: JSONValue
        let hash: String
    }

    private static func enqueue(payload: LocalPayload, context: ModelContext) throws {
        let state = try context.fetch(FetchDescriptor<SyncEntityState>()).first {
            $0.entityType == payload.type.rawValue && $0.entityID == payload.entityID
        }
        if state?.payloadHash == payload.hash { return }

        let pending = try context.fetch(FetchDescriptor<SyncOutboxItem>())
        if let editable = pending.first(where: {
            $0.entityType == payload.type.rawValue
                && $0.entityID == payload.entityID
                && $0.attemptCount == 0
        }) {
            editable.operation = SyncMutationOperation.upsert.rawValue
            editable.payloadJSON = payload.json
            editable.baseRevision = state?.serverRevision ?? 0
            return
        }
        context.insert(SyncOutboxItem(
            entityType: payload.type,
            entityID: payload.entityID,
            operation: .upsert,
            payloadJSON: payload.json,
            baseRevision: state?.serverRevision ?? 0
        ))
    }

    private static func localPayloads(context: ModelContext, settings: AppSettings) throws -> [LocalPayload] {
        var result: [LocalPayload] = []
        for project in try context.fetch(FetchDescriptor<Project>()) {
            result.append(try localPayload(type: .project, id: project.id.uuidString, dto: projectDTO(project)))
        }
        for tag in try context.fetch(FetchDescriptor<Tag>()) {
            result.append(try localPayload(type: .tag, id: tag.id.uuidString, dto: tagDTO(tag)))
        }
        result.append(try localPayload(type: .settings, id: settingsEntityID, dto: settingsDTO(settings)))
        for task in try context.fetch(FetchDescriptor<PlannerTask>()) {
            result.append(try localPayload(type: .task, id: task.id.uuidString, dto: taskDTO(task)))
        }
        for event in try context.fetch(FetchDescriptor<CalendarEvent>()) {
            result.append(try localPayload(type: .calendarEvent, id: event.id.uuidString, dto: calendarEventDTO(event)))
        }
        for exception in try context.fetch(FetchDescriptor<CalendarEventException>()) {
            result.append(try localPayload(type: .calendarEventException, id: exception.id.uuidString, dto: calendarEventExceptionDTO(exception)))
        }
        return result
    }

    private static func localPayload<T: Encodable>(type: SyncEntityType, id: String, dto: T) throws -> LocalPayload {
        let data = try SyncClient.encoder.encode(dto)
        guard let json = String(data: data, encoding: .utf8) else { throw SyncError.invalidResponse }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return LocalPayload(type: type, entityID: id, json: json, value: value, hash: hashString(json))
    }

    private static func prepareOutbox(context: ModelContext, settings: AppSettings) throws {
        let states = try context.fetch(FetchDescriptor<SyncEntityState>())
        let pending = try context.fetch(FetchDescriptor<SyncOutboxItem>())
        for payload in try localPayloads(context: context, settings: settings) {
            let state = states.first { $0.entityType == payload.type.rawValue && $0.entityID == payload.entityID }
            guard state?.payloadHash != payload.hash else { continue }
            if let existing = pending.first(where: {
                $0.entityType == payload.type.rawValue && $0.entityID == payload.entityID && $0.operation == SyncMutationOperation.upsert.rawValue
            }) {
                if existing.attemptCount == 0 {
                    existing.payloadJSON = payload.json
                    existing.baseRevision = state?.serverRevision ?? 0
                }
                continue
            }
            context.insert(SyncOutboxItem(
                entityType: payload.type,
                entityID: payload.entityID,
                operation: .upsert,
                payloadJSON: payload.json,
                baseRevision: state?.serverRevision ?? 0
            ))
        }

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        for tombstone in tombstones {
            guard let type = tombstone.syncEntityType else { continue }
            let entityID = tombstone.entityID.uuidString
            let existing = pending.first { $0.entityType == type.rawValue && $0.entityID == entityID }
            if existing == nil {
                let state = states.first { $0.entityType == type.rawValue && $0.entityID == entityID }
                context.insert(SyncOutboxItem(
                    entityType: type,
                    entityID: entityID,
                    operation: .delete,
                    payloadJSON: nil,
                    baseRevision: state?.serverRevision ?? 0,
                    createdAt: tombstone.createdAt
                ))
                context.delete(tombstone)
            }
        }
        try context.save()
    }

    private static func mutationDTO(_ item: SyncOutboxItem) throws -> SyncMutationDTO {
        let payload: JSONValue?
        if let json = item.payloadJSON, let data = json.data(using: .utf8) {
            payload = try JSONDecoder().decode(JSONValue.self, from: data)
        } else { payload = nil }
        return SyncMutationDTO(
            mutationID: item.mutationID.uuidString,
            entityType: item.entityType,
            entityID: item.entityID,
            operation: item.operation,
            payload: payload,
            baseRevision: item.baseRevision,
            createdAt: item.createdAt
        )
    }

    static func apply(
        changes: [SyncServerChangeDTO],
        context: ModelContext,
        settings: AppSettings,
        respectPendingMutations: Bool = true
    ) throws {
        let pendingEntityKeys: Set<String>
        if respectPendingMutations {
            pendingEntityKeys = Set(try context.fetch(FetchDescriptor<SyncOutboxItem>()).map {
                "\($0.entityType):\($0.entityID)"
            })
        } else {
            pendingEntityKeys = []
        }
        let order: [SyncEntityType] = [.project, .tag, .settings, .calendarEvent, .calendarEventException, .task]
        for type in order {
            for change in changes where change.entityType == type.rawValue {
                let key = "\(change.entityType):\(change.entityID)"
                guard !pendingEntityKeys.contains(key) else { continue }
                try apply(change: change, context: context, settings: settings)
            }
        }

        let events = try context.fetch(FetchDescriptor<CalendarEvent>())
        let exceptions = try context.fetch(FetchDescriptor<CalendarEventException>())
        for event in events {
            NotificationService.rescheduleNotifications(
                for: event,
                exceptions: exceptions.filter { $0.eventID == event.id }
            )
        }
    }

    private static func apply(change: SyncServerChangeDTO, context: ModelContext, settings: AppSettings) throws {
        guard let type = SyncEntityType(rawValue: change.entityType) else { return }
        if change.operation == SyncMutationOperation.delete.rawValue {
            try applyDelete(type: type, entityID: change.entityID, context: context)
            try updateState(typeRawValue: change.entityType, entityID: change.entityID, revision: change.revision, payloadHash: "deleted", context: context)
            return
        }
        guard let payload = change.payload else { return }
        let data = try JSONEncoder().encode(payload)
        switch type {
        case .project: try upsertProject(SyncClient.decoder.decode(ProjectBackupDTO.self, from: data), context: context)
        case .tag: try upsertTag(SyncClient.decoder.decode(TagBackupDTO.self, from: data), context: context)
        case .settings: applySettings(try SyncClient.decoder.decode(SettingsBackupDTO.self, from: data), settings: settings)
        case .task: try upsertTask(SyncClient.decoder.decode(TaskBackupDTO.self, from: data), context: context)
        case .calendarEvent: try upsertCalendarEvent(SyncClient.decoder.decode(CalendarEventBackupDTO.self, from: data), context: context)
        case .calendarEventException: try upsertCalendarEventException(SyncClient.decoder.decode(CalendarEventExceptionBackupDTO.self, from: data), context: context)
        }
        try updateState(
            typeRawValue: change.entityType,
            entityID: change.entityID,
            revision: change.revision,
            payloadHash: hashString(try jsonString(payload)),
            context: context
        )
    }

    private static func applyDelete(type: SyncEntityType, entityID: String, context: ModelContext) throws {
        switch type {
        case .task:
            if let id = UUID(uuidString: entityID), let task = try context.fetch(FetchDescriptor<PlannerTask>()).first(where: { $0.id == id }) {
                NotificationService.cancelNotifications(for: task)
                task.checklistItems.forEach(context.delete)
                context.delete(task)
            }
        case .project:
            if let id = UUID(uuidString: entityID), let project = try context.fetch(FetchDescriptor<Project>()).first(where: { $0.id == id }) {
                try context.fetch(FetchDescriptor<PlannerTask>()).filter { $0.project?.id == id }.forEach { $0.project = nil }
                try context.fetch(FetchDescriptor<CalendarEvent>()).filter { $0.project?.id == id }.forEach { $0.project = nil }
                try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.project?.id == id }.forEach { $0.project = nil }
                context.delete(project)
            }
        case .tag:
            if let id = UUID(uuidString: entityID), let tag = try context.fetch(FetchDescriptor<Tag>()).first(where: { $0.id == id }) {
                try context.fetch(FetchDescriptor<PlannerTask>()).forEach { $0.tags.removeAll { $0.id == id } }
                context.delete(tag)
            }
        case .settings: break
        case .calendarEvent:
            if let id = UUID(uuidString: entityID), let event = try context.fetch(FetchDescriptor<CalendarEvent>()).first(where: { $0.id == id }) {
                NotificationService.cancelNotifications(for: event)
                try context.fetch(FetchDescriptor<CalendarEventException>())
                    .filter { $0.eventID == id }
                    .forEach(context.delete)
                context.delete(event)
            }
        case .calendarEventException:
            if let id = UUID(uuidString: entityID), let exception = try context.fetch(FetchDescriptor<CalendarEventException>()).first(where: { $0.id == id }) {
                context.delete(exception)
            }
        }
    }

    private static func applyLocalPayload(_ json: String, type: SyncEntityType, context: ModelContext) throws {
        guard let data = json.data(using: .utf8) else { throw SyncError.invalidResponse }
        switch type {
        case .task: try upsertTask(SyncClient.decoder.decode(TaskBackupDTO.self, from: data), context: context)
        case .project: try upsertProject(SyncClient.decoder.decode(ProjectBackupDTO.self, from: data), context: context)
        case .tag: try upsertTag(SyncClient.decoder.decode(TagBackupDTO.self, from: data), context: context)
        case .settings:
            if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
                applySettings(try SyncClient.decoder.decode(SettingsBackupDTO.self, from: data), settings: settings)
            }
        case .calendarEvent:
            try upsertCalendarEvent(SyncClient.decoder.decode(CalendarEventBackupDTO.self, from: data), context: context)
        case .calendarEventException:
            try upsertCalendarEventException(SyncClient.decoder.decode(CalendarEventExceptionBackupDTO.self, from: data), context: context)
        }
    }

    private static func duplicateLocalPayload(_ json: String, type: SyncEntityType, context: ModelContext) throws {
        guard let data = json.data(using: .utf8) else { throw SyncError.invalidResponse }
        switch type {
        case .task:
            let dto = try SyncClient.decoder.decode(TaskBackupDTO.self, from: data)
            let projects = try context.fetch(FetchDescriptor<Project>())
            let tags = try context.fetch(FetchDescriptor<Tag>())
            let checklist = dto.checklistItems.map { ChecklistItem(title: $0.title, isDone: $0.isDone, order: $0.order) }
            checklist.forEach(context.insert)
            context.insert(PlannerTask(
                title: dto.title + " (конфликтная копия)", notes: dto.notes,
                status: TaskStatus(rawValue: dto.status) ?? .inbox,
                priority: Priority(rawValue: dto.priority) ?? .none,
                recurrence: .none, showInKanban: dto.showInKanban ?? true,
                scheduled: dto.scheduled, due: dto.due,
                project: dto.projectID.flatMap { id in projects.first { $0.id == id } },
                tags: dto.tagIDs.compactMap { id in tags.first { $0.id == id } },
                checklistItems: checklist, manualOrder: dto.manualOrder
            ))
        case .project:
            let dto = try SyncClient.decoder.decode(ProjectBackupDTO.self, from: data)
            context.insert(Project(
                title: dto.title + " (конфликтная копия)",
                status: ProjectStatus(rawValue: dto.status) ?? .active,
                color: ProjectColorPreset(rawValue: dto.color ?? "ocean") ?? .ocean,
                deadline: dto.deadline, notes: dto.notes
            ))
        case .tag, .settings:
            try applyLocalPayload(json, type: type, context: context)
        case .calendarEvent:
            let dto = try SyncClient.decoder.decode(CalendarEventBackupDTO.self, from: data)
            context.insert(CalendarEvent(
                id: UUID(), title: dto.title + " (конфликтная копия)", notes: dto.notes,
                start: dto.start, end: dto.end,
                timeZoneIdentifier: dto.timeZoneIdentifier,
                recurrence: CalendarEventRecurrence(rawValue: dto.recurrenceRawValue) ?? .none,
                recurrenceEndDate: dto.recurrenceEndDate,
                reminder: CalendarEventReminder(rawValue: dto.reminderRawValue) ?? .fifteenMinutes,
                project: try context.fetch(FetchDescriptor<Project>()).first { $0.id == dto.projectID }
            ))
        case .calendarEventException:
            // An exception without its source event cannot be materialized safely.
            // Keep the payload resolvable by applying it only when the source exists.
            try applyLocalPayload(json, type: type, context: context)
        }
    }

    private static func upsertProject(_ dto: ProjectBackupDTO, context: ModelContext) throws {
        if let project = try context.fetch(FetchDescriptor<Project>()).first(where: { $0.id == dto.id }) {
            project.title = dto.title; project.statusRawValue = dto.status
            project.colorRawValue = dto.color ?? ProjectColorPreset.ocean.rawValue
            project.deadline = dto.deadline; project.notes = dto.notes
            project.createdAt = dto.createdAt; project.updatedAt = dto.updatedAt ?? dto.createdAt
        } else {
            context.insert(Project(
                id: dto.id, title: dto.title, status: ProjectStatus(rawValue: dto.status) ?? .active,
                color: ProjectColorPreset(rawValue: dto.color ?? "ocean") ?? .ocean,
                deadline: dto.deadline, notes: dto.notes, createdAt: dto.createdAt, updatedAt: dto.updatedAt ?? dto.createdAt
            ))
        }
    }

    private static func upsertTag(_ dto: TagBackupDTO, context: ModelContext) throws {
        if let tag = try context.fetch(FetchDescriptor<Tag>()).first(where: { $0.id == dto.id }) {
            tag.title = dto.title; tag.createdAt = dto.createdAt
        } else { context.insert(Tag(id: dto.id, title: dto.title, createdAt: dto.createdAt)) }
    }

    private static func upsertTask(_ dto: TaskBackupDTO, context: ModelContext) throws {
        let projects = try context.fetch(FetchDescriptor<Project>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let project = dto.projectID.flatMap { id in projects.first { $0.id == id } }
        let taskTags = dto.tagIDs.compactMap { id in tags.first { $0.id == id } }
        let task = try context.fetch(FetchDescriptor<PlannerTask>()).first(where: { $0.id == dto.id })
            ?? PlannerTask(title: dto.title)
        if task.id != dto.id { task.id = dto.id; context.insert(task) }
        task.title = dto.title; task.notes = dto.notes
        task.statusRawValue = dto.status; task.priorityRawValue = dto.priority
        task.recurrenceRawValue = dto.recurrence ?? TaskRecurrence.none.rawValue
        task.recurrenceSeriesID = dto.recurrenceSeriesID
        task.recurrenceAnchorDate = dto.recurrenceAnchorDate
        task.recurrenceSequence = dto.recurrenceSequence ?? 0
        task.showInKanban = dto.showInKanban ?? true
        task.scheduled = dto.scheduled; task.due = dto.due
        task.createdAt = dto.createdAt; task.updatedAt = dto.updatedAt ?? dto.createdAt
        task.completedAt = dto.completedAt; task.project = project; task.tags = taskTags
        task.manualOrder = dto.manualOrder
        task.checklistItems.forEach(context.delete)
        task.checklistItems = dto.checklistItems.map {
            let item = ChecklistItem(id: $0.id, title: $0.title, isDone: $0.isDone, order: $0.order)
            context.insert(item); return item
        }
        syncNotifications(for: task, context: context)
    }

    private static func applySettings(_ dto: SettingsBackupDTO, settings: AppSettings) {
        settings.theme = dto.theme
        settings.hideEmptyKanbanColumns = dto.hideEmptyKanbanColumns
        settings.defaultReminderLeadMinutes = dto.defaultReminderLeadMinutes ?? settings.defaultReminderLeadMinutes
        settings.updatedAt = dto.updatedAt ?? dto.createdAt
    }

    private static func updateState(
        typeRawValue: String,
        entityID: String,
        revision: Int64,
        payloadHash: String,
        context: ModelContext
    ) throws {
        guard let type = SyncEntityType(rawValue: typeRawValue) else { return }
        if let state = try context.fetch(FetchDescriptor<SyncEntityState>()).first(where: {
            $0.entityType == typeRawValue && $0.entityID == entityID
        }) {
            state.serverRevision = revision; state.payloadHash = payloadHash; state.updatedAt = .now
        } else {
            context.insert(SyncEntityState(entityType: type, entityID: entityID, serverRevision: revision, payloadHash: payloadHash))
        }
    }

    private static func resetLocalSyncMetadata(context: ModelContext) throws {
        try context.fetch(FetchDescriptor<SyncOutboxItem>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<SyncEntityState>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<SyncTombstone>()).forEach(context.delete)
        try context.save()
    }

    private static func makeClient(settings: AppSettings, token: String) throws -> SyncClient {
        guard let baseURL = URL(string: settings.syncServerURL), baseURL.scheme?.lowercased() == "https" else {
            throw SyncError.invalidServerURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SyncError.missingToken }
        guard !settings.syncCertificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.missingCertificateFingerprint
        }
        return SyncClient(baseURL: baseURL, token: token, certificateFingerprint: settings.syncCertificateFingerprint)
    }

    private static func jsonString(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw SyncError.invalidResponse }
        return string
    }

    private static func hashString(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func taskDTO(_ task: PlannerTask) -> TaskBackupDTO {
        TaskBackupDTO(
            id: task.id, title: task.title, notes: task.notes, status: task.status.rawValue,
            priority: task.priority.rawValue, recurrence: task.recurrence.rawValue,
            recurrenceSeriesID: task.recurrenceSeriesID, recurrenceAnchorDate: task.recurrenceAnchorDate,
            recurrenceSequence: task.recurrenceSequence, showInKanban: task.showInKanban,
            scheduled: task.scheduled, due: task.due, createdAt: task.createdAt, updatedAt: task.updatedAt,
            completedAt: task.completedAt, projectID: task.project?.id, tagIDs: task.tags.map(\.id),
            checklistItems: task.checklistItems.sorted { $0.order < $1.order }.map {
                ChecklistItemBackupDTO(id: $0.id, title: $0.title, isDone: $0.isDone, order: $0.order)
            }, manualOrder: task.manualOrder
        )
    }

    private static func projectDTO(_ project: Project) -> ProjectBackupDTO {
        ProjectBackupDTO(
            id: project.id, title: project.title, status: project.status.rawValue,
            color: project.colorPreset.rawValue, deadline: project.deadline, notes: project.notes,
            createdAt: project.createdAt, updatedAt: project.updatedAt
        )
    }

    private static func calendarEventDTO(_ event: CalendarEvent) -> CalendarEventBackupDTO {
        CalendarEventBackupDTO(
            id: event.id, title: event.title, notes: event.notes,
            start: event.start, end: event.end,
            timeZoneIdentifier: event.timeZoneIdentifier,
            recurrenceRawValue: event.recurrenceRawValue,
            recurrenceEndDate: event.recurrenceEndDate,
            projectID: event.project?.id, reminderRawValue: event.reminderRawValue,
            createdAt: event.createdAt, updatedAt: event.updatedAt
        )
    }

    private static func calendarEventExceptionDTO(_ exception: CalendarEventException) -> CalendarEventExceptionBackupDTO {
        CalendarEventExceptionBackupDTO(
            id: exception.id, eventID: exception.eventID,
            occurrenceDate: exception.occurrenceDate, isDeleted: exception.isSkipped,
            titleOverride: exception.titleOverride, notesOverride: exception.notesOverride,
            startOverride: exception.startOverride, endOverride: exception.endOverride,
            timeZoneIdentifierOverride: exception.timeZoneIdentifierOverride,
            reminderRawValueOverride: exception.reminderRawValueOverride,
            projectOverrideSet: exception.projectOverrideSet,
            projectID: exception.project?.id,
            createdAt: exception.createdAt, updatedAt: exception.updatedAt
        )
    }

    static func upsertCalendarEvent(_ dto: CalendarEventBackupDTO, context: ModelContext) throws {
        let project = dto.projectID.flatMap { id in
            (try? context.fetch(FetchDescriptor<Project>()))?.first { $0.id == id }
        }
        let event: CalendarEvent
        if let existing = try context.fetch(FetchDescriptor<CalendarEvent>()).first(where: { $0.id == dto.id }) {
            event = existing
        } else {
            event = CalendarEvent(id: dto.id, title: dto.title, notes: dto.notes,
                                  start: dto.start, end: dto.end,
                                  timeZoneIdentifier: dto.timeZoneIdentifier,
                                  recurrence: CalendarEventRecurrence(rawValue: dto.recurrenceRawValue) ?? .none,
                                  recurrenceEndDate: dto.recurrenceEndDate,
                                  reminder: CalendarEventReminder(rawValue: dto.reminderRawValue) ?? .fifteenMinutes,
                                  project: project, createdAt: dto.createdAt, updatedAt: dto.updatedAt)
            context.insert(event)
        }
        event.title = dto.title; event.notes = dto.notes
        event.start = dto.start; event.end = dto.end
        event.timeZoneIdentifier = dto.timeZoneIdentifier
        event.recurrenceRawValue = dto.recurrenceRawValue
        event.recurrenceEndDate = dto.recurrenceEndDate
        event.project = project; event.reminderRawValue = dto.reminderRawValue
        event.createdAt = dto.createdAt; event.updatedAt = dto.updatedAt
    }

    static func upsertCalendarEventException(_ dto: CalendarEventExceptionBackupDTO, context: ModelContext) throws {
        guard let event = try context.fetch(FetchDescriptor<CalendarEvent>()).first(where: { $0.id == dto.eventID }) else { return }
        let project = dto.projectID.flatMap { id in
            (try? context.fetch(FetchDescriptor<Project>()))?.first { $0.id == id }
        }
        let exception: CalendarEventException
        if let existing = try context.fetch(FetchDescriptor<CalendarEventException>()).first(where: { $0.id == dto.id }) {
            exception = existing
        } else {
            exception = CalendarEventException(id: dto.id, eventID: event.id, occurrenceDate: dto.occurrenceDate,
                                               isDeleted: dto.isDeleted, titleOverride: dto.titleOverride,
                                               notesOverride: dto.notesOverride, startOverride: dto.startOverride,
                                               endOverride: dto.endOverride,
                                               timeZoneIdentifierOverride: dto.timeZoneIdentifierOverride,
                                               reminderOverride: dto.reminderRawValueOverride.flatMap(CalendarEventReminder.init(rawValue:)),
                                               projectOverrideSet: dto.projectOverrideSet ?? false,
                                               project: project, createdAt: dto.createdAt, updatedAt: dto.updatedAt)
            context.insert(exception)
        }
        exception.eventID = event.id; exception.occurrenceDate = dto.occurrenceDate
        exception.isSkipped = dto.isDeleted; exception.titleOverride = dto.titleOverride; exception.notesOverride = dto.notesOverride
        exception.startOverride = dto.startOverride; exception.endOverride = dto.endOverride
        exception.timeZoneIdentifierOverride = dto.timeZoneIdentifierOverride
        exception.reminderRawValueOverride = dto.reminderRawValueOverride
        exception.projectOverrideSet = dto.projectOverrideSet ?? false
        exception.project = project
        exception.createdAt = dto.createdAt; exception.updatedAt = dto.updatedAt
    }
    private static func tagDTO(_ tag: Tag) -> TagBackupDTO {
        TagBackupDTO(id: tag.id, title: tag.title, createdAt: tag.createdAt)
    }
    private static func settingsDTO(_ settings: AppSettings) -> SettingsBackupDTO {
        SettingsBackupDTO(
            id: settings.id, theme: settings.theme, hideEmptyKanbanColumns: settings.hideEmptyKanbanColumns,
            defaultReminderLeadMinutes: settings.defaultReminderLeadMinutes,
            createdAt: settings.createdAt, updatedAt: settings.updatedAt
        )
    }

    private static func syncNotifications(for task: PlannerTask, context: ModelContext) {
        guard let settings = try? context.fetch(FetchDescriptor<AppSettings>()).first else { return }
        if TaskListService.isActive(task) { NotificationService.rescheduleNotifications(for: task, settings: settings) }
        else { NotificationService.cancelNotifications(for: task) }
    }
}
