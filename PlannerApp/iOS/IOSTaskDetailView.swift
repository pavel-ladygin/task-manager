import SwiftData
import SwiftUI

#if os(iOS)
struct IOSTaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var task: PlannerTask
    let projects: [Project]
    let deleteTask: (PlannerTask) -> Void

    @State private var newChecklistTitle = ""
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Form {
            Section("Задача") {
                TextField("Название", text: $task.title)
                    .onChange(of: task.title) { _, _ in saveTaskChanges() }

                Picker("Статус", selection: statusBinding) {
                    ForEach(TaskStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                }

                Picker("Приоритет", selection: priorityBinding) {
                    ForEach(Priority.allCases) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }

                Picker("Повтор", selection: recurrenceBinding) {
                    ForEach(TaskRecurrence.allCases) { recurrence in
                        Text(recurrence.displayName).tag(recurrence)
                    }
                }

                Picker("Проект", selection: projectBinding) {
                    Text("Без проекта").tag(Optional<UUID>.none)
                    ForEach(projects) { project in
                        Text(project.title).tag(Optional(project.id))
                    }
                }
            }

            Section("Даты") {
                IOSOptionalDatePicker(title: "Запланировано", date: scheduledBinding)
                IOSOptionalDatePicker(title: "Срок", date: dueBinding)
            }

            Section("Чеклист") {
                ForEach(task.checklistItems.sorted { $0.order < $1.order }) { item in
                    IOSChecklistItemRow(
                        item: item,
                        task: task,
                        onError: { errorMessage = $0.localizedDescription }
                    )
                }
                .onDelete(perform: deleteChecklistItems)

                HStack {
                    TextField("Новый пункт чеклиста", text: $newChecklistTitle)
                        .submitLabel(.done)
                        .onSubmit(addChecklistItem)

                    Button(action: addChecklistItem) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Заметки") {
                TextEditor(text: $task.notes)
                    .frame(minHeight: 120)
                    .onChange(of: task.notes) { _, _ in saveTaskChanges() }
            }

            Section("Метаданные") {
                LabeledContent("Создана", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Обновлена", value: task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Завершена", value: task.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Не завершена")
            }

            Section("Удаление") {
                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Удалить задачу", systemImage: "trash")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .navigationTitle("Задача")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") {
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Удалить задачу?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                deleteTask(task)
                dismiss()
            }

            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Задача будет удалена с этого устройства и попадет в синхронизацию удаления.")
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusBinding: Binding<TaskStatus> {
        Binding(
            get: { task.status },
            set: { newValue in
                do {
                    try PlannerDataService.setTaskStatus(task, status: newValue, context: modelContext)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var priorityBinding: Binding<Priority> {
        Binding(
            get: { task.priority },
            set: { newValue in
                task.priority = newValue
                saveTaskChanges()
            }
        )
    }

    private var recurrenceBinding: Binding<TaskRecurrence> {
        Binding(
            get: { task.recurrence },
            set: { newValue in
                task.recurrence = newValue
                saveTaskChanges()
            }
        )
    }

    private var projectBinding: Binding<UUID?> {
        Binding(
            get: { task.project?.id },
            set: { newValue in
                task.project = projects.first { $0.id == newValue }
                saveTaskChanges()
            }
        )
    }

    private var scheduledBinding: Binding<Date?> {
        Binding(
            get: { task.scheduled },
            set: { newValue in
                task.scheduled = newValue
                saveTaskChanges()
            }
        )
    }

    private var dueBinding: Binding<Date?> {
        Binding(
            get: { task.due },
            set: { newValue in
                task.due = newValue
                saveTaskChanges()
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func addChecklistItem() {
        do {
            try PlannerDataService.createChecklistItem(
                title: newChecklistTitle,
                for: task,
                context: modelContext
            )
            newChecklistTitle = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChecklistItems(at offsets: IndexSet) {
        let items = task.checklistItems.sorted { $0.order < $1.order }

        do {
            for offset in offsets {
                try PlannerDataService.deleteChecklistItem(
                    items[offset],
                    from: task,
                    context: modelContext
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveTaskChanges() {
        do {
            try PlannerDataService.markTaskUpdated(task, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IOSOptionalDatePicker: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        Toggle(title, isOn: isEnabled)

        if date != nil {
            DatePicker(
                title,
                selection: concreteDate,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { date != nil },
            set: { enabled in
                date = enabled ? (date ?? .now) : nil
            }
        )
    }

    private var concreteDate: Binding<Date> {
        Binding(
            get: { date ?? .now },
            set: { date = $0 }
        )
    }
}

private struct IOSChecklistItemRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: ChecklistItem
    let task: PlannerTask
    let onError: (Error) -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: doneBinding)
                .labelsHidden()

            TextField("Пункт чеклиста", text: $item.title)
                .onChange(of: item.title) { _, newValue in
                    do {
                        try PlannerDataService.updateChecklistItemTitle(
                            item,
                            title: newValue,
                            task: task,
                            context: modelContext
                        )
                    } catch {
                        onError(error)
                    }
                }
        }
    }

    private var doneBinding: Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { newValue in
                do {
                    try PlannerDataService.setChecklistItemDone(
                        item,
                        isDone: newValue,
                        task: task,
                        context: modelContext
                    )
                } catch {
                    onError(error)
                }
            }
        )
    }
}
#endif
