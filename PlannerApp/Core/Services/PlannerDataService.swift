import Foundation
import SwiftData

struct ChecklistItemDraft: Identifiable, Equatable {
    var id: UUID
    var title: String
    var isDone: Bool
    var order: Int

    init(item: ChecklistItem) {
        id = item.id
        title = item.title
        isDone = item.isDone
        order = item.order
    }

    init(id: UUID = UUID(), title: String, isDone: Bool = false, order: Int) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.order = order
    }
}

struct TaskDraft: Equatable {
    var title: String
    var notes: String
    var status: TaskStatus
    var priority: Priority
    var recurrence: TaskRecurrence
    var projectID: UUID?
    var scheduled: Date?
    var due: Date?
    var showInKanban: Bool
    var checklistItems: [ChecklistItemDraft]
    let baseUpdatedAt: Date

    init(task: PlannerTask) {
        title = task.title
        notes = task.notes
        status = task.status
        priority = task.priority
        recurrence = task.recurrence
        projectID = task.project?.id
        scheduled = task.scheduled
        due = task.due
        showInKanban = task.showInKanban
        checklistItems = task.checklistItems.sorted { $0.order < $1.order }.map(ChecklistItemDraft.init)
        baseUpdatedAt = task.updatedAt
    }
}

struct ProjectDraft: Equatable {
    var title: String
    var status: ProjectStatus
    var color: ProjectColorPreset
    var deadline: Date?
    var notes: String
    let baseUpdatedAt: Date

    init(project: Project) {
        title = project.title
        status = project.status
        color = project.colorPreset
        deadline = project.deadline
        notes = project.notes
        baseUpdatedAt = project.updatedAt
    }
}

enum PlannerDataError: LocalizedError {
    case recurrenceRequiresDate
    case staleDraft

