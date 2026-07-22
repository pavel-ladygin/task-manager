import Foundation
import SwiftData

@MainActor
enum PlannerDataService {
    @discardableResult
    static func createTask(
        title: String,
        context: ModelContext,
        project: Project? = nil,
        status: TaskStatus = .inbox,
        priority: Priority = .none,
        recurrence: TaskRecurrence = .none,
        notes: String = ""
    ) throws -> PlannerTask {
        let task = PlannerTask(
            title: validatedTitle(title),
            notes: notes,
            status: status,
            priority: priority,
            recurrence: recurrence,
            project: project
        )
        context.insert(task)
        try context.save()
        syncNotifications(for: task, context: context)
        return task
    }

    static func updateTask(
        _ task: PlannerTask,
        title: String,
        status: TaskStatus,
        priority: Priority,
        recurrence: TaskRecurrence? = nil,
        project: Project?,
        notes: String,
        scheduled: Date? = nil,
        due: Date? = nil,
        context: ModelContext
    ) throws {
        task.title = validatedTitle(title)
        updateTaskStatus(task, status: status)
        task.priority = priority
        if let recurrence {
            task.recurrence = recurrence
        }
        task.project = project
        task.notes = notes
        task.scheduled = scheduled
        task.due = due
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func setTaskStatus(
        _ task: PlannerTask,
        status: TaskStatus,
        context: ModelContext
    ) throws {
        updateTaskStatus(task, status: status)
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func moveTask(
        _ task: PlannerTask,
        to status: TaskStatus,
        after previousTask: PlannerTask?,
        before nextTask: PlannerTask?,
        context: ModelContext
    ) throws {
        updateTaskStatus(task, status: status)
        task.manualOrder = KanbanService.manualOrderBetween(previous: previousTask, next: nextTask)
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func rescheduleTask(
        _ task: PlannerTask,
        to scheduled: Date,
        context: ModelContext
    ) throws {
        let duration = scheduledIntervalDuration(for: task)
        task.scheduled = scheduled

        if let duration {
            task.due = scheduled.addingTimeInterval(duration)
        }

        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func setTaskDue(
        _ task: PlannerTask,
        to due: Date?,
        context: ModelContext
    ) throws {
        task.due = due
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func markTaskUpdated(_ task: PlannerTask, context: ModelContext) throws {
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    @discardableResult
    static func createChecklistItem(
        title: String,
        for task: PlannerTask,
        context: ModelContext
    ) throws -> ChecklistItem {
        let nextOrder = (task.checklistItems.map(\.order).max() ?? -1) + 1
        let item = ChecklistItem(
            title: validatedTitle(title),
            order: nextOrder
        )
        context.insert(item)
        task.checklistItems.append(item)
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
        return item
    }

    static func updateChecklistItemTitle(
        _ item: ChecklistItem,
        title: String,
        task: PlannerTask,
        context: ModelContext
    ) throws {
        item.title = validatedTitle(title)
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func setChecklistItemDone(
        _ item: ChecklistItem,
        isDone: Bool,
        task: PlannerTask,
        context: ModelContext
    ) throws {
        item.isDone = isDone
        task.updatedAt = .now
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func deleteChecklistItem(
        _ item: ChecklistItem,
        from task: PlannerTask,
        context: ModelContext
    ) throws {
        task.checklistItems.removeAll { $0.id == item.id }
        task.updatedAt = .now
        context.delete(item)
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func deleteTask(_ task: PlannerTask, context: ModelContext) throws {
        try deleteTask(task, context: context, saveImmediately: true)
    }

    @discardableResult
    static func deleteCompletedTasks(from tasks: [PlannerTask], context: ModelContext) throws -> Int {
        let completedTasks = tasks.filter { $0.status == .done }

        for task in completedTasks {
            try deleteTask(task, context: context, saveImmediately: false)
        }

        if !completedTasks.isEmpty {
            try context.save()
        }

        return completedTasks.count
    }

    private static func deleteTask(
        _ task: PlannerTask,
        context: ModelContext,
        saveImmediately: Bool
    ) throws {
        recordTombstone(entityType: .task, entityID: task.id, context: context)
        NotificationService.cancelNotifications(for: task)
        task.checklistItems.forEach { context.delete($0) }
        task.checklistItems.removeAll()
        context.delete(task)

        if saveImmediately {
            try context.save()
        }
    }

    @discardableResult
    static func createProject(
        title: String,
        context: ModelContext,
        status: ProjectStatus = .active,
        deadline: Date? = nil,
        notes: String = ""
    ) throws -> Project {
        let project = Project(
            title: validatedTitle(title),
            status: status,
            deadline: deadline,
            notes: notes
        )
        context.insert(project)
        try context.save()
        return project
    }

    static func updateProject(
        _ project: Project,
        title: String,
        status: ProjectStatus,
        deadline: Date? = nil,
        notes: String,
        context: ModelContext
    ) throws {
        project.title = validatedTitle(title)
        project.status = status
        project.deadline = deadline
        project.notes = notes
        project.updatedAt = .now
        try context.save()
    }

    static func markProjectUpdated(_ project: Project, context: ModelContext) throws {
        project.updatedAt = .now
        try context.save()
    }

    static func setProjectColor(
        _ color: ProjectColorPreset,
        project: Project,
        context: ModelContext
    ) throws {
        project.colorPreset = color
        project.updatedAt = .now
        try context.save()
    }

    static func deleteProject(_ project: Project, context: ModelContext) throws {
        recordTombstone(entityType: .project, entityID: project.id, context: context)
        context.delete(project)
        try context.save()
    }

    @discardableResult
    static func ensureAppSettings(context: ModelContext) throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        if let settings = try context.fetch(descriptor).first {
            return settings
        }

        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        return settings
    }

    static func setHideEmptyKanbanColumns(
        _ isHidden: Bool,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.hideEmptyKanbanColumns = isHidden
        settings.updatedAt = .now
        try context.save()
    }

    static func setTheme(
        _ theme: AppTheme,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.appTheme = theme
        settings.updatedAt = .now
        try context.save()
    }

    static func setDefaultReminderLeadMinutes(
        _ minutes: Int,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.defaultReminderLeadMinutes = max(0, minutes)
        settings.updatedAt = .now
        try context.save()

        let tasks = try context.fetch(FetchDescriptor<PlannerTask>())
        tasks.forEach { syncNotifications(for: $0, context: context) }
    }

    static func setSyncEnabled(
        _ isEnabled: Bool,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.syncEnabled = isEnabled
        settings.updatedAt = .now
        try context.save()
    }

    static func setSyncServerURL(
        _ serverURL: String,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.syncServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.updatedAt = .now
        try context.save()
    }

    static func setSyncCertificateFingerprint(
        _ fingerprint: String,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.syncCertificateFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.updatedAt = .now
        try context.save()
    }

    private static func updateTaskStatus(_ task: PlannerTask, status: TaskStatus) {
        let previousStatus = task.status
        task.status = status

        if previousStatus != .done, status == .done {
            task.completedAt = .now
        } else if previousStatus == .done, status != .done {
            task.completedAt = nil
        }
    }

    private static func validatedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Без названия" : trimmed
    }

    private static func scheduledIntervalDuration(for task: PlannerTask) -> TimeInterval? {
        guard
            let scheduled = task.scheduled,
            let due = task.due,
            due > scheduled,
            Calendar.current.isDate(due, inSameDayAs: scheduled)
        else {
            return nil
        }

        return due.timeIntervalSince(scheduled)
    }

    private static func recordTombstone(
        entityType: SyncEntityType,
        entityID: UUID,
        context: ModelContext
    ) {
        let now = Date.now
        context.insert(SyncTombstone(
            entityType: entityType,
            entityID: entityID,
            clientUpdatedAt: now,
            createdAt: now
        ))
    }

    private static func syncNotifications(for task: PlannerTask, context: ModelContext) {
        guard let settings = try? ensureAppSettings(context: context) else {
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
