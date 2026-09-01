import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct IOSKanbanView: View {
    let columns: [KanbanColumn]
    let projects: [Project]
    @Binding var searchText: String
    let createTask: (String, TaskStatus) -> Void
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void
    let openTask: (PlannerTask) -> Void
    let completeTask: (PlannerTask) -> Void

    @State private var selectedProjectID: UUID?
    @State private var selectedPriority: Priority?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(filteredColumns) { column in
                    IOSKanbanColumnView(
                        column: column,
                        allColumns: filteredColumns,
                        createTask: createTask,
                        moveTask: moveTask,
                        openTask: openTask,
                        completeTask: completeTask
                    )
                    .frame(width: 292)
                }
            }
            .padding()
            .frame(minHeight: 520, alignment: .topLeading)
        }
        .navigationTitle("Канбан")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Все проекты") { selectedProjectID = nil }
                    ForEach(projects) { project in
                        Button(project.title) { selectedProjectID = project.id }
                    }
                } label: {
                    Label("Проект", systemImage: "folder")
                }
                Menu {
                    Button("Любой приоритет") { selectedPriority = nil }
                    ForEach(Priority.allCases) { priority in
                        Button(priority.displayName) { selectedPriority = priority }
                    }
                } label: {
                    Label("Приоритет", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Поиск")
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .overlay {
            if columns.allSatisfy(\.tasks.isEmpty) {
                ContentUnavailableView(
                    isSearching ? "Ничего не найдено" : "Нет карточек",
                    systemImage: "rectangle.3.group",
                    description: Text(isSearching ? "Попробуйте изменить запрос." : "Задачи появятся здесь как карточки по статусам.")
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var filteredColumns: [KanbanColumn] {
        columns.map { column in
            KanbanColumn(
                status: column.status,
                title: column.title,
                tasks: column.tasks.filter { task in
                    (selectedProjectID == nil || task.project?.id == selectedProjectID)
                        && (selectedPriority == nil || task.priority == selectedPriority)
                }
            )
        }
    }
}

private struct IOSKanbanColumnView: View {
    let column: KanbanColumn
    let allColumns: [KanbanColumn]
    let createTask: (String, TaskStatus) -> Void
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void
    let openTask: (PlannerTask) -> Void
    let completeTask: (PlannerTask) -> Void
    @EnvironmentObject private var voiceInputController: TaskVoiceInputController
    @State private var quickTitle = ""
    @State private var targetedTaskID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(column.title)
                    .font(.headline)

                Spacer()

                Text("\(column.tasks.count)")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(PlannerTheme.elevatedBackground, in: Capsule())
            }

            VStack(spacing: 8) {
                ForEach(Array(column.tasks.enumerated()), id: \.element.id) { index, task in
                    if targetedTaskID == task.id {
                        RoundedRectangle(cornerRadius: 2).fill(PlannerTheme.accent).frame(height: 3)
                    }
                    IOSKanbanCardView(
                        task: task,
                        openTask: { openTask(task) },
                        completeTask: completeTask
                    )
                    .onDrop(
                        of: [.plainText],
                        isTargeted: Binding(
                            get: { targetedTaskID == task.id },
                            set: { targetedTaskID = $0 ? task.id : nil }
                        )
                    ) { providers in
                        loadTask(from: providers) { dropped in
                            guard dropped.id != task.id else { return }
                            let withoutDropped = column.tasks.filter { $0.id != dropped.id }
                            let targetIndex = withoutDropped.firstIndex { $0.id == task.id }
                                ?? min(index, withoutDropped.count)
                            let previous = targetIndex > 0 ? withoutDropped[targetIndex - 1] : nil
                            let next = targetIndex < withoutDropped.count ? withoutDropped[targetIndex] : nil
                            moveTask(dropped, column.status, previous, next)
                            targetedTaskID = nil
                        }
                        return true
                    }
                    .contextMenu {
                        if index > 0 {
                            Button("Переместить выше") {
                                let next = column.tasks[index - 1]
                                let previous = index > 1 ? column.tasks[index - 2] : nil
                                moveTask(task, column.status, previous, next)
                            }
                        }
                        if index + 1 < column.tasks.count {
                            Button("Переместить ниже") {
                                let previous = column.tasks[index + 1]
                                let next = index + 2 < column.tasks.count ? column.tasks[index + 2] : nil
                                moveTask(task, column.status, previous, next)
                            }
                        }
                        ForEach(TaskStatus.allCases.filter { $0 != column.status }) { status in
                            Button("В \(status.displayName)") { moveTask(task, status, nil, nil) }
                        }
                    }
                }

                if column.tasks.isEmpty {
                    Text("Перетащите задачи сюда")
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(PlannerTheme.rowBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
                        )
                }

                HStack {
                    TextField("Новая задача", text: $quickTitle).onSubmit(addTask)
                    TaskVoiceInputButton(fieldID: voiceFieldID, text: $quickTitle)
                    Button(action: addTask) { Image(systemName: "plus.circle.fill") }
                        .disabled(quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            loadTask(from: providers) { droppedTask in
                moveTask(
                    droppedTask,
                    column.status,
                    lastTask(excluding: droppedTask),
                    nil
                )
            }

            return true
        }
        .background(PlannerTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
        )
    }

    private func addTask() {
        voiceInputController.stop(ifActive: voiceFieldID)
        let title = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        createTask(title, column.status)
        quickTitle = ""
    }

    private var voiceFieldID: String {
        "ios.kanban.\(column.status.rawValue)"
    }

    private func lastTask(excluding task: PlannerTask) -> PlannerTask? {
        column.tasks.filter { $0.id != task.id }.last
    }

    private func loadTask(
        from providers: [NSItemProvider],
        completion: @escaping (PlannerTask) -> Void
    ) {
        guard let provider = providers.first else {
            return
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let rawID = object as? String,
                let taskID = UUID(uuidString: rawID)
            else {
                return
            }

            DispatchQueue.main.async {
                guard let task = allColumns.flatMap(\.tasks).first(where: { $0.id == taskID }) else {
                    return
                }

                completion(task)
            }
        }
    }
}

private struct IOSKanbanCardView: View {
    let task: PlannerTask
    let openTask: () -> Void
    let completeTask: (PlannerTask) -> Void
    @State private var suppressOpenUntil = Date.distantPast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                completeTask(task)
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? PlannerTheme.success : PlannerTheme.secondaryText)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(task.status == .done)

            Button {
                guard Date.now >= suppressOpenUntil else { return }
                openTask()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(task.priority.displayName)
                            .foregroundStyle(priorityColor)

                        if let projectTitle = task.project?.title {
                            Text(projectTitle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .lineLimit(1)

                    if let scheduled = task.scheduled {
                        Label(scheduled.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(PlannerTheme.secondaryText)
                            .lineLimit(1)
                    }

                    if let due = task.due {
                        Label("Срок \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "flag")
                            .font(.caption)
                            .foregroundStyle(PlannerTheme.danger)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .onDrag {
            suppressOpenUntil = Date.now.addingTimeInterval(3)
            return NSItemProvider(object: task.id.uuidString as NSString)
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .urgent, .high:
            PlannerTheme.warning
        case .medium:
            PlannerTheme.accent
        case .low, .none:
            PlannerTheme.secondaryText
        }
    }

    private var cardBackground: AnyShapeStyle {
        if let preset = task.project?.colorPreset {
            return AnyShapeStyle(PlannerTheme.projectGradient(preset, opacity: 0.20))
        }

        return AnyShapeStyle(PlannerTheme.elevatedBackground)
    }

    private var borderColor: Color {
        if let preset = task.project?.colorPreset {
            return PlannerTheme.projectAccent(preset).opacity(0.42)
        }

        return PlannerTheme.border
    }
}
#endif