    var errorDescription: String? {
        switch self {
        case .recurrenceRequiresDate:
            "Для повторяющейся задачи укажите дату планирования или срок."
        case .staleDraft:
            "Объект изменился после открытия редактора. Закройте редактор и повторите изменения."
        }
    }
}

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
        try validateRecurrence(recurrence, scheduled: nil, due: nil)
        let task = PlannerTask(
            title: validatedTitle(title),
            notes: notes,
            status: status,
            priority: priority,
            recurrence: recurrence,
            project: project
        )
        context.insert(task)
        try SyncService.enqueueUpsert(task: task, context: context)
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
        showInKanban: Bool = true,
        context: ModelContext
    ) throws {
        try validateRecurrence(recurrence ?? task.recurrence, scheduled: scheduled, due: due)
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
        task.showInKanban = showInKanban
        task.updatedAt = .now
        try SyncService.enqueueUpsert(task: task, context: context)
        try context.save()
        syncNotifications(for: task, context: context)
    }

    @discardableResult
    static func setTaskStatus(
        _ task: PlannerTask,
        status: TaskStatus,
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> PlannerTask? {
        let previousStatus = task.status
        updateTaskStatus(task, status: status)
        task.updatedAt = now
        let nextTask = try nextRecurringTaskIfNeeded(
            for: task,
            previousStatus: previousStatus,
            context: context,
            now: now,
            calendar: calendar
        )
        try SyncService.enqueueUpsert(task: task, context: context)
        if let nextTask { try SyncService.enqueueUpsert(task: nextTask, context: context) }
        try context.save()
        syncNotifications(for: task, context: context)
        if let nextTask { syncNotifications(for: nextTask, context: context) }
        return nextTask
    }

    @discardableResult
    static func saveTask(
        _ task: PlannerTask,
        draft: TaskDraft,
        projects: [Project],
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> PlannerTask? {
        guard task.updatedAt == draft.baseUpdatedAt else { throw PlannerDataError.staleDraft }
        try validateRecurrence(draft.recurrence, scheduled: draft.scheduled, due: draft.due)

        let previousStatus = task.status
        let scheduleChanged = task.recurrence != draft.recurrence
            || task.scheduled != draft.scheduled
            || task.due != draft.due

        task.title = validatedTitle(draft.title)
        task.notes = draft.notes
        task.priority = draft.priority
        task.project = projects.first { $0.id == draft.projectID }
        task.scheduled = draft.scheduled
        task.due = draft.due
        task.showInKanban = draft.showInKanban
        task.recurrence = draft.recurrence
        updateTaskStatus(task, status: draft.status)

        if draft.recurrence == .none {
            task.recurrenceSeriesID = nil
            task.recurrenceAnchorDate = nil
            task.recurrenceSequence = 0
        } else if scheduleChanged || task.recurrenceSeriesID == nil {
            task.recurrenceSeriesID = UUID()
            task.recurrenceAnchorDate = draft.scheduled ?? draft.due
            task.recurrenceSequence = 0
        }

        try reconcileChecklist(task: task, drafts: draft.checklistItems, context: context)
        task.updatedAt = now
        let nextTask = try nextRecurringTaskIfNeeded(
            for: task,
            previousStatus: previousStatus,
            context: context,
            now: now,
            calendar: calendar
        )
        try SyncService.enqueueUpsert(task: task, context: context)
        if let nextTask { try SyncService.enqueueUpsert(task: nextTask, context: context) }
        try context.save()
        syncNotifications(for: task, context: context)
        if let nextTask { syncNotifications(for: nextTask, context: context) }
        return nextTask
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
        if KanbanService.shouldNormalize(previous: previousTask, next: nextTask) {
            let tasks = try context.fetch(FetchDescriptor<PlannerTask>()).filter { $0.status == status }
            KanbanService.normalize(tasks)
            for normalizedTask in tasks {
                normalizedTask.updatedAt = .now
                try SyncService.enqueueUpsert(task: normalizedTask, context: context)
            }
        } else {
            try SyncService.enqueueUpsert(task: task, context: context)
        }
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
        try SyncService.enqueueUpsert(task: task, context: context)
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
        try SyncService.enqueueUpsert(task: task, context: context)
        try context.save()
        syncNotifications(for: task, context: context)
    }

    static func markTaskUpdated(_ task: PlannerTask, context: ModelContext) throws {
        task.updatedAt = .now
        try SyncService.enqueueUpsert(task: task, context: context)
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
        try SyncService.enqueueUpsert(task: task, context: context)
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
        try SyncService.enqueueUpsert(task: task, context: context)
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
        try SyncService.enqueueUpsert(task: task, context: context)
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
        try SyncService.enqueueUpsert(task: task, context: context)
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
        try SyncService.enqueueDelete(type: .task, entityID: task.id, context: context)
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
        try SyncService.enqueueUpsert(project: project, context: context)
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
        try SyncService.enqueueUpsert(project: project, context: context)
        try context.save()
    }

    static func saveProject(
        _ project: Project,
        draft: ProjectDraft,
        context: ModelContext
    ) throws {
        guard project.updatedAt == draft.baseUpdatedAt else { throw PlannerDataError.staleDraft }
        project.title = validatedTitle(draft.title)
        project.status = draft.status
        project.colorPreset = draft.color
        project.deadline = draft.deadline
        project.notes = draft.notes
        project.updatedAt = .now
        try SyncService.enqueueUpsert(project: project, context: context)
        try context.save()
    }

    static func markProjectUpdated(_ project: Project, context: ModelContext) throws {
        project.updatedAt = .now
        try SyncService.enqueueUpsert(project: project, context: context)
        try context.save()
    }

    static func setProjectColor(
        _ color: ProjectColorPreset,
        project: Project,
        context: ModelContext
    ) throws {
        project.colorPreset = color
        project.updatedAt = .now
        try SyncService.enqueueUpsert(project: project, context: context)
        try context.save()
    }

    static func deleteProject(_ project: Project, context: ModelContext) throws {
        let affectedTasks = try context.fetch(FetchDescriptor<PlannerTask>()).filter { $0.project?.id == project.id }
        for task in affectedTasks {
            task.project = nil
            task.updatedAt = .now
            try SyncService.enqueueUpsert(task: task, context: context)
        }
        // Calendar events are independent from tasks; deleting a project only
        // removes their project colour/link and keeps the schedule entries.
        let affectedEvents = try context.fetch(FetchDescriptor<CalendarEvent>()).filter { $0.project?.id == project.id }
        for event in affectedEvents {
            event.project = nil
            event.updatedAt = .now
            try SyncService.enqueueUpsert(event: event, context: context)
        }
        let affectedExceptions = try context.fetch(FetchDescriptor<CalendarEventException>()).filter { $0.project?.id == project.id }
        for exception in affectedExceptions {
            exception.project = nil
            exception.projectOverrideSet = true
            exception.updatedAt = .now
            try SyncService.enqueueUpsert(exception: exception, context: context)
        }
        try SyncService.enqueueDelete(type: .project, entityID: project.id, context: context)
        context.delete(project)
        try context.save()
    }

    @discardableResult
    static func ensureAppSettings(context: ModelContext) throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        if let settings = try context.fetch(descriptor).first {
            try performV2DataRepairIfNeeded(settings: settings, context: context)
            return settings
        }

        let settings = AppSettings(dataRepairVersion: 1)
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
        try SyncService.enqueueUpsert(settings: settings, context: context)
        try context.save()
    }

    static func setTheme(
        _ theme: AppTheme,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.appTheme = theme
        settings.updatedAt = .now
        try SyncService.enqueueUpsert(settings: settings, context: context)
        try context.save()
    }

    static func setDefaultReminderLeadMinutes(
        _ minutes: Int,
        settings: AppSettings,
        context: ModelContext
    ) throws {
        settings.defaultReminderLeadMinutes = max(0, minutes)
        settings.updatedAt = .now
        try SyncService.enqueueUpsert(settings: settings, context: context)
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

    private static func validateRecurrence(
        _ recurrence: TaskRecurrence,
        scheduled: Date?,
        due: Date?
    ) throws {
        if recurrence != .none, scheduled == nil, due == nil {
            throw PlannerDataError.recurrenceRequiresDate
        }
    }

    private static func reconcileChecklist(
        task: PlannerTask,
        drafts: [ChecklistItemDraft],
        context: ModelContext
    ) throws {
        let draftIDs = Set(drafts.map(\.id))
        let removed = task.checklistItems.filter { !draftIDs.contains($0.id) }
        removed.forEach(context.delete)

        let existing = Dictionary(uniqueKeysWithValues: task.checklistItems.map { ($0.id, $0) })
        task.checklistItems = drafts.enumerated().map { index, draft in
            if let item = existing[draft.id] {
                item.title = validatedTitle(draft.title)
                item.isDone = draft.isDone
                item.order = index
                return item
            }
            let item = ChecklistItem(
                id: draft.id,
                title: validatedTitle(draft.title),
                isDone: draft.isDone,
                order: index
            )
            context.insert(item)
            return item
        }
    }

    private static func nextRecurringTaskIfNeeded(
        for task: PlannerTask,
        previousStatus: TaskStatus,
        context: ModelContext,
        now: Date,
        calendar: Calendar
    ) throws -> PlannerTask? {
        guard previousStatus != .done, task.status == .done, task.recurrence != .none else { return nil }
        guard let sourceAnchor = task.recurrenceAnchorDate ?? task.scheduled ?? task.due else {
            throw PlannerDataError.recurrenceRequiresDate
        }

        let seriesID = task.recurrenceSeriesID ?? UUID()
        task.recurrenceSeriesID = seriesID
        task.recurrenceAnchorDate = sourceAnchor

        let tasks = try context.fetch(FetchDescriptor<PlannerTask>())
        if let existingNext = tasks
            .filter({ $0.recurrenceSeriesID == seriesID && $0.recurrenceSequence > task.recurrenceSequence })
            .min(by: { $0.recurrenceSequence < $1.recurrenceSequence }) {
            return existingNext
        }

        let result = try RecurrenceService.nextOccurrence(
            recurrence: task.recurrence,
            anchor: sourceAnchor,
            after: now,
            startingSequence: task.recurrenceSequence + 1,
            calendar: calendar
        )

        if let existing = tasks.first(where: {
            $0.recurrenceSeriesID == seriesID && $0.recurrenceSequence == result.sequence
        }) {
            return existing
        }

        let anchorWasScheduled = task.scheduled != nil
        let interval = task.scheduled.flatMap { scheduled in task.due.map { $0.timeIntervalSince(scheduled) } }
        let nextScheduled = anchorWasScheduled ? result.date : nil
        let nextDue: Date?
        if anchorWasScheduled, let interval {
            nextDue = result.date.addingTimeInterval(interval)
        } else if task.due != nil {
            nextDue = result.date
        } else {
            nextDue = nil
        }

        let copiedChecklist = task.checklistItems
            .filter { !$0.isDone }
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, item in
                ChecklistItem(title: item.title, order: index)
            }
        copiedChecklist.forEach(context.insert)

        let plannedTasks = tasks.filter { $0.status == .planned }
        let nextTask = PlannerTask(
            title: task.title,
            notes: task.notes,
            status: .planned,
            priority: task.priority,
            recurrence: task.recurrence,
            recurrenceSeriesID: seriesID,
            recurrenceAnchorDate: sourceAnchor,
            recurrenceSequence: result.sequence,
            showInKanban: task.showInKanban,
            scheduled: nextScheduled,
            due: nextDue,
            createdAt: now,
            updatedAt: now,
            project: task.project,
            tags: task.tags,
            checklistItems: copiedChecklist,
            manualOrder: KanbanService.nextManualOrder(in: plannedTasks)
        )
        context.insert(nextTask)
        return nextTask
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

    private static func performV2DataRepairIfNeeded(
        settings: AppSettings,
        context: ModelContext
    ) throws {
        guard settings.dataRepairVersion < 1 else { return }
        let tasks = try context.fetch(FetchDescriptor<PlannerTask>())
        for task in tasks {
            let wasLegacyHidden = task.project?.title.trimmingCharacters(in: .whitespacesAndNewlines) == "Дни рождения"
                || task.tags.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == "Дни рождения" }
            if wasLegacyHidden { task.showInKanban = false }

            if task.recurrence != .none {
                guard let anchor = task.scheduled ?? task.due else {
                    task.recurrence = .none
                    task.recurrenceSeriesID = nil
                    task.recurrenceAnchorDate = nil
                    task.recurrenceSequence = 0
                    continue
                }
                task.recurrenceSeriesID = task.recurrenceSeriesID ?? UUID()
                task.recurrenceAnchorDate = task.recurrenceAnchorDate ?? anchor
            }
        }
        settings.dataRepairVersion = 1
        settings.updatedAt = .now
        try context.save()
    }
}
