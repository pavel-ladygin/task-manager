import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

#if os(macOS)
enum MacSidebarSection: String, CaseIterable, Hashable, Identifiable {
    case inbox
    case today
    case upcoming
    case kanban
    case calendar
    case projects
    case completed
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox:
            "Входящие"
        case .today:
            "Сегодня"
        case .upcoming:
            "Предстоящие"
        case .kanban:
            "Канбан"
        case .calendar:
            "Календарь"
        case .projects:
            "Проекты"
        case .completed:
            "Завершенные"
        case .settings:
            "Настройки"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox:
            "tray"
        case .today:
            "sun.max"
        case .upcoming:
            "calendar.badge.clock"
        case .kanban:
            "rectangle.3.group"
        case .calendar:
            "calendar"
        case .projects:
            "folder"
        case .completed:
            "checkmark.circle"
        case .settings:
            "gearshape"
        }
    }
}

private enum MacFocusedField: Hashable {
    case quickAdd
    case search
}

struct PlannerCommandActions {
    let focusQuickAdd: () -> Void
    let focusSearch: () -> Void
    let toggleInspector: () -> Void
    let markSelectedTaskDone: () -> Void
    let canMarkSelectedTaskDone: Bool
}

private struct PlannerCommandActionsKey: FocusedValueKey {
    typealias Value = PlannerCommandActions
}

extension FocusedValues {
    var plannerCommandActions: PlannerCommandActions? {
        get { self[PlannerCommandActionsKey.self] }
        set { self[PlannerCommandActionsKey.self] = newValue }
    }
}

private extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct MacMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \PlannerTask.createdAt, order: .forward) private var tasks: [PlannerTask]
    @Query(sort: \Project.createdAt, order: .forward) private var projects: [Project]
    @Query(sort: \AppSettings.createdAt, order: .forward) private var appSettings: [AppSettings]
    @FocusState private var focusedField: MacFocusedField?

    @State private var selectedSection: MacSidebarSection = .inbox
    @State private var selectedTaskID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var searchText = ""
    @State private var newTaskTitle = ""
    @State private var newProjectTitle = ""
    @State private var selectedCalendarDate = Date.now
    @State private var isInspectorVisible = true
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var notificationStatus = "Неизвестно"
    @State private var syncToken = ""
    @State private var syncStatus = "Не синхронизировано"
    @State private var autoSyncTask: Swift.Task<Void, Never>?
    @State private var isAutoSyncing = false

    private var selectedTask: PlannerTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        rootLayout
            .frame(minWidth: 1060, minHeight: 680)
            .background(PlannerTheme.windowBackground)
            .tint(PlannerTheme.accent)
            .preferredColorScheme(currentSettings?.appTheme.colorScheme)
            .focusedSceneValue(\.plannerCommandActions, commandActions)
            .alert("Ошибка планировщика", isPresented: errorBinding) {
                Button("ОК", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Планировщик", isPresented: statusBinding) {
                Button("ОК", role: .cancel) {
                    statusMessage = nil
                }
            } message: {
                Text(statusMessage ?? "")
            }
            .onChange(of: selectedSection) { _, newSection in
                if newSection != .projects {
                    selectedProjectID = nil
                }

                switch newSection {
                case .kanban, .settings:
                    ensureAppSettings()
                default:
                    break
                }
            }
            .onChange(of: selectedProjectID) { _, newProjectID in
                if activeSection == .projects, newProjectID != nil {
                    selectedTaskID = nil
                }
            }
            .onAppear {
                ensureAppSettings()
                refreshNotificationStatus()
                syncToken = KeychainService.loadSyncToken()
                triggerAutoSyncNow(reason: "Запуск")
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    triggerAutoSyncNow(reason: "Вход")
                case .inactive, .background:
                    triggerAutoSyncNow(reason: "Выход")
                @unknown default:
                    break
                }
            }
            .onChange(of: taskSyncSignature) { _, _ in
                scheduleAutoSync(reason: "Изменения задач")
            }
            .onChange(of: projectSyncSignature) { _, _ in
                scheduleAutoSync(reason: "Изменения проектов")
            }
    }

    @ViewBuilder
    private var rootLayout: some View {
        if isInspectorVisible {
            NavigationSplitView {
                MacSidebar(selectedSection: $selectedSection)
            } content: {
                contentPanel
            } detail: {
                inspectorPanel
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
            }
        } else {
            NavigationSplitView {
                MacSidebar(selectedSection: $selectedSection)
            } detail: {
                contentPanel
            }
        }
    }

    private var contentPanel: some View {
        MacContentView(
            section: activeSection,
            tasks: tasksForSelectedSection,
            upcomingSections: upcomingSections,
            searchText: searchText,
            allTasks: searchFilteredTasks,
            kanbanColumns: kanbanColumns,
            calendarWeek: calendarWeek,
            calendarPlacements: calendarPlacements,
            isCurrentCalendarWeek: isCurrentCalendarWeek,
            projects: activeProjects,
            allProjectTasks: selectedProjectTasks,
            selectedProject: selectedProject,
            selectedProjectProgress: selectedProjectProgress,
            settings: currentSettings,
            selectedTaskID: $selectedTaskID,
            selectedProjectID: $selectedProjectID,
            newProjectTitle: $newProjectTitle,
            createProject: createProject,
            deleteTask: deleteTask,
            deleteProject: deleteProject,
            completeTask: completeTask,
            moveTask: moveTask,
            rescheduleTask: rescheduleTask,
            setTaskDue: setTaskDue,
            openTaskInspector: openTaskInspector,
            goToPreviousCalendarWeek: { moveSelectedCalendarWeek(by: -1) },
            goToNextCalendarWeek: { moveSelectedCalendarWeek(by: 1) },
            goToCurrentCalendarWeek: goToCurrentCalendarWeek,
            setHideEmptyKanbanColumns: setHideEmptyKanbanColumns,
            setTheme: setTheme,
            setDefaultReminderLeadMinutes: setDefaultReminderLeadMinutes,
            requestNotificationAuthorization: requestNotificationAuthorization,
            notificationStatus: notificationStatus,
            syncToken: $syncToken,
            syncStatus: syncStatus,
            setSyncEnabled: setSyncEnabled,
            setSyncServerURL: setSyncServerURL,
            setSyncCertificateFingerprint: setSyncCertificateFingerprint,
            setSyncToken: setSyncToken,
            testSyncConnection: testSyncConnection,
            bootstrapSync: bootstrapSync,
            syncNow: syncNow,
            completedTaskCount: completedTaskCount,
            clearCompletedTasks: clearCompletedTasks,
            exportBackup: exportBackup,
            importBackup: importBackup
        )
        .toolbar {
            MacToolbar(
                searchText: $searchText,
                newTaskTitle: $newTaskTitle,
                isInspectorVisible: $isInspectorVisible,
                focusedField: $focusedField,
                createTask: createTask
            )
        }
        .background(PlannerTheme.windowBackground)
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if let selectedTask {
            TaskDetailView(task: selectedTask, projects: projects, deleteTask: deleteTask)
        } else if activeSection == .projects, let selectedProject {
            ProjectDetailView(project: selectedProject)
        } else {
            ContentUnavailableView(
                "Ничего не выбрано",
                systemImage: "sidebar.right",
                description: Text("Выберите задачу или проект, чтобы открыть параметры.")
            )
        }
    }

    private var tasksForSelectedSection: [PlannerTask] {
        switch activeSection {
        case .inbox:
            TaskListService.inboxTasks(from: tasks, searchText: searchText)
        case .today:
            TaskListService.todayTasks(from: tasks, searchText: searchText)
        case .upcoming:
            upcomingSections.flatMap(\.tasks)
        case .completed:
            TaskListService.completedTasks(from: tasks, searchText: searchText)
        case .kanban, .calendar, .projects, .settings:
            searchFilteredTasks
        }
    }

    private var activeSection: MacSidebarSection {
        selectedSection
    }

    private var upcomingSections: [UpcomingSection] {
        TaskListService.upcomingSections(from: tasks, searchText: searchText)
    }

    private var searchFilteredTasks: [PlannerTask] {
        tasks.filter { TaskListService.matchesSearch($0, searchText: searchText) }
    }

    private var kanbanColumns: [KanbanColumn] {
        KanbanService.columns(
            from: tasks,
            searchText: searchText,
            hideEmptyColumns: currentSettings?.hideEmptyKanbanColumns ?? false
        )
    }

    private var calendarWeek: CalendarWeek {
        CalendarService.week(containing: selectedCalendarDate)
    }

    private var calendarPlacements: [CalendarTaskPlacement] {
        CalendarService.placements(
            from: tasks,
            searchText: searchText,
            week: calendarWeek
        )
    }

    private var isCurrentCalendarWeek: Bool {
        Calendar.current.isDate(
            calendarWeek.startOfWeek,
            inSameDayAs: CalendarService.currentWeek().startOfWeek
        )
    }

    private var currentSettings: AppSettings? {
        appSettings.first
    }

    private var activeProjects: [Project] {
        TaskListService.activeProjects(from: projects, searchText: searchText)
    }

    private var selectedProjectTasks: [PlannerTask] {
        guard let selectedProject else {
            return []
        }

        return TaskListService.tasks(for: selectedProject, tasks: tasks, searchText: searchText)
    }

    private var selectedProjectProgress: ProjectProgress {
        guard let selectedProject else {
            return ProjectProgress(totalTasks: 0, closedTasks: 0)
        }

        return TaskListService.progress(for: selectedProject, tasks: tasks)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var statusBinding: Binding<Bool> {
        Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )
    }

    private var completedTaskCount: Int {
        tasks.filter { $0.status == .done }.count
    }

    private var commandActions: PlannerCommandActions {
        PlannerCommandActions(
            focusQuickAdd: focusQuickAdd,
            focusSearch: focusSearch,
            toggleInspector: toggleInspector,
            markSelectedTaskDone: markSelectedTaskDone,
            canMarkSelectedTaskDone: selectedTask.map { $0.status != .done } ?? false
        )
    }

    private var taskSyncSignature: String {
        tasks
            .map { task in
                [
                    task.id.uuidString,
                    String(task.updatedAt.timeIntervalSinceReferenceDate),
                    task.project?.id.uuidString ?? "none",
                    String(task.checklistItems.count)
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    private var projectSyncSignature: String {
        projects
            .map { project in
                [
                    project.id.uuidString,
                    String(project.updatedAt.timeIntervalSinceReferenceDate),
                    project.status.rawValue
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    private func createTask() {
        do {
            let task = try PlannerDataService.createTask(
                title: newTaskTitle,
                context: modelContext,
                status: .inbox
            )
            newTaskTitle = ""
            selectedTaskID = task.id
            selectedSection = .inbox
            isInspectorVisible = true
            scheduleAutoSync(reason: "Создана задача")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProject() {
        do {
            let project = try PlannerDataService.createProject(
                title: newProjectTitle,
                context: modelContext
            )
            newProjectTitle = ""
            selectedProjectID = project.id
            selectedTaskID = nil
            isInspectorVisible = true
            scheduleAutoSync(reason: "Создан проект")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTask(_ task: PlannerTask) {
        do {
            try PlannerDataService.deleteTask(task, context: modelContext)
            if selectedTaskID == task.id {
                selectedTaskID = nil
            }
            scheduleAutoSync(reason: "Удалена задача")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCompletedTasks() {
        do {
            let shouldClearSelectedTask = selectedTask?.status == .done
            let deletedCount = try PlannerDataService.deleteCompletedTasks(from: tasks, context: modelContext)

            if shouldClearSelectedTask {
                selectedTaskID = nil
            }

            statusMessage = deletedCount == 0
                ? "Выполненных задач для очистки нет."
                : "Удалено выполненных задач: \(deletedCount)."

            if deletedCount > 0 {
                scheduleAutoSync(reason: "Очищены выполненные задачи")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: Project) {
        do {
            try PlannerDataService.deleteProject(project, context: modelContext)
            if selectedProjectID == project.id {
                selectedProjectID = nil
            }
            scheduleAutoSync(reason: "Удален проект")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openTaskInspector(_ taskID: UUID) {
        selectedTaskID = taskID
        isInspectorVisible = true
    }

    private func completeTask(_ task: PlannerTask) {
        guard task.status != .done else {
            return
        }

        do {
            try PlannerDataService.setTaskStatus(
                task,
                status: .done,
                context: modelContext
            )
            selectedTaskID = task.id
            scheduleAutoSync(reason: "Задача выполнена")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveTask(
        _ task: PlannerTask,
        to status: TaskStatus,
        after previousTask: PlannerTask?,
        before nextTask: PlannerTask?
    ) {
        do {
            try PlannerDataService.moveTask(
                task,
                to: status,
                after: previousTask,
                before: nextTask,
                context: modelContext
            )
            selectedTaskID = task.id
            isInspectorVisible = true
            scheduleAutoSync(reason: "Задача перемещена")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rescheduleTask(_ task: PlannerTask, to scheduled: Date) {
        do {
            try PlannerDataService.rescheduleTask(
                task,
                to: scheduled,
                context: modelContext
            )
            selectedTaskID = task.id
            isInspectorVisible = true
            scheduleAutoSync(reason: "Задача перенесена")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setTaskDue(_ task: PlannerTask, to due: Date) {
        do {
            try PlannerDataService.setTaskDue(
                task,
                to: due,
                context: modelContext
            )
            selectedTaskID = task.id
            isInspectorVisible = true
            scheduleAutoSync(reason: "Изменен срок")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveSelectedCalendarWeek(by value: Int) {
        selectedCalendarDate = Calendar.current.date(
            byAdding: .day,
            value: value * 7,
            to: selectedCalendarDate
        ) ?? selectedCalendarDate
    }

    private func goToCurrentCalendarWeek() {
        selectedCalendarDate = .now
    }

    private func setHideEmptyKanbanColumns(_ isHidden: Bool, settings: AppSettings) {
        do {
            try PlannerDataService.setHideEmptyKanbanColumns(
                isHidden,
                settings: settings,
                context: modelContext
            )
            scheduleAutoSync(reason: "Изменены настройки")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setTheme(_ theme: AppTheme, settings: AppSettings) {
        do {
            try PlannerDataService.setTheme(
                theme,
                settings: settings,
                context: modelContext
            )
            scheduleAutoSync(reason: "Изменена тема")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setDefaultReminderLeadMinutes(_ minutes: Int, settings: AppSettings) {
        do {
            try PlannerDataService.setDefaultReminderLeadMinutes(
                minutes,
                settings: settings,
                context: modelContext
            )
            scheduleAutoSync(reason: "Изменены уведомления")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncEnabled(_ isEnabled: Bool, settings: AppSettings) {
        do {
            try PlannerDataService.setSyncEnabled(isEnabled, settings: settings, context: modelContext)
            if isEnabled {
                triggerAutoSyncNow(reason: "Синхронизация включена")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncServerURL(_ serverURL: String, settings: AppSettings) {
        do {
            try PlannerDataService.setSyncServerURL(serverURL, settings: settings, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncCertificateFingerprint(_ fingerprint: String, settings: AppSettings) {
        do {
            try PlannerDataService.setSyncCertificateFingerprint(fingerprint, settings: settings, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncToken(_ token: String) {
        syncToken = token
        do {
            try KeychainService.saveSyncToken(token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testSyncConnection(_ settings: AppSettings) {
        Swift.Task {
            do {
                let response = try await SyncService.testConnection(settings: settings, token: syncToken)
                syncStatus = "Подключение OK, cursor \(response.serverCursor)"
                statusMessage = syncStatus
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bootstrapSync(_ settings: AppSettings) {
        Swift.Task {
            do {
                let result = try await SyncService.bootstrap(context: modelContext, settings: settings, token: syncToken)
                syncStatus = "Bootstrap OK: отправлено \(result.pushed), cursor \(result.cursor)"
                statusMessage = syncStatus
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncNow(_ settings: AppSettings) {
        Swift.Task {
            do {
                let result = try await SyncService.syncNow(context: modelContext, settings: settings, token: syncToken)
                syncStatus = "Sync OK: отправлено \(result.pushed), получено \(result.pulled), cursor \(result.cursor)"
                statusMessage = syncStatus
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "planner-backup.json"
        panel.title = "Экспорт резервной копии"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try BackupService.exportData(context: modelContext)
            try data.write(to: url, options: .atomic)
            statusMessage = "JSON-резервная копия экспортирована в \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Импорт резервной копии"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            try BackupService.importData(data, context: modelContext)
            selectedTaskID = nil
            selectedProjectID = nil
            statusMessage = "JSON-резервная копия импортирована из \(url.lastPathComponent)."
            scheduleAutoSync(reason: "Импортирована резервная копия")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func focusQuickAdd() {
        selectedSection = .inbox
        isInspectorVisible = true
        focusedField = .quickAdd

        DispatchQueue.main.async {
            focusedField = .quickAdd
        }
    }

    private func focusSearch() {
        focusedField = .search

        DispatchQueue.main.async {
            focusedField = .search
        }
    }

    private func toggleInspector() {
        isInspectorVisible.toggle()
    }

    private func markSelectedTaskDone() {
        guard let selectedTask, selectedTask.status != .done else {
            return
        }

        do {
            try PlannerDataService.setTaskStatus(
                selectedTask,
                status: .done,
                context: modelContext
            )
            scheduleAutoSync(reason: "Задача выполнена")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestNotificationAuthorization() {
        Swift.Task {
            do {
                let isGranted = try await NotificationService.requestAuthorization()
                notificationStatus = isGranted
                    ? await NotificationService.authorizationStatusDescription()
                    : "Запрещены"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshNotificationStatus() {
        Swift.Task {
            notificationStatus = await NotificationService.authorizationStatusDescription()
        }
    }

    private func ensureAppSettings() {
        do {
            try PlannerDataService.ensureAppSettings(context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleAutoSync(reason: String) {
        guard AutoSyncService.canSync(settings: currentSettings, token: syncToken) else {
            return
        }

        autoSyncTask?.cancel()
        autoSyncTask = Swift.Task {
            do {
                try await Swift.Task.sleep(nanoseconds: AutoSyncService.debounceDelayNanoseconds)
            } catch {
                return
            }

            guard !Swift.Task.isCancelled else {
                return
            }

            await performAutoSync(reason: reason, showErrors: false)
        }
    }

    private func triggerAutoSyncNow(reason: String) {
        guard AutoSyncService.canSync(settings: currentSettings, token: syncToken) else {
            return
        }

        autoSyncTask?.cancel()
        autoSyncTask = nil
        Swift.Task {
            await performAutoSync(reason: reason, showErrors: false)
        }
    }

    private func performAutoSync(reason: String, showErrors: Bool) async {
        guard
            let settings = currentSettings,
            AutoSyncService.canSync(settings: settings, token: syncToken)
        else {
            return
        }

        guard !isAutoSyncing else {
            scheduleAutoSync(reason: reason)
            return
        }

        isAutoSyncing = true
        defer { isAutoSyncing = false }

        do {
            let result = try await AutoSyncService.syncNow(
                context: modelContext,
                settings: settings,
                token: syncToken
            )
            syncStatus = "Автосинк OK: отправлено \(result.pushed), получено \(result.pulled), cursor \(result.cursor)"
        } catch {
            syncStatus = "Автосинк ошибка: \(error.localizedDescription)"
            if showErrors {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MacSidebar: View {
    @Binding var selectedSection: MacSidebarSection

    var body: some View {
        List(selection: $selectedSection) {
            Section("План") {
                sidebarRow(.inbox)
                sidebarRow(.today)
                sidebarRow(.upcoming)
            }

            Section("Виды") {
                sidebarRow(.kanban)
                sidebarRow(.calendar)
                sidebarRow(.projects)
                sidebarRow(.completed)
            }

            Section("Приложение") {
                sidebarRow(.settings)
            }
        }
        .navigationTitle("Планировщик")
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.sidebarBackground)
        .tint(PlannerTheme.accent)
    }

    private func sidebarRow(_ section: MacSidebarSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }
}

private struct MacToolbar: ToolbarContent {
    @Binding var searchText: String
    @Binding var newTaskTitle: String
    @Binding var isInspectorVisible: Bool
    var focusedField: FocusState<MacFocusedField?>.Binding
    let createTask: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PlannerTheme.secondaryText)

                TextField("Поиск", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 220)
                    .focused(focusedField, equals: .search)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PlannerTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
            )
        }

        ToolbarItemGroup(placement: .primaryAction) {
            TextField("Быстро добавить", text: $newTaskTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused(focusedField, equals: .quickAdd)
                .onSubmit(createTask)

            Button(action: createTask) {
                Label("Добавить задачу", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                isInspectorVisible.toggle()
            } label: {
                Label("Показать/скрыть инспектор", systemImage: "sidebar.right")
            }
        }
    }
}

private struct MacContentView: View {
    let section: MacSidebarSection
    let tasks: [PlannerTask]
    let upcomingSections: [UpcomingSection]
    let searchText: String
    let allTasks: [PlannerTask]
    let kanbanColumns: [KanbanColumn]
    let calendarWeek: CalendarWeek
    let calendarPlacements: [CalendarTaskPlacement]
    let isCurrentCalendarWeek: Bool
    let projects: [Project]
    let allProjectTasks: [PlannerTask]
    let selectedProject: Project?
    let selectedProjectProgress: ProjectProgress
    let settings: AppSettings?
    @Binding var selectedTaskID: UUID?
    @Binding var selectedProjectID: UUID?
    @Binding var newProjectTitle: String
    let createProject: () -> Void
    let deleteTask: (PlannerTask) -> Void
    let deleteProject: (Project) -> Void
    let completeTask: (PlannerTask) -> Void
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void
    let setTaskDue: (PlannerTask, Date) -> Void
    let openTaskInspector: (UUID) -> Void
    let goToPreviousCalendarWeek: () -> Void
    let goToNextCalendarWeek: () -> Void
    let goToCurrentCalendarWeek: () -> Void
    let setHideEmptyKanbanColumns: (Bool, AppSettings) -> Void
    let setTheme: (AppTheme, AppSettings) -> Void
    let setDefaultReminderLeadMinutes: (Int, AppSettings) -> Void
    let requestNotificationAuthorization: () -> Void
    let notificationStatus: String
    @Binding var syncToken: String
    let syncStatus: String
    let setSyncEnabled: (Bool, AppSettings) -> Void
    let setSyncServerURL: (String, AppSettings) -> Void
    let setSyncCertificateFingerprint: (String, AppSettings) -> Void
    let setSyncToken: (String) -> Void
    let testSyncConnection: (AppSettings) -> Void
    let bootstrapSync: (AppSettings) -> Void
    let syncNow: (AppSettings) -> Void
    let completedTaskCount: Int
    let clearCompletedTasks: () -> Void
    let exportBackup: () -> Void
    let importBackup: () -> Void

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            switch section {
            case .inbox, .today, .completed:
                taskList(tasks: tasks)
            case .upcoming:
                upcomingList
            case .kanban:
                KanbanBoardView(
                    columns: kanbanColumns,
                    searchText: searchText,
                    selectedTaskID: $selectedTaskID,
                    moveTask: moveTask
                )
            case .calendar:
                CalendarWeekView(
                    week: calendarWeek,
                    placements: calendarPlacements,
                    searchText: searchText,
                    isCurrentWeek: isCurrentCalendarWeek,
                    selectedTaskID: $selectedTaskID,
                    openTaskInspector: openTaskInspector,
                    goToPreviousWeek: goToPreviousCalendarWeek,
                    goToNextWeek: goToNextCalendarWeek,
                    goToCurrentWeek: goToCurrentCalendarWeek,
                    rescheduleTask: rescheduleTask,
                    setTaskDue: setTaskDue
                )
            case .projects:
                projectsView
            case .settings:
                SettingsPlaceholderView(
                    settings: settings,
                    setHideEmptyKanbanColumns: setHideEmptyKanbanColumns,
                    setTheme: setTheme,
                    setDefaultReminderLeadMinutes: setDefaultReminderLeadMinutes,
                    requestNotificationAuthorization: requestNotificationAuthorization,
                    notificationStatus: notificationStatus,
                    syncToken: $syncToken,
                    syncStatus: syncStatus,
                    setSyncEnabled: setSyncEnabled,
                    setSyncServerURL: setSyncServerURL,
                    setSyncCertificateFingerprint: setSyncCertificateFingerprint,
                    setSyncToken: setSyncToken,
                    testSyncConnection: testSyncConnection,
                    bootstrapSync: bootstrapSync,
                    syncNow: syncNow,
                    completedTaskCount: completedTaskCount,
                    clearCompletedTasks: clearCompletedTasks,
                    exportBackup: exportBackup,
                    importBackup: importBackup
                )
            }
        }
        .navigationTitle(section.title)
    }

    private func taskList(tasks: [PlannerTask]) -> some View {
        List(selection: $selectedTaskID) {
            ForEach(tasks) { task in
                TaskListRow(
                    task: task,
                    isSelected: selectedTaskID == task.id,
                    completeTask: completeTask
                )
                    .tag(task.id)
            }
            .onDelete { offsets in
                for offset in offsets {
                    deleteTask(tasks[offset])
                }
            }
        }
        .overlay {
            if tasks.isEmpty {
                emptyState(for: section)
                    .allowsHitTesting(false)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
    }

    private var upcomingList: some View {
        List(selection: $selectedTaskID) {
            ForEach(upcomingSections) { section in
                Section(section.title) {
                    ForEach(section.tasks) { task in
                        TaskListRow(
                            task: task,
                            isSelected: selectedTaskID == task.id,
                            completeTask: completeTask
                        )
                            .tag(task.id)
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            deleteTask(section.tasks[offset])
                        }
                    }
                }
            }
        }
        .overlay {
            if upcomingSections.isEmpty {
                emptyState(for: .upcoming)
                    .allowsHitTesting(false)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
    }

    private var projectsView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Новый проект", text: $newProjectTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createProject)

                Button(action: createProject) {
                    Label("Добавить проект", systemImage: "folder.badge.plus")
                }
                .disabled(newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(PlannerTheme.panelBackground)

            Divider()

            HStack(spacing: 0) {
                projectListPane
                    .frame(width: 280)

                Divider()

                projectDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PlannerTheme.windowBackground)
    }

    @ViewBuilder
    private var projectListPane: some View {
        if projects.isEmpty {
            TopAlignedPlaceholderView(
                title: isSearching ? "Ничего не найдено" : "Нет проектов",
                systemImage: "folder",
                description: isSearching ? "Попробуйте изменить запрос." : "Создайте проект, чтобы группировать задачи."
            )
        } else {
            List(selection: $selectedProjectID) {
                Section("Активные проекты") {
                    ForEach(projects) { project in
                        ProjectListRow(project: project)
                            .tag(project.id)
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            deleteProject(projects[offset])
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PlannerTheme.windowBackground)
        }
    }

    @ViewBuilder
    private var projectDetailPane: some View {
        if let selectedProject {
            ProjectPageView(
                project: selectedProject,
                tasks: allProjectTasks,
                progress: selectedProjectProgress,
                selectedTaskID: $selectedTaskID,
                deleteTask: deleteTask,
                completeTask: completeTask
            )
        } else {
            TopAlignedPlaceholderView(
                title: projects.isEmpty ? "Проект не выбран" : "Выберите проект",
                systemImage: "folder",
                description: projects.isEmpty ? "Создайте проект, чтобы видеть здесь задачи и прогресс." : "Выберите активный проект, чтобы открыть задачи и прогресс."
            )
        }
    }

    @ViewBuilder
    private func emptyState(for section: MacSidebarSection) -> some View {
        if isSearching {
            ContentUnavailableView(
                "Ничего не найдено",
                systemImage: "magnifyingglass",
                description: Text("Попробуйте изменить запрос.")
            )
        } else {
            switch section {
            case .inbox:
                ContentUnavailableView(
                    "Входящие пусты",
                    systemImage: section.systemImage,
                    description: Text("Используйте быстрое добавление, чтобы создать задачу.")
                )
            case .today:
                ContentUnavailableView(
                    "На сегодня ничего нет",
                    systemImage: section.systemImage,
                    description: Text("Здесь появятся задачи, запланированные на сегодня или просроченные.")
                )
            case .upcoming:
                ContentUnavailableView(
                    "Нет предстоящих задач",
                    systemImage: section.systemImage,
                    description: Text("Здесь появятся задачи на ближайшие 7 дней и задачи без даты.")
                )
            case .completed:
                ContentUnavailableView(
                    "Нет завершенных задач",
                    systemImage: section.systemImage,
                    description: Text("Здесь появятся выполненные и отмененные задачи.")
                )
            case .projects:
                ContentUnavailableView(
                    "Нет проектов",
                    systemImage: section.systemImage,
                    description: Text("Создайте проект, чтобы группировать задачи.")
                )
            case .kanban, .calendar, .settings:
                ContentUnavailableView(
                    section.title,
                    systemImage: section.systemImage,
                    description: Text("Нет подходящих элементов.")
                )
            }
        }
    }
}

private struct ProjectListRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(PlannerTheme.projectGradient(project.colorPreset, opacity: 0.9))
                    .frame(width: 22, height: 14)

                Text(project.title)
                    .font(.body)
            }

            Text(project.status.displayName)
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
        }
        .padding(.vertical, 4)
        .listRowBackground(PlannerTheme.rowBackground)
    }
}

private struct TopAlignedPlaceholderView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(PlannerTheme.accent)

            Text(title)
                .font(.headline)

            Text(description)
                .font(.callout)
                .foregroundStyle(PlannerTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(.horizontal, 24)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ProjectPageView: View {
    let project: Project
    let tasks: [PlannerTask]
    let progress: ProjectProgress
    @Binding var selectedTaskID: UUID?
    let deleteTask: (PlannerTask) -> Void
    let completeTask: (PlannerTask) -> Void

    private var activeTasks: [PlannerTask] {
        tasks.filter(TaskListService.isActive)
    }

    private var closedTasks: [PlannerTask] {
        tasks.filter { !TaskListService.isActive($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(PlannerTheme.projectGradient(project.colorPreset, opacity: 0.9))
                                .frame(width: 28, height: 18)

                            Text(project.title)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                        }

                        Text(project.notes.isEmpty ? "Нет заметок" : project.notes)
                            .foregroundStyle(PlannerTheme.secondaryText)
                            .lineLimit(3)
                    }

                    Spacer()

                    Text("\(progress.closedTasks)/\(progress.totalTasks)")
                        .font(.headline)
                        .foregroundStyle(PlannerTheme.secondaryText)
                }

                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(PlannerTheme.accent)
            }
            .padding()
            .background(PlannerTheme.projectGradient(project.colorPreset, opacity: 0.16))

            Divider()

            List(selection: $selectedTaskID) {
                Section("Активные") {
                    if activeTasks.isEmpty {
                        Text("Нет активных задач")
                            .foregroundStyle(PlannerTheme.secondaryText)
                    } else {
                        ForEach(activeTasks) { task in
                            TaskListRow(
                                task: task,
                                isSelected: selectedTaskID == task.id,
                                completeTask: completeTask
                            )
                                .tag(task.id)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                deleteTask(activeTasks[offset])
                            }
                        }
                    }
                }

                Section("Завершенные") {
                    if closedTasks.isEmpty {
                        Text("Нет завершенных задач")
                            .foregroundStyle(PlannerTheme.secondaryText)
                    } else {
                        ForEach(closedTasks) { task in
                            TaskListRow(
                                task: task,
                                isSelected: selectedTaskID == task.id,
                                completeTask: completeTask
                            )
                                .tag(task.id)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                deleteTask(closedTasks[offset])
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PlannerTheme.windowBackground)
        }
        .background(PlannerTheme.windowBackground)
    }
}

private struct TaskListRow: View {
    let task: PlannerTask
    let isSelected: Bool
    let completeTask: (PlannerTask) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                completeTask(task)
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? PlannerTheme.success : PlannerTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(task.status == .done)
            .help(task.status == .done ? "Задача выполнена" : "Отметить выполненной")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(task.status.displayName)
                    Text(task.priority.displayName)
                    if let scheduled = task.scheduled {
                        Text(scheduled.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let due = task.due {
                        Text("Срок \(due.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let projectTitle = task.project?.title {
                        Text(projectTitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            rowBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? PlannerTheme.accent.opacity(0.62) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .listRowBackground(isSelected ? PlannerTheme.accentSoft.opacity(0.28) : PlannerTheme.rowBackground)
    }

    private var rowBackground: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(PlannerTheme.accentSoft.opacity(0.78))
        }

        if let preset = task.project?.colorPreset {
            return AnyShapeStyle(PlannerTheme.projectGradient(preset, opacity: 0.18))
        }

        return AnyShapeStyle(Color.clear)
    }
}

private struct KanbanBoardView: View {
    let columns: [KanbanColumn]
    let searchText: String
    @Binding var selectedTaskID: UUID?
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let columnHeight = max(proxy.size.height - 32, 420)

            ZStack(alignment: .topLeading) {
                if columns.isEmpty {
                    ContentUnavailableView(
                        isSearching ? "Ничего не найдено" : "Нет карточек",
                        systemImage: MacSidebarSection.kanban.systemImage,
                        description: Text(isSearching ? "Попробуйте изменить запрос." : "Задачи появятся здесь как карточки по статусам.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(columns) { column in
                                KanbanColumnView(
                                    column: column,
                                    allColumns: columns,
                                    minHeight: columnHeight,
                                    selectedTaskID: $selectedTaskID,
                                    moveTask: moveTask
                                )
                                .frame(width: 270, alignment: .top)
                            }
                        }
                        .padding()
                        .frame(minHeight: proxy.size.height, alignment: .topLeading)
                    }
                }
            }
        }
        .background(PlannerTheme.windowBackground)
    }
}

private struct KanbanColumnView: View {
    let column: KanbanColumn
    let allColumns: [KanbanColumn]
    let minHeight: CGFloat
    @Binding var selectedTaskID: UUID?
    let moveTask: (PlannerTask, TaskStatus, PlannerTask?, PlannerTask?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(column.title)
                    .font(.headline)
                Spacer()
                Text("\(column.tasks.count)")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
            }

            VStack(spacing: 8) {
                ForEach(column.tasks) { task in
                    KanbanCardView(task: task) {
                        selectedTaskID = task.id
                    }
                }

                if column.tasks.isEmpty {
                    Text("Перетащите задачи сюда")
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(PlannerTheme.rowBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding()
        .frame(minHeight: minHeight, alignment: .top)
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

private struct KanbanCardView: View {
    let task: PlannerTask
    let selectTask: () -> Void

    var body: some View {
        Button(action: selectTask) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(task.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer()

                    Text(task.priority.displayName)
                        .font(.caption2)
                        .foregroundStyle(PlannerTheme.secondaryText)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let projectTitle = task.project?.title {
                        Label(projectTitle, systemImage: "folder")
                            .lineLimit(1)
                    }

                    if let scheduled = task.scheduled {
                        Label(scheduled.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .lineLimit(1)
                    }

                    if let due = task.due {
                        Label("Срок \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "flag")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(task.project.map { PlannerTheme.projectAccent($0.colorPreset).opacity(0.42) } ?? PlannerTheme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onDrag {
            NSItemProvider(object: task.id.uuidString as NSString)
        }
    }

    private var cardBackground: AnyShapeStyle {
        if let preset = task.project?.colorPreset {
            return AnyShapeStyle(PlannerTheme.projectGradient(preset, opacity: 0.20))
        }

        return AnyShapeStyle(PlannerTheme.elevatedBackground)
    }
}

private struct CalendarWeekView: View {
    let week: CalendarWeek
    let placements: [CalendarTaskPlacement]
    let searchText: String
    let isCurrentWeek: Bool
    @Binding var selectedTaskID: UUID?
    let openTaskInspector: (UUID) -> Void
    let goToPreviousWeek: () -> Void
    let goToNextWeek: () -> Void
    let goToCurrentWeek: () -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void
    let setTaskDue: (PlannerTask, Date) -> Void

    private let timeColumnWidth: CGFloat = 64
    private let dayColumnWidth: CGFloat = 164
    private let slotHeight: CGFloat = 24

    private var timelineHeight: CGFloat {
        slotHeight * 48
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalendarWeekControlsView(
                week: week,
                placementCount: placements.count,
                isSearching: isSearching,
                isCurrentWeek: isCurrentWeek,
                goToPreviousWeek: goToPreviousWeek,
                goToNextWeek: goToNextWeek,
                goToCurrentWeek: goToCurrentWeek
            )
            .padding([.horizontal, .top])
            .padding(.bottom, 10)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    CalendarWeekHeader(
                        days: week.days,
                        timeColumnWidth: timeColumnWidth,
                        dayColumnWidth: dayColumnWidth
                    )

                    CalendarAllDayRow(
                        days: week.days,
                        placements: placements,
                        timeColumnWidth: timeColumnWidth,
                        dayColumnWidth: dayColumnWidth,
                        selectTask: openTaskInspector,
                        rescheduleTask: rescheduleTask
                    )

                    HStack(alignment: .top, spacing: 0) {
                        CalendarTimeAxis(
                            timeColumnWidth: timeColumnWidth,
                            slotHeight: slotHeight
                        )

                        ForEach(week.days, id: \.id) { day in
                            CalendarTimelineDayColumn(
                                day: day,
                                placements: timedPlacements(for: day),
                                allPlacements: placements,
                                dayColumnWidth: dayColumnWidth,
                                slotHeight: slotHeight,
                                timelineHeight: timelineHeight,
                                selectTask: openTaskInspector,
                                rescheduleTask: rescheduleTask,
                                setTaskDue: setTaskDue
                            )
                        }
                    }
                }
                .padding()
                .frame(
                    minWidth: timeColumnWidth + (dayColumnWidth * CGFloat(week.days.count)),
                    alignment: .topLeading
                )
            }
            .background(PlannerTheme.windowBackground)
        }
        .background(PlannerTheme.windowBackground)
    }

    private func timedPlacements(for day: CalendarDay) -> [CalendarTaskPlacement] {
        placements.filter { $0.day.id == day.id && !$0.isAllDay }
    }
}

private struct CalendarWeekControlsView: View {
    let week: CalendarWeek
    let placementCount: Int
    let isSearching: Bool
    let isCurrentWeek: Bool
    let goToPreviousWeek: () -> Void
    let goToNextWeek: () -> Void
    let goToCurrentWeek: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: goToPreviousWeek) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .help("Предыдущая неделя")

            VStack(alignment: .leading, spacing: 3) {
                Text(isCurrentWeek ? "Текущая неделя" : "Выбранная неделя")
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(weekRangeText)
                    Text(statusText)
                }
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
            }

            Spacer(minLength: 16)

            Button("Сегодня", action: goToCurrentWeek)
                .buttonStyle(.bordered)
                .disabled(isCurrentWeek)

            Button(action: goToNextWeek) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .help("Следующая неделя")
        }
        .padding(12)
        .background(PlannerTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
        )
    }

    private var statusText: String {
        if placementCount == 0 {
            return isSearching ? "Нет совпадений" : "Нет задач"
        }

        return "\(placementCount) событий"
    }

    private var weekRangeText: String {
        guard let first = week.days.first?.date, let last = week.days.last?.date else {
            return ""
        }

        return "\(first.formatted(date: .abbreviated, time: .omitted)) - \(last.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct CalendarWeekHeader: View {
    let days: [CalendarDay]
    let timeColumnWidth: CGFloat
    let dayColumnWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("Время")
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.trailing, 8)

            ForEach(days, id: \.id) { day in
                VStack(spacing: 2) {
                    Text(day.title)
                        .font(.headline)

                    Text(day.subtitle)
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                }
                .frame(width: dayColumnWidth)
                .padding(.vertical, 8)
                .background(PlannerTheme.panelBackground, in: Rectangle())
                .border(PlannerTheme.subtleBorder, width: 0.5)
            }
        }
    }
}

private struct CalendarAllDayRow: View {
    let days: [CalendarDay]
    let placements: [CalendarTaskPlacement]
    let timeColumnWidth: CGFloat
    let dayColumnWidth: CGFloat
    let selectTask: (UUID) -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Весь день")
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 12)

            ForEach(days, id: \.id) { day in
                CalendarAllDayCell(
                    day: day,
                    placements: allDayPlacements(for: day),
                    allPlacements: placements,
                    dayColumnWidth: dayColumnWidth,
                    selectTask: selectTask,
                    rescheduleTask: rescheduleTask
                )
            }
        }
    }

    private func allDayPlacements(for day: CalendarDay) -> [CalendarTaskPlacement] {
        placements.filter { $0.day.id == day.id && $0.isAllDay }
    }
}

private struct CalendarAllDayCell: View {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let allPlacements: [CalendarTaskPlacement]
    let dayColumnWidth: CGFloat
    let selectTask: (UUID) -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(placements) { placement in
                CalendarTaskBlock(
                    placement: placement,
                    width: dayColumnWidth - 12,
                    height: 26,
                    selectTask: { selectTask(placement.task.id) }
                )
            }

            if placements.isEmpty {
                Text("Нет задач")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
        }
        .padding(6)
        .frame(width: dayColumnWidth, alignment: .topLeading)
        .frame(minHeight: 58, alignment: .topLeading)
        .background(PlannerTheme.panelBackground.opacity(0.68), in: Rectangle())
        .border(PlannerTheme.subtleBorder, width: 0.5)
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            CalendarDragHelper.loadTask(from: providers, placements: allPlacementsForLookup) { task in
                rescheduleTask(task, CalendarService.date(for: day, hour: 0, minute: 0))
            }

            return true
        }
    }

    private var allPlacementsForLookup: [CalendarTaskPlacement] {
        allPlacements
    }
}

private struct CalendarTimeAxis: View {
    let timeColumnWidth: CGFloat
    let slotHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .frame(width: timeColumnWidth, height: slotHeight * 2, alignment: .topTrailing)
                    .padding(.trailing, 8)
            }
        }
    }
}

private struct CalendarTimelineDayColumn: View {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let allPlacements: [CalendarTaskPlacement]
    let dayColumnWidth: CGFloat
    let slotHeight: CGFloat
    let timelineHeight: CGFloat
    let selectTask: (UUID) -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void
    let setTaskDue: (PlannerTask, Date) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CalendarGridCanvas(
                dayColumnWidth: dayColumnWidth,
                slotHeight: slotHeight,
                timelineHeight: timelineHeight
            )

            ForEach(placements) { placement in
                CalendarTaskBlock(
                    placement: placement,
                    width: dayColumnWidth - 12,
                    height: height(for: placement),
                    slotHeight: slotHeight,
                    selectTask: { selectTask(placement.task.id) },
                    resizeTask: { due in
                        setTaskDue(placement.task, due)
                    }
                )
                .offset(x: 6, y: yOffset(for: placement))
            }
        }
        .frame(width: dayColumnWidth, height: timelineHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(
            of: [.plainText],
            delegate: CalendarTimelineDropDelegate(
                day: day,
                placements: allPlacements,
                slotHeight: slotHeight,
                timelineHeight: timelineHeight,
                rescheduleTask: rescheduleTask
            )
        )
        .border(PlannerTheme.subtleBorder, width: 0.5)
    }

    private func yOffset(for placement: CalendarTaskPlacement) -> CGFloat {
        (CGFloat(placement.startMinute) / 30) * slotHeight
    }

    private func height(for placement: CalendarTaskPlacement) -> CGFloat {
        max(24, (CGFloat(placement.durationMinutes) / 30) * slotHeight - 2)
    }
}

private struct CalendarGridCanvas: View {
    let dayColumnWidth: CGFloat
    let slotHeight: CGFloat
    let timelineHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            for slotIndex in 0...48 {
                let y = min(CGFloat(slotIndex) * slotHeight, size.height)
                let isHour = slotIndex.isMultiple(of: 2)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))

                context.stroke(
                    line,
                    with: .color(isHour ? PlannerTheme.border.opacity(0.70) : PlannerTheme.border.opacity(0.42)),
                    lineWidth: isHour ? 0.8 : 0.5
                )
            }
        }
        .background(PlannerTheme.rowBackground.opacity(0.36), in: Rectangle())
        .frame(width: dayColumnWidth, height: timelineHeight)
    }
}

private struct CalendarTimelineDropDelegate: DropDelegate {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let slotHeight: CGFloat
    let timelineHeight: CGFloat
    let rescheduleTask: (PlannerTask, Date) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let slotIndex = slotIndex(for: info.location.y)
        CalendarDragHelper.loadTask(from: info.itemProviders(for: [.plainText]), placements: placements) { task in
            let hour = slotIndex / 2
            let minute = slotIndex.isMultiple(of: 2) ? 0 : 30
            let date = CalendarService.date(for: day, hour: hour, minute: minute)
            rescheduleTask(task, date)
        }

        return true
    }

    private func slotIndex(for yPosition: CGFloat) -> Int {
        let clampedY = min(max(0, yPosition), max(0, timelineHeight - 1))
        return min(47, max(0, Int(clampedY / slotHeight)))
    }
}
private struct CalendarTaskBlock: View {
    let placement: CalendarTaskPlacement
    let width: CGFloat
    let height: CGFloat
    var slotHeight: CGFloat?
    let selectTask: () -> Void
    var resizeTask: ((Date) -> Void)?

    @State private var resizeEndMinute: Int?
    @State private var resizeStartEndMinute: Int?

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: selectTask) {
                HStack(spacing: 5) {
                    Image(systemName: placement.kind == .due ? "flag.fill" : "calendar")
                        .font(.caption2)
                        .foregroundStyle(placement.kind == .due ? PlannerTheme.danger : PlannerTheme.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(placement.task.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(metaText)
                            .font(.caption2)
                            .foregroundStyle(PlannerTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: width, height: effectiveHeight, alignment: .leading)
                .background(blockBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .onDrag {
                NSItemProvider(object: placement.task.id.uuidString as NSString)
            }

            if canResize {
                CalendarResizeHandle()
                    .frame(width: width - 8, height: 16)
                    .gesture(resizeGesture)
            }
        }
        .frame(width: width, height: effectiveHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if resizeEndMinute != nil {
                CalendarResizePreview(text: resizePreviewText)
                    .offset(y: -36)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var metaText: String {
        if placement.isAllDay {
            return placement.kind.title
        }

        let hour = placement.startMinute / 60
        let minute = placement.startMinute % 60
        let time = String(format: "%02d:%02d", hour, minute)
        return "\(placement.kind.title) \(time)"
    }

    private var canResize: Bool {
        placement.kind == .scheduled && !placement.isAllDay && slotHeight != nil && resizeTask != nil
    }

    private var effectiveEndMinute: Int {
        resizeEndMinute ?? baseEndMinute
    }

    private var effectiveHeight: CGFloat {
        let duration = max(1, effectiveEndMinute - placement.startMinute)
        let heightForDuration = (CGFloat(duration) / 30) * (slotHeight ?? 24)
        return max(24, heightForDuration - 2)
    }

    private var baseEndMinute: Int {
        min(1_439, placement.startMinute + max(30, placement.durationMinutes))
    }

    private var minimumEndMinute: Int {
        min(1_439, placement.startMinute + 30)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let slotHeight else {
                    return
                }

                if resizeStartEndMinute == nil {
                    resizeStartEndMinute = baseEndMinute
                    resizeEndMinute = baseEndMinute
                }

                let slotDelta = stableSlotDelta(
                    for: value.translation.height,
                    slotHeight: slotHeight
                )
                let minuteDelta = slotDelta * 30
                let nextEndMinute = clampedEndMinute((resizeStartEndMinute ?? baseEndMinute) + minuteDelta)

                guard nextEndMinute != resizeEndMinute else {
                    return
                }

                resizeEndMinute = nextEndMinute
            }
            .onEnded { _ in
                defer {
                    resizeStartEndMinute = nil
                    self.resizeEndMinute = nil
                }

                guard
                    let resizeEndMinute,
                    resizeEndMinute != baseEndMinute
                else {
                    return
                }

                resizeTask?(date(forMinuteOfDay: resizeEndMinute))
            }
    }

    private var resizePreviewText: String {
        let start = timeText(forMinuteOfDay: placement.startMinute)
        let end = timeText(forMinuteOfDay: effectiveEndMinute)
        let duration = durationText(minutes: max(1, effectiveEndMinute - placement.startMinute))
        return "\(start) - \(end) · \(duration)"
    }

    private func clampedEndMinute(_ minute: Int) -> Int {
        min(1_439, max(minimumEndMinute, minute))
    }

    private func stableSlotDelta(for translation: CGFloat, slotHeight: CGFloat) -> Int {
        let deadband = slotHeight * 0.25

        if translation > deadband {
            return Int(floor((translation - deadband) / slotHeight)) + 1
        }

        if translation < -deadband {
            return Int(ceil((translation + deadband) / slotHeight)) - 1
        }

        return 0
    }

    private func date(forMinuteOfDay minute: Int) -> Date {
        let clamped = clampedEndMinute(minute)
        return CalendarService.date(
            for: placement.day,
            hour: clamped / 60,
            minute: clamped % 60
        )
    }

    private func timeText(forMinuteOfDay minute: Int) -> String {
        let clamped = max(0, min(1_439, minute))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    private func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0 && remainingMinutes > 0 {
            return "\(hours) ч \(remainingMinutes) мин"
        } else if hours > 0 {
            return "\(hours) ч"
        } else {
            return "\(remainingMinutes) мин"
        }
    }

    private var blockBackground: AnyShapeStyle {
        if placement.kind == .due {
            return AnyShapeStyle(PlannerTheme.danger.opacity(0.16))
        }

        if let preset = placement.task.project?.colorPreset {
            return AnyShapeStyle(PlannerTheme.projectGradient(preset, opacity: 0.28))
        }

        return AnyShapeStyle(PlannerTheme.accentSoft.opacity(0.86))
    }

    private var borderColor: Color {
        if placement.kind == .due {
            return PlannerTheme.danger.opacity(0.38)
        }

        if let preset = placement.task.project?.colorPreset {
            return PlannerTheme.projectAccent(preset).opacity(0.48)
        }

        return PlannerTheme.accent.opacity(0.42)
    }
}

private struct CalendarResizeHandle: View {
    var body: some View {
        Capsule()
            .fill(PlannerTheme.accent.opacity(0.72))
            .frame(width: 34, height: 4)
            .frame(maxWidth: .infinity, minHeight: 10)
            .contentShape(Rectangle())
    }
}

private struct CalendarResizePreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PlannerTheme.elevatedBackground.opacity(0.96), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(PlannerTheme.accent.opacity(0.36), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
    }
}

private enum CalendarDragHelper {
    static func loadTask(
        from providers: [NSItemProvider],
        placements: [CalendarTaskPlacement],
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
                guard let task = placements.first(where: { $0.task.id == taskID })?.task else {
                    return
                }

                completion(task)
            }
        }
    }
}

private struct SettingsPlaceholderView: View {
    let settings: AppSettings?
    let setHideEmptyKanbanColumns: (Bool, AppSettings) -> Void
    let setTheme: (AppTheme, AppSettings) -> Void
    let setDefaultReminderLeadMinutes: (Int, AppSettings) -> Void
    let requestNotificationAuthorization: () -> Void
    let notificationStatus: String
    @Binding var syncToken: String
    let syncStatus: String
    let setSyncEnabled: (Bool, AppSettings) -> Void
    let setSyncServerURL: (String, AppSettings) -> Void
    let setSyncCertificateFingerprint: (String, AppSettings) -> Void
    let setSyncToken: (String) -> Void
    let testSyncConnection: (AppSettings) -> Void
    let bootstrapSync: (AppSettings) -> Void
    let syncNow: (AppSettings) -> Void
    let completedTaskCount: Int
    let clearCompletedTasks: () -> Void
    let exportBackup: () -> Void
    let importBackup: () -> Void

    @State private var isClearCompletedConfirmationPresented = false

    var body: some View {
        Form {
            Section("Настройки") {
                if let settings {
                    Picker(
                        "Тема",
                        selection: Binding(
                            get: { settings.appTheme },
                            set: { setTheme($0, settings) }
                        )
                    ) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName)
                                .tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(
                        "Скрывать пустые колонки канбана",
                        isOn: Binding(
                            get: { settings.hideEmptyKanbanColumns },
                            set: { setHideEmptyKanbanColumns($0, settings) }
                        )
                    )

                    Stepper(
                        "Напоминать за \(settings.defaultReminderLeadMinutes) мин",
                        value: Binding(
                            get: { settings.defaultReminderLeadMinutes },
                            set: { setDefaultReminderLeadMinutes($0, settings) }
                        ),
                        in: 0...240,
                        step: 5
                    )
                } else {
                    LabeledContent("Настройки", value: "Загрузка")
                }
            }

            Section("Уведомления") {
                LabeledContent("Разрешение", value: notificationStatus)

                Button(action: requestNotificationAuthorization) {
                    Label("Запросить разрешение", systemImage: "bell.badge")
                }
            }

            Section("Синхронизация") {
                if let settings {
                    Toggle(
                        "Включить синхронизацию",
                        isOn: Binding(
                            get: { settings.syncEnabled },
                            set: { setSyncEnabled($0, settings) }
                        )
                    )

                    TextField(
                        "Server URL",
                        text: Binding(
                            get: { settings.syncServerURL },
                            set: { setSyncServerURL($0, settings) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    SecureField(
                        "API token",
                        text: Binding(
                            get: { syncToken },
                            set: { setSyncToken($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "SHA256 fingerprint",
                        text: Binding(
                            get: { settings.syncCertificateFingerprint },
                            set: { setSyncCertificateFingerprint($0, settings) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    LabeledContent("Device ID", value: settings.syncDeviceID)
                    LabeledContent("Cursor", value: "\(settings.syncLastCursor)")
                    LabeledContent("Последняя синхронизация", value: settings.syncLastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Нет")
                    LabeledContent("Статус", value: syncStatus)

                    HStack {
                        Button("Test connection") {
                            testSyncConnection(settings)
                        }

                        Button("Bootstrap server") {
                            bootstrapSync(settings)
                        }

                        Button("Sync now") {
                            syncNow(settings)
                        }
                    }
                } else {
                    LabeledContent("Синхронизация", value: "Загрузка")
                }
            }

            Section("Резервная копия") {
                HStack {
                    Button(action: exportBackup) {
                        Label("Экспорт JSON", systemImage: "square.and.arrow.up")
                    }

                    Button(action: importBackup) {
                        Label("Импорт JSON", systemImage: "square.and.arrow.down")
                    }
                }
            }

            Section("Очистка") {
                LabeledContent("Выполненные задачи", value: "\(completedTaskCount)")

                Button(role: .destructive) {
                    isClearCompletedConfirmationPresented = true
                } label: {
                    Label("Очистить выполненные задачи", systemImage: "trash")
                }
                .disabled(completedTaskCount == 0)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .confirmationDialog(
            "Очистить выполненные задачи?",
            isPresented: $isClearCompletedConfirmationPresented
        ) {
            Button("Удалить \(completedTaskCount)", role: .destructive) {
                clearCompletedTasks()
            }

            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены задачи со статусом «Выполнено». Удаление попадет в синхронизацию.")
        }
    }
}
#endif
