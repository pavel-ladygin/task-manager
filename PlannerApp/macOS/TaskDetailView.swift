import SwiftData
import SwiftUI

#if os(macOS)
struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let task: PlannerTask
    let projects: [Project]
    let deleteTask: (PlannerTask) -> Void

    @State private var editingTask: PlannerTask
    @State private var draft: TaskDraft
    @State private var newChecklistTitle = ""
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var pendingTask: PlannerTask?
    @State private var isSwitchConfirmationPresented = false

    init(task: PlannerTask, projects: [Project], deleteTask: @escaping (PlannerTask) -> Void) {
        self.task = task
        self.projects = projects
        self.deleteTask = deleteTask
        _editingTask = State(initialValue: task)
        _draft = State(initialValue: TaskDraft(task: task))
    }

    private var isDirty: Bool { draft != TaskDraft(task: editingTask) }

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
                OptionalDatePicker(title: "Запланировано", date: $draft.scheduled)
                OptionalDatePicker(title: "Срок", date: $draft.due)
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
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addChecklistItem)
                    Button(action: addChecklistItem) { Image(systemName: "plus") }
                        .disabled(newChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Заметки") {
                TextEditor(text: $draft.notes).frame(minHeight: 140)
            }

            Section("Метаданные") {
                LabeledContent("Создана", value: editingTask.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Обновлена", value: editingTask.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Завершена", value: editingTask.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Не завершена")
                if isDirty { Label("Есть несохранённые изменения", systemImage: "pencil.circle") }
            }

            Section("Удаление") {
                Button(role: .destructive) { isDeleteConfirmationPresented = true } label: {
                    Label("Удалить задачу", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .navigationTitle("Параметры задачи")
        .toolbar {
            ToolbarItemGroup {
                Button("Отмена", action: resetDraft).disabled(!isDirty)
                Button("Сохранить") { _ = save() }.keyboardShortcut("s", modifiers: .command).disabled(!isDirty)
            }
        }
        .onChange(of: task.id) { _, _ in
            if isDirty {
                pendingTask = task
                isSwitchConfirmationPresented = true
            } else {
                adopt(task)
            }
        }
        .confirmationDialog("Удалить задачу?", isPresented: $isDeleteConfirmationPresented) {
            Button("Удалить", role: .destructive) { deleteTask(editingTask) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Задача будет удалена с этого устройства и попадет в синхронизацию удаления.")
        }
        .confirmationDialog("Сохранить изменения перед переходом?", isPresented: $isSwitchConfirmationPresented) {
            Button("Сохранить") {
                if save(), let pendingTask { adopt(pendingTask) }
            }
            Button("Отбросить", role: .destructive) {
                if let pendingTask { adopt(pendingTask) }
            }
            Button("Остаться", role: .cancel) { pendingTask = nil }
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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

    @discardableResult
    private func save() -> Bool {
        do {
            try PlannerDataService.saveTask(editingTask, draft: draft, projects: projects, context: modelContext)
            resetDraft()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resetDraft() { draft = TaskDraft(task: editingTask) }
    private func adopt(_ task: PlannerTask) {
        editingTask = task
        draft = TaskDraft(task: task)
        pendingTask = nil
    }
}

private struct OptionalDatePicker: View {
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
