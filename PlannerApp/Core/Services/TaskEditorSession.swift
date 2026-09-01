import Combine
import Foundation
import SwiftData

@MainActor
final class TaskEditorSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var task: PlannerTask
    @Published var draft: TaskDraft
    @Published var errorMessage: String?
    private var baselineDraft: TaskDraft

    var isDirty: Bool {
        draft != baselineDraft
    }

    private init(task: PlannerTask) {
        self.task = task
        let draft = TaskDraft(task: task)
        self.draft = draft
        baselineDraft = draft
    }

    static func open(_ task: PlannerTask) -> TaskEditorSession {
        TaskEditorSession(task: task)
    }

    func open(_ task: PlannerTask) {
        self.task = task
        let draft = TaskDraft(task: task)
        self.draft = draft
        baselineDraft = draft
        errorMessage = nil
    }

    @discardableResult
    func save(projects: [Project], context: ModelContext) -> Bool {
        guard isDirty else {
            errorMessage = nil
            return true
        }

        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Название задачи не может быть пустым."
            return false
        }

        do {
            try PlannerDataService.saveTask(
                task,
                draft: draft,
                projects: projects,
                context: context
            )
            let savedDraft = TaskDraft(task: task)
            draft = savedDraft
            baselineDraft = savedDraft
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveAndClose(
        projects: [Project],
        context: ModelContext,
        onClose: () -> Void
    ) -> Bool {
        guard save(projects: projects, context: context) else {
            return false
        }

        onClose()
        return true
    }

    func discardAndClose(onClose: () -> Void) {
        draft = baselineDraft
        errorMessage = nil
        onClose()
    }

    @discardableResult
    func saveAndSwitch(
        to task: PlannerTask,
        projects: [Project],
        context: ModelContext
    ) -> Bool {
        guard self.task.id != task.id else {
            return true
        }
        guard save(projects: projects, context: context) else {
            return false
        }

        open(task)
        return true
    }

    func refreshIfClean() {
        guard !isDirty else { return }
        let refreshedDraft = TaskDraft(task: task)
        draft = refreshedDraft
        baselineDraft = refreshedDraft
    }

    func clearError() {
        errorMessage = nil
    }
}
