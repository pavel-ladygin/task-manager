import SwiftUI

#if os(iOS)
struct IOSProjectsView: View {
    let projects: [Project]
    let tasks: [PlannerTask]
    @Binding var searchText: String
    let createProject: (String) -> Void
    let deleteProject: (Project) -> Void
    let openTask: (PlannerTask) -> Void
    let completeTask: (PlannerTask) -> Void

    @State private var newProjectTitle = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Новый проект", text: $newProjectTitle)
                        .submitLabel(.done)
                        .onSubmit(addProject)

                    Button(action: addProject) {
                        Image(systemName: "folder.badge.plus")
                    }
                    .disabled(newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Активные проекты") {
                ForEach(projects) { project in
                    NavigationLink {
                        IOSProjectPageView(
                            project: project,
                            tasks: TaskListService.tasks(
                                for: project,
                                tasks: tasks,
                                searchText: searchText
                            ),
                            progress: TaskListService.progress(for: project, tasks: tasks),
                            openTask: openTask,
                            completeTask: completeTask
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(PlannerTheme.projectGradient(project.colorPreset, opacity: 0.9))
                                    .frame(width: 22, height: 14)

                                Text(project.title)
                                    .lineLimit(1)
                            }

                            Text(project.status.displayName)
                                .font(.caption)
                                .foregroundStyle(PlannerTheme.secondaryText)
                        }
                        .listRowBackground(PlannerTheme.rowBackground)
                    }
                }
                .onDelete { offsets in
                    offsets.map { projects[$0] }.forEach(deleteProject)
                }
            }
        }
        .navigationTitle("Проекты")
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .searchable(text: $searchText, prompt: "Поиск")
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView(
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Нет проектов" : "Ничего не найдено",
                    systemImage: "folder",
                    description: Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Создайте проект, чтобы группировать задачи." : "Попробуйте изменить запрос.")
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func addProject() {
        let title = newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }

        createProject(title)
        newProjectTitle = ""
    }
}

private struct IOSProjectPageView: View {
    let project: Project
    let tasks: [PlannerTask]
    let progress: ProjectProgress
    let openTask: (PlannerTask) -> Void
    let completeTask: (PlannerTask) -> Void

    @State private var isProjectEditorPresented = false

    private var activeTasks: [PlannerTask] {
        tasks.filter(TaskListService.isActive)
    }

    private var closedTasks: [PlannerTask] {
        tasks.filter { !TaskListService.isActive($0) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Статус", value: project.status.displayName)
                    LabeledContent("Цвет", value: project.colorPreset.displayName)
                    LabeledContent(
                        "Срок",
                        value: project.deadline?.formatted(date: .abbreviated, time: .omitted) ?? "Не задан"
                    )

                    Text(project.notes.isEmpty ? "Нет заметок" : project.notes)
                        .foregroundStyle(PlannerTheme.secondaryText)
                        .lineLimit(4)

                    ProgressView(value: progress.fraction) {
                        Text("Закрыто: \(progress.closedTasks)/\(progress.totalTasks)")
                    }
                    .tint(PlannerTheme.accent)
                }
            }

            Section("Активные") {
                if activeTasks.isEmpty {
                    Text("Нет активных задач")
                        .foregroundStyle(PlannerTheme.secondaryText)
                } else {
                    ForEach(activeTasks) { task in
                        IOSProjectTaskRow(
                            task: task,
                            openTask: { openTask(task) },
                            completeTask: completeTask
                        )
                    }
                }
            }

            Section("Завершенные") {
                if closedTasks.isEmpty {
                    Text("Нет завершенных задач")
                        .foregroundStyle(PlannerTheme.secondaryText)
                } else {
                    ForEach(closedTasks) { task in
                        IOSProjectTaskRow(
                            task: task,
                            openTask: { openTask(task) },
                            completeTask: completeTask
                        )
                    }
                }
            }
        }
        .navigationTitle(project.title)
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isProjectEditorPresented = true } label: {
                    Label("Редактировать", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $isProjectEditorPresented) {
            NavigationStack {
                IOSProjectEditorView(project: project)
            }
        }
    }
}

private struct IOSProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let project: Project
    @State private var draft: ProjectDraft
    @State private var errorMessage: String?
    @State private var confirmCancel = false

    init(project: Project) {
        self.project = project
        _draft = State(initialValue: ProjectDraft(project: project))
    }

    private var isDirty: Bool { draft != ProjectDraft(project: project) }

    var body: some View {
        Form {
            Section("Проект") {
                TextField("Название", text: $draft.title)
                Picker("Статус", selection: $draft.status) {
                    ForEach(ProjectStatus.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Цвет", selection: $draft.color) {
                    ForEach(ProjectColorPreset.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("Срок") {
                Toggle("Есть срок", isOn: deadlineEnabled)
                if draft.deadline != nil {
                    DatePicker("Срок", selection: deadline, displayedComponents: .date)
                }
            }
            Section("Заметки") { TextEditor(text: $draft.notes).frame(minHeight: 140) }
        }
        .navigationTitle("Редактировать проект")
        .interactiveDismissDisabled(isDirty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { isDirty ? (confirmCancel = true) : dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить", action: save).disabled(!isDirty)
            }
        }
        .confirmationDialog("Отбросить изменения?", isPresented: $confirmCancel) {
            Button("Сохранить", action: save)
            Button("Отбросить", role: .destructive) { dismiss() }
            Button("Остаться", role: .cancel) {}
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var deadlineEnabled: Binding<Bool> {
        Binding(get: { draft.deadline != nil }, set: { draft.deadline = $0 ? (draft.deadline ?? .now) : nil })
    }
    private var deadline: Binding<Date> {
        Binding(get: { draft.deadline ?? .now }, set: { draft.deadline = $0 })
    }
    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
    private func save() {
        Task { @MainActor in
            do {
                try PlannerDataService.saveProject(project, draft: draft, context: modelContext)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct IOSProjectTaskRow: View {
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
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text(task.status.displayName)
                            Text(task.priority.displayName)
                        }
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .listRowBackground(PlannerTheme.rowBackground)
    }

    private var rowBackground: AnyShapeStyle {
        if let preset = task.project?.colorPreset {
            return AnyShapeStyle(PlannerTheme.projectGradient(preset, opacity: 0.18))
        }

        return AnyShapeStyle(Color.clear)
    }
}
#endif
