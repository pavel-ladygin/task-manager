import SwiftData
import SwiftUI

#if os(iOS)
struct IOSTaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let task: PlannerTask
    let projects: [Project]
    let deleteTask: (PlannerTask) -> Void

    @State private var draft: TaskDraft
    @State private var newChecklistTitle = ""
    @State private var errorMessage: String?
    @State private var confirmation: Confirmation?

    private enum Confirmation { case cancel, delete }

    init(task: PlannerTask, projects: [Project], deleteTask: @escaping (PlannerTask) -> Void) {
        self.task = task
        self.projects = projects
        self.deleteTask = deleteTask
        _draft = State(initialValue: TaskDraft(task: task))
    }

    private var isDirty: Bool { draft != TaskDraft(task: task) }

    var body: some View {
        Form {
            Section("Задача") {
                TextField("Название", text: $draft.title)
                Picker("Статус", selection: $draft.status) {
                    ForEach(TaskStatus.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Приоритет", selection: $draft.priority) {
                    ForEach(Priority.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Повтор", selection: $draft.recurrence) {
                    ForEach(TaskRecurrence.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Проект", selection: $draft.projectID) {
                    Text("Без проекта").tag(Optional<UUID>.none)
                    ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                }
                Toggle("Показывать в канбане", isOn: $draft.showInKanban)
            }

            Section("Даты") {
                IOSOptionalDatePicker(title: "Запланировано", date: $draft.scheduled)
                IOSOptionalDatePicker(title: "Срок", date: $draft.due)
                if draft.recurrence != .none, draft.scheduled == nil, draft.due == nil {
                    Label("Для повторения нужна хотя бы одна дата", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PlannerTheme.warning)
                }
            }

            Section("Чеклист") {
                ForEach($draft.checklistItems) { $item in
                    HStack {
                        Toggle("", isOn: $item.isDone).labelsHidden()
                        TextField("Пункт чеклиста", text: $item.title)
                    }
                }
                .onDelete { draft.checklistItems.remove(atOffsets: $0) }

                HStack {
                    TextField("Новый пункт чеклиста", text: $newChecklistTitle)
                        .submitLabel(.done).onSubmit(addChecklistItem)
                    Button(action: addChecklistItem) { Image(systemName: "plus.circle.fill") }
                        .disabled(newChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Заметки") { TextEditor(text: $draft.notes).frame(minHeight: 120) }

            Section("Метаданные") {
                LabeledContent("Создана", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Обновлена", value: task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Завершена", value: task.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Не завершена")
            }

            Section {
                Button(role: .destructive) { confirmation = .delete } label: {
                    Label("Удалить задачу", systemImage: "trash")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .navigationTitle("Задача")
        .interactiveDismissDisabled(isDirty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { isDirty ? (confirmation = .cancel) : dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить", action: save).disabled(!isDirty)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
            if confirmation == .delete {
                Button("Удалить", role: .destructive) { deleteTask(task); dismiss() }
            } else {
                Button("Сохранить", action: save)
                Button("Отбросить изменения", role: .destructive) { dismiss() }
            }
            Button("Остаться", role: .cancel) {}
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var confirmationTitle: String {
        confirmation == .delete ? "Удалить задачу?" : "Отбросить изменения?"
    }
    private var confirmationBinding: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }
    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func addChecklistItem() {
        let title = newChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draft.checklistItems.append(ChecklistItemDraft(title: title, order: draft.checklistItems.count))
        newChecklistTitle = ""
    }
    private func save() {
        do {
            try PlannerDataService.saveTask(task, draft: draft, projects: projects, context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct IOSOptionalDatePicker: View {
    let title: String
    @Binding var date: Date?
    var body: some View {
        Toggle(title, isOn: isEnabled)
        if date != nil {
            DatePicker(title, selection: concreteDate, displayedComponents: [.date, .hourAndMinute])
        }
    }
    private var isEnabled: Binding<Bool> {
        Binding(get: { date != nil }, set: { date = $0 ? (date ?? .now) : nil })
    }
    private var concreteDate: Binding<Date> {
        Binding(get: { date ?? .now }, set: { date = $0 })
    }
}
#endif
