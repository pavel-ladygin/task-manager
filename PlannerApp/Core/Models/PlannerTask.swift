import Foundation
import SwiftData

@Model
final class PlannerTask {
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

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        status: TaskStatus = .inbox,
        priority: Priority = .none,
        recurrence: TaskRecurrence = .none,
        scheduled: Date? = nil,
        due: Date? = nil,
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now,
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
