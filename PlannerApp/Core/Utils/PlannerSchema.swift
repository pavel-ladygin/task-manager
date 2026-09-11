import Foundation
import SwiftData

// V1 deliberately mirrors the schema shipped before versioned migrations were introduced.
// Keeping it here allows SwiftData to identify and migrate an existing unversioned store.
enum PlannerSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlannerTask.self, Project.self, Tag.self, ChecklistItem.self, AppSettings.self, SyncTombstone.self]
    }

    @Model final class PlannerTask {
        var id: UUID = UUID()
        var title: String = ""
        var notes: String = ""
        var statusRawValue: String = TaskStatus.inbox.rawValue
        var priorityRawValue: String = Priority.none.rawValue
        var recurrenceRawValue: String = TaskRecurrence.none.rawValue
        var scheduled: Date?
        var due: Date?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var completedAt: Date?
        var project: Project?
        var tags: [Tag] = []
        var checklistItems: [ChecklistItem] = []
        var manualOrder: Double = 0
        init() {}
    }

    @Model final class Project {
        var id: UUID = UUID()
        var title: String = ""
        var statusRawValue: String = ProjectStatus.active.rawValue
        var colorRawValue: String = "ocean"
        var deadline: Date?
        var notes: String = ""
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        init() {}
    }

    @Model final class Tag {
        var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date.now
        init() {}
    }

    @Model final class ChecklistItem {
        var id: UUID = UUID()
        var title: String = ""
        var isDone: Bool = false
        var order: Int = 0
        init() {}
    }

    @Model final class AppSettings {
        var id: UUID = UUID()
        var theme: String = AppTheme.system.rawValue
        var hideEmptyKanbanColumns: Bool = false
        var defaultReminderLeadMinutes: Int = 15
        var syncEnabled: Bool = false
        var syncServerURL: String = "https://91.108.189.121:8443"
        var syncCertificateFingerprint: String = ""
        var syncDeviceID: String = UUID().uuidString
        var syncLastCursor: Int64 = 0
        var syncLastSyncAt: Date?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        init() {}
    }

    @Model final class SyncTombstone {
        var id: UUID = UUID()
        var entityType: String = ""
        var entityID: UUID = UUID()
        var clientUpdatedAt: Date = Date.now
        var createdAt: Date = Date.now
        init() {}
    }
}

