import SwiftUI

#if os(iOS)
struct IOSTaskListView: View {
    let title: String
    let systemImage: String
    let tasks: [PlannerTask]
    let sections: [UpcomingSection]
    let controls: AnyView?
    let projects: [Project]
    @Binding var searchText: String
    let createTask: (String) -> Void
    let deleteTask: ((PlannerTask) -> Void)?
    let completeTask: (PlannerTask) -> Void

    @State private var newTaskTitle = ""
    @State private var selectedTask: PlannerTask?

    init(
        title: String,
        systemImage: String,
        tasks: [PlannerTask],
        sections: [UpcomingSection] = [],
        controls: AnyView? = nil,
        projects: [Project],
        searchText: Binding<String>,
        createTask: @escaping (String) -> Void,
        deleteTask: @escaping (PlannerTask) -> Void,
        completeTask: @escaping (PlannerTask) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tasks = tasks
        self.sections = sections
        self.controls = controls
        self.projects = projects
        self._searchText = searchText
        self.createTask = createTask
        self.deleteTask = deleteTask
        self.completeTask = completeTask
    }

    init(
        title: String,
        systemImage: String,
        sections: [UpcomingSection],
        controls: AnyView? = nil,
        projects: [Project],
        searchText: Binding<String>,
        createTask: @escaping (String) -> Void,
        completeTask: @escaping (PlannerTask) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tasks = []
        self.sections = sections
        self.controls = controls
        self.projects = projects
        self._searchText = searchText
        self.createTask = createTask
        self.deleteTask = nil
        self.completeTask = completeTask
    }

    var body: some View {
        List {
            if let controls {
                Section {
                    controls
                }
                .listRowBackground(PlannerTheme.rowBackground)
            }

            quickAddSection

            if shouldShowTaskSection {
                Section(title) {
                    ForEach(tasks) { task in
                        IOSTaskRow(
                            task: task,
                            openTask: { selectedTask = task },
                            completeTask: completeTask
                        )
                    }
                    .onDelete { offsets in
                        guard let deleteTask else {
                            return
                        }

                        offsets.map { tasks[$0] }.forEach(deleteTask)
                    }
                }
            }

            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.tasks) { task in
                        IOSTaskRow(
                            task: task,
                            openTask: { selectedTask = task },
                            completeTask: completeTask
                        )
                    }
                }
            }
        }
        .navigationTitle(title)
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .searchable(text: $searchText, prompt: "Поиск")
        .overlay {
            if isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: systemImage,
                    description: Text(emptyDescription)
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

    private var quickAddSection: some View {
        Section {
            HStack {
                TextField("Новая задача", text: $newTaskTitle)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit(addTask)

                Button(action: addTask) {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(PlannerTheme.accent)
                }
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var isEmpty: Bool {
        tasks.isEmpty && sections.allSatisfy(\.tasks.isEmpty)
    }

    private var shouldShowTaskSection: Bool {
        !tasks.isEmpty || sections.isEmpty
    }

    private var emptyTitle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Нет задач" : "Ничего не найдено"
    }

    private var emptyDescription: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Используйте быстрое добавление, чтобы создать задачу."
            : "Попробуйте изменить запрос."
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }

        createTask(title)
        newTaskTitle = ""
    }
}

private struct IOSTaskRow: View {
    let task: PlannerTask
    let openTask: () -> Void
    let completeTask: (PlannerTask) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                completeTask(task)
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? PlannerTheme.success : PlannerTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(task.status == .done)

            Button(action: openTask) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text(task.status.displayName)
                            Text(task.priority.displayName)

                            if let scheduled = task.scheduled {
                                Text(scheduled.formatted(date: .abbreviated, time: .shortened))
                            }

                            if let projectTitle = task.project?.title {
                                Text(projectTitle)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                        .lineLimit(1)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(PlannerTheme.rowBackground)
    }
}
#endif
