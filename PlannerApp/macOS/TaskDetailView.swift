import SwiftUI

#if os(macOS)
struct TaskDetailView: View {
    @ObservedObject var session: TaskEditorSession
    let projects: [Project]
    let saveAndClose: () -> Void
    let discardAndClose: () -> Void
    let deleteTask: (PlannerTask) -> Void

    @State private var newChecklistTitle = ""
    @State private var confirmation: Confirmation?

    private enum Confirmation {
        case cancel
        case delete
    }

    var body: some View {
        Form {
            Section("Задача") {
                TextField("Название", text: $session.draft.title)

                Picker("Статус", selection: $session.draft.status) {
                    ForEach(TaskStatus.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Приоритет", selection: $session.draft.priority) {
                    ForEach(Priority.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Повтор", selection: $session.draft.recurrence) {
                    ForEach(TaskRecurrence.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Проект", selection: $session.draft.projectID) {
                    Text("Без проекта").tag(Optional<UUID>.none)
                    ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                }
                Toggle("Показывать в канбане", isOn: $session.draft.showInKanban)
            }

            Section("Даты") {
                OptionalDatePicker(title: "Запланировано", date: $session.draft.scheduled)
                OptionalDatePicker(title: "Срок", date: $session.draft.due)
                if session.draft.recurrence != .none,
                   session.draft.scheduled == nil,
                   session.draft.due == nil {
                    Label("Для повторения нужна хотя бы одна дата", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PlannerTheme.warning)
                }
            }

            Section("Чеклист") {
                ForEach($session.draft.checklistItems) { $item in
                    HStack {
                        Toggle("", isOn: $item.isDone).labelsHidden()
                        TextField("Пункт чеклиста", text: $item.title)
                    }
                }
                .onDelete { session.draft.checklistItems.remove(atOffsets: $0) }

                HStack {
                    TextField("Новый пункт чеклиста", text: $newChecklistTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addChecklistItem)
                    Button(action: addChecklistItem) { Image(systemName: "plus") }
                        .disabled(newChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Заметки") {
                TextEditor(text: $session.draft.notes).frame(minHeight: 140)
            }

            Section("Метаданные") {
                LabeledContent("Создана", value: session.task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Обновлена", value: session.task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Завершена", value: session.task.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Не завершена")
                if session.isDirty {
                    Label("Есть несохранённые изменения", systemImage: "pencil.circle")
                }
            }

            Section("Удаление") {
                Button(role: .destructive) { confirmation = .delete } label: {
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
                Button("Отмена") {
                    session.isDirty ? (confirmation = .cancel) : discardAndClose()
                }
                Button("Сохранить", action: saveAndClose)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding) {
            if confirmation == .delete {
                Button("Удалить", role: .destructive) { deleteTask(session.task) }
            } else {
                Button("Отбросить изменения", role: .destructive, action: discardAndClose)
            }
            Button("Остаться", role: .cancel) {}
        } message: {
            if confirmation == .delete {
                Text("Задача будет удалена с этого устройства и попадет в синхронизацию удаления.")
            } else {
                Text("Несохранённые изменения будут потеряны.")
            }
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) { session.clearError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .onChange(of: session.task.id) { _, _ in
            newChecklistTitle = ""
            confirmation = nil
        }
    }

    private var confirmationTitle: String {
        confirmation == .delete ? "Удалить задачу?" : "Отбросить изменения?"
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.clearError() } })
    }

    private func addChecklistItem() {
        let title = newChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        session.draft.checklistItems.append(
            ChecklistItemDraft(title: title, order: session.draft.checklistItems.count)
        )
        newChecklistTitle = ""
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