enum PlannerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PlannerTask.self,
            Project.self,
            Tag.self,
            ChecklistItem.self,
            AppSettings.self,
            SyncTombstone.self,
            SyncOutboxItem.self,
            SyncEntityState.self,
            SyncConflict.self
        ]
    }

    @Model final class PlannerTask {
        var id: UUID = UUID()
        var title: String = ""
        var notes: String = ""
        var statusRawValue: String = TaskStatus.inbox.rawValue
        var priorityRawValue: String = Priority.none.rawValue
        var recurrenceRawValue: String = TaskRecurrence.none.rawValue
        var recurrenceSeriesID: UUID?
        var recurrenceAnchorDate: Date?
        var recurrenceSequence: Int = 0
        var showInKanban: Bool = true
        var scheduled: Date?
        var due: Date?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var completedAt: Date?
        var project: Project?
        var tags: [Tag] = []
        var checklistItems: [ChecklistItem] = []
        var manualOrder: Double = 0

        init(
            id: UUID = UUID(),
            title: String,
            notes: String = "",
            status: TaskStatus = .inbox,
            priority: Priority = .none,
            recurrence: TaskRecurrence = .none,
            recurrenceSeriesID: UUID? = nil,
            recurrenceAnchorDate: Date? = nil,
            recurrenceSequence: Int = 0,
            showInKanban: Bool = true,
            scheduled: Date? = nil,
            due: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now,
            completedAt: Date? = nil,
            project: Project? = nil,
            tags: [Tag] = [],
            checklistItems: [ChecklistItem] = [],
            manualOrder: Double = 0
        ) {
            self.id = id
            self.title = title
            self.notes = notes
            self.statusRawValue = status.rawValue
            self.priorityRawValue = priority.rawValue
            self.recurrenceRawValue = recurrence.rawValue
            self.recurrenceSeriesID = recurrenceSeriesID
            self.recurrenceAnchorDate = recurrenceAnchorDate
            self.recurrenceSequence = recurrenceSequence
            self.showInKanban = showInKanban
            self.scheduled = scheduled
            self.due = due
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.completedAt = completedAt
            self.project = project
            self.tags = tags
            self.checklistItems = checklistItems
            self.manualOrder = manualOrder
        }

        var status: TaskStatus {
            get { TaskStatus(rawValue: statusRawValue) ?? .inbox }
            set { statusRawValue = newValue.rawValue }
        }

        var priority: Priority {
            get { Priority(rawValue: priorityRawValue) ?? .none }
            set { priorityRawValue = newValue.rawValue }
        }

        var recurrence: TaskRecurrence {
            get { TaskRecurrence(rawValue: recurrenceRawValue) ?? .none }
            set { recurrenceRawValue = newValue.rawValue }
        }
    }

    @Model final class Project {
        var id: UUID = UUID()
        var title: String = ""
        var statusRawValue: String = ProjectStatus.active.rawValue
        var colorRawValue: String = "ocean"
        var deadline: Date?
        var notes: String = ""
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            title: String,
            status: ProjectStatus = .active,
            color: ProjectColorPreset = .ocean,
            deadline: Date? = nil,
            notes: String = "",
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.title = title
            statusRawValue = status.rawValue
            colorRawValue = color.rawValue
            self.deadline = deadline
            self.notes = notes
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var status: ProjectStatus {
            get { ProjectStatus(rawValue: statusRawValue) ?? .active }
            set { statusRawValue = newValue.rawValue }
        }

        var colorPreset: ProjectColorPreset {
            get { ProjectColorPreset(rawValue: colorRawValue) ?? .ocean }
            set { colorRawValue = newValue.rawValue }
        }
    }

    @Model final class Tag {
        var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date.now

        init(id: UUID = UUID(), title: String, createdAt: Date = .now) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
        }
    }

    @Model final class ChecklistItem {
        var id: UUID = UUID()
        var title: String = ""
        var isDone: Bool = false
        var order: Int = 0

        init(id: UUID = UUID(), title: String, isDone: Bool = false, order: Int = 0) {
            self.id = id
            self.title = title
            self.isDone = isDone
            self.order = order
        }
    }

    @Model final class AppSettings {
        var id: UUID = UUID()
        var theme: String = AppTheme.system.rawValue
        var hideEmptyKanbanColumns: Bool = false
        var defaultReminderLeadMinutes: Int = 15
        var syncEnabled: Bool = false
        var syncServerURL: String = "https://91.108.189.121:8443"
        var syncCertificateFingerprint: String = ""
        var syncDeviceID: String = UUID().uuidString
        var syncLastCursor: Int64 = 0
        var syncLastSyncAt: Date?
        var dataRepairVersion: Int = 0
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            theme: String = "system",
            hideEmptyKanbanColumns: Bool = false,
            defaultReminderLeadMinutes: Int = 15,
            syncEnabled: Bool = false,
            syncServerURL: String = "https://91.108.189.121:8443",
            syncCertificateFingerprint: String = "",
            syncDeviceID: String = UUID().uuidString,
            syncLastCursor: Int64 = 0,
            syncLastSyncAt: Date? = nil,
            dataRepairVersion: Int = 0,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.theme = theme
            self.hideEmptyKanbanColumns = hideEmptyKanbanColumns
            self.defaultReminderLeadMinutes = defaultReminderLeadMinutes
            self.syncEnabled = syncEnabled
            self.syncServerURL = syncServerURL
            self.syncCertificateFingerprint = syncCertificateFingerprint
            self.syncDeviceID = syncDeviceID
            self.syncLastCursor = syncLastCursor
            self.syncLastSyncAt = syncLastSyncAt
            self.dataRepairVersion = dataRepairVersion
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var appTheme: AppTheme {
            get { AppTheme(rawValue: theme) ?? .system }
            set { theme = newValue.rawValue }
        }
    }

    @Model final class SyncTombstone {
        var id: UUID = UUID()
        var entityType: String = ""
        var entityID: UUID = UUID()
        var clientUpdatedAt: Date = Date.now
        var createdAt: Date = Date.now

        init(
            id: UUID = UUID(),
            entityType: SyncEntityType,
            entityID: UUID,
            clientUpdatedAt: Date = .now,
            createdAt: Date = .now
        ) {
            self.id = id
            self.entityType = entityType.rawValue
            self.entityID = entityID
            self.clientUpdatedAt = clientUpdatedAt
            self.createdAt = createdAt
        }

        var syncEntityType: SyncEntityType? { SyncEntityType(rawValue: entityType) }
    }

    @Model final class SyncOutboxItem {
        @Attribute(.unique) var mutationID: UUID = UUID()
        var entityType: String = ""
        var entityID: String = ""
        var operation: String = SyncMutationOperation.upsert.rawValue
        var payloadJSON: String?
        var baseRevision: Int64 = 0
        var createdAt: Date = Date.now
        var attemptCount: Int = 0

        init(
            mutationID: UUID = UUID(),
            entityType: SyncEntityType,
            entityID: String,
            operation: SyncMutationOperation,
            payloadJSON: String?,
            baseRevision: Int64,
            createdAt: Date = .now
        ) {
            self.mutationID = mutationID
            self.entityType = entityType.rawValue
            self.entityID = entityID
            self.operation = operation.rawValue
            self.payloadJSON = payloadJSON
            self.baseRevision = baseRevision
            self.createdAt = createdAt
        }
    }

    @Model final class SyncEntityState {
        var id: UUID = UUID()
        var entityType: String = ""
        var entityID: String = ""
        var serverRevision: Int64 = 0
        var payloadHash: String = ""
        var updatedAt: Date = Date.now

        init(entityType: SyncEntityType, entityID: String, serverRevision: Int64, payloadHash: String = "") {
            self.entityType = entityType.rawValue
            self.entityID = entityID
            self.serverRevision = serverRevision
            self.payloadHash = payloadHash
        }
    }

    @Model final class SyncConflict {
        var id: UUID = UUID()
        var entityType: String = ""
        var entityID: String = ""
        var localPayloadJSON: String?
        var serverPayloadJSON: String?
        var serverRevision: Int64 = 0
        var createdAt: Date = Date.now
        var resolvedAt: Date?

        init(
            entityType: SyncEntityType,
            entityID: String,
            localPayloadJSON: String?,
            serverPayloadJSON: String?,
            serverRevision: Int64
        ) {
            self.entityType = entityType.rawValue
            self.entityID = entityID
            self.localPayloadJSON = localPayloadJSON
            self.serverPayloadJSON = serverPayloadJSON
            self.serverRevision = serverRevision
        }
    }
}

