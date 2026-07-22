import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct IOSKanbanView: View {
    let columns: [KanbanColumn]
    let projects: [Project]
    @Binding var searchText: String
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void
    let completeTask: (PlannerTask) -> Void

    @State private var selectedTask: PlannerTask?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    IOSKanbanColumnView(
                        column: column,
                        allColumns: columns,
                        selectedTask: $selectedTask,
                        moveTask: moveTask,
                        completeTask: completeTask
                    )
                    .frame(width: 292)
                }
            }
            .padding()
            .frame(minHeight: 520, alignment: .topLeading)
        }
        .navigationTitle("Канбан")
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
        .sheet(item: $selectedTask) { task in
            NavigationStack {
                IOSTaskDetailView(task: task, projects: projects)
            }
        }
    }
}

private struct IOSKanbanColumnView: View {
    let column: KanbanColumn
    let allColumns: [KanbanColumn]
    @Binding var selectedTask: PlannerTask?
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void
    let completeTask: (PlannerTask) -> Void

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
                ForEach(column.tasks) { task in
                    IOSKanbanCardView(
                        task: task,
                        openTask: { selectedTask = task },
                        completeTask: completeTask
                    )
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
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(12)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { taskIDs, _ in
            guard
                let rawID = taskIDs.first,
                let droppedTask = task(for: rawID)
            else {
                return false
            }

            moveTask(
                droppedTask,
                column.status,
                lastTask(excluding: droppedTask),
                nil
            )
            return true
        }
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

    private func lastTask(excluding task: PlannerTask) -> PlannerTask? {
        column.tasks.filter { $0.id != task.id }.last
    }

    private func task(for rawID: String) -> PlannerTask? {
        guard let taskID = UUID(uuidString: rawID) else {
            return nil
        }

        return allColumns.flatMap(\.tasks).first { $0.id == taskID }
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

            Button(action: openTask) {
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
        .background(PlannerTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PlannerTheme.border, lineWidth: 0.5)
        )
        .draggable(task.id.uuidString)
        .onDrag {
            NSItemProvider(object: task.id.uuidString as NSString)
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
}
#endif