enum PlannerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PlannerSchemaV1.self, PlannerSchemaV2.self, PlannerSchemaV3.self, PlannerSchemaV4.self]
    }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: PlannerSchemaV1.self, toVersion: PlannerSchemaV2.self),
            .lightweight(fromVersion: PlannerSchemaV2.self, toVersion: PlannerSchemaV3.self),
            .lightweight(fromVersion: PlannerSchemaV3.self, toVersion: PlannerSchemaV4.self)
        ]
    }
}

enum PlannerSchema {
    static let models = PlannerSchemaV4.models
}

/// The third schema adds calendar-only events. Existing task and project model
/// types intentionally remain the V2 types so old stores can be migrated
/// lightweight without rewriting their relationships.
enum PlannerSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        PlannerSchemaV2.models + [CalendarEvent.self, CalendarEventException.self]
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
        init() {}
    }

    @Model final class CalendarEventException {
        @Attribute(.unique) var id: UUID = UUID()
        var eventID: UUID = UUID()
        var occurrenceDate: Date = Date.now
        var isDeleted: Bool = false
        var titleOverride: String?
        var notesOverride: String?
        var startOverride: Date?
        var endOverride: Date?
        var timeZoneIdentifierOverride: String?
        var reminderRawValueOverride: Int?
        var projectOverrideSet: Bool = false
        var project: PlannerSchemaV2.Project?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        init() {}
    }
}

/// V4 fixes the V3 exception flag's collision with PersistentModel.isDeleted.
/// `CalendarEventException.isSkipped` keeps V3's physical `isDeleted` column.
enum PlannerSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        PlannerSchemaV2.models + [CalendarEvent.self, CalendarEventException.self]
    }
}
