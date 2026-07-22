import SwiftData
import SwiftUI

#if os(iOS)
struct IOSMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlannerTask.createdAt, order: .forward) private var tasks: [PlannerTask]
    @Query(sort: \Project.createdAt, order: .forward) private var projects: [Project]
    @Query(sort: \AppSettings.createdAt, order: .forward) private var appSettings: [AppSettings]

    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var todayListMode: IOSTodayListMode = .today
    @State private var upcomingRange: UpcomingRange = .nextWeek
    @State private var selectedCalendarDate = Date.now
    @State private var syncToken = ""
    @State private var syncStatus = "Не синхронизировано"

    private var currentSettings: AppSettings? {
        appSettings.first
    }

    var body: some View {
        TabView {
            taskNavigation(
                title: "Сегодня",
                systemImage: "sun.max",
                tasks: todayTasksForSelectedMode,
                sections: upcomingSectionsForToday,
                controls: todayControls
            )
            .tabItem {
                Label("Сегодня", systemImage: "sun.max")
            }

            taskNavigation(
                title: "Входящие",
                systemImage: "tray",
                tasks: TaskListService.inboxTasks(from: tasks, searchText: searchText)
            )
            .tabItem {
                Label("Входящие", systemImage: "tray")
            }

            NavigationStack {
                IOSKanbanView(
                    columns: KanbanService.columns(
                        from: tasks,
                        searchText: searchText,
                        hideEmptyColumns: currentSettings?.hideEmptyKanbanColumns ?? false
                    ),
                    projects: projects,
                    searchText: $searchText,
                    moveTask: moveTask,
                    completeTask: completeTask
                )
            }
            .tabItem {
                Label("Канбан", systemImage: "rectangle.3.group")
            }

            NavigationStack {
                let week = calendarWeek

                IOSCalendarView(
                    week: week,
                    placements: CalendarService.placements(
                        from: tasks,
                        searchText: searchText,
                        week: week
                    ),
                    projects: projects,
                    searchText: $searchText,
                    isCurrentWeek: isCurrentCalendarWeek,
                    goToPreviousWeek: { moveSelectedCalendarWeek(by: -1) },
                    goToNextWeek: { moveSelectedCalendarWeek(by: 1) },
                    goToCurrentWeek: goToCurrentCalendarWeek,
                    rescheduleTask: rescheduleTask,
                    completeTask: completeTask
                )
            }
            .tabItem {
                Label("Календарь", systemImage: "calendar")
            }

            moreNavigation
            .tabItem {
                Label("Еще", systemImage: "ellipsis.circle")
            }
        }
        .tint(PlannerTheme.accent)
        .background(PlannerTheme.windowBackground)
        .preferredColorScheme(currentSettings?.appTheme.colorScheme)
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            ensureAppSettings()
            syncToken = KeychainService.loadSyncToken()
        }
    }

    private var moreNavigation: some View {
        NavigationStack {
            List {
                Section("Разделы") {
                    NavigationLink {
                        IOSProjectsView(
                            projects: TaskListService.activeProjects(from: projects, searchText: searchText),
                            allProjects: projects,
                            tasks: tasks,
                            searchText: $searchText,
                            createProject: createProject,
                            deleteProject: deleteProject,
                            completeTask: completeTask
                        )
                    } label: {
                        Label("Проекты", systemImage: "folder")
                    }

                    NavigationLink {
                        IOSSettingsView(
                            settings: currentSettings,
                            setTheme: setTheme,
                            setHideEmptyKanbanColumns: setHideEmptyKanbanColumns,
                            setDefaultReminderLeadMinutes: setDefaultReminderLeadMinutes,
                            syncToken: $syncToken,
                            syncStatus: syncStatus,
                            setSyncEnabled: setSyncEnabled,
                            setSyncServerURL: setSyncServerURL,
                            setSyncCertificateFingerprint: setSyncCertificateFingerprint,
                            setSyncToken: setSyncToken,
                            testSyncConnection: testSyncConnection,
                            bootstrapSync: bootstrapSync,
                            syncNow: syncNow,
                            importBackup: importBackup,
                            exportBackup: exportBackup
                        )
                    } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Еще")
            .scrollContentBackground(.hidden)
            .background(PlannerTheme.windowBackground)
            .tint(PlannerTheme.accent)
        }
    }

    private func taskNavigation(
        title: String,
        systemImage: String,
        tasks: [PlannerTask],
        sections: [UpcomingSection] = [],
        controls: AnyView? = nil
    ) -> some View {
        NavigationStack {
            IOSTaskListView(
                title: title,
                systemImage: systemImage,
                tasks: tasks,
                sections: sections,
                controls: controls,
                projects: projects,
                searchText: $searchText,
                createTask: createTask,
                deleteTask: deleteTask,
                completeTask: completeTask
            )
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var calendarWeek: CalendarWeek {
        CalendarService.week(containing: selectedCalendarDate)
    }

    private var isCurrentCalendarWeek: Bool {
        Calendar.current.isDate(
            calendarWeek.startOfWeek,
            inSameDayAs: CalendarService.currentWeek().startOfWeek
        )
    }

    private var todayTasksForSelectedMode: [PlannerTask] {
        guard todayListMode == .today else {
            return []
        }

        return TaskListService.todayTasks(from: tasks, searchText: searchText)
    }

    private var upcomingSectionsForToday: [UpcomingSection] {
        guard todayListMode == .upcoming else {
            return []
        }

        return TaskListService
            .upcomingSections(from: tasks, searchText: searchText, range: upcomingRange)
            .filter { $0.kind != .today }
    }

    private var todayControls: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 10) {
                Picker("Режим", selection: $todayListMode) {
                    ForEach(IOSTodayListMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if todayListMode == .upcoming {
                    Picker("Диапазон", selection: $upcomingRange) {
                        ForEach(UpcomingRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.vertical, 4)
        )
    }

    private func createTask(_ title: String) {
        do {
            try PlannerDataService.createTask(
                title: title,
                context: modelContext,
                status: .inbox
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTask(_ task: PlannerTask) {
        do {
            try PlannerDataService.deleteTask(task, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeTask(_ task: PlannerTask) {
        guard task.status != .done else {
            return
        }

        do {
            try PlannerDataService.setTaskStatus(task, status: .done, context: modelContext)
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

    private func createProject(_ title: String) {
        do {
            try PlannerDataService.createProject(title: title, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: Project) {
        do {
            try PlannerDataService.deleteProject(project, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setTheme(_ theme: AppTheme, settings: AppSettings) {
        do {
            try PlannerDataService.setTheme(theme, settings: settings, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setHideEmptyKanbanColumns(_ isHidden: Bool, settings: AppSettings) {
        do {
            try PlannerDataService.setHideEmptyKanbanColumns(
                isHidden,
                settings: settings,
                context: modelContext
            )
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncEnabled(_ isEnabled: Bool, settings: AppSettings) {
        do {
            try PlannerDataService.setSyncEnabled(isEnabled, settings: settings, context: modelContext)
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
        Task {
            do {
                let response = try await SyncService.testConnection(settings: settings, token: syncToken)
                syncStatus = "Подключение OK, cursor \(response.serverCursor)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bootstrapSync(_ settings: AppSettings) {
        Task {
            do {
                let result = try await SyncService.bootstrap(context: modelContext, settings: settings, token: syncToken)
                syncStatus = "Bootstrap OK: отправлено \(result.pushed), cursor \(result.cursor)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncNow(_ settings: AppSettings) {
        Task {
            do {
                let result = try await SyncService.syncNow(context: modelContext, settings: settings, token: syncToken)
                syncStatus = "Sync OK: отправлено \(result.pushed), получено \(result.pulled), cursor \(result.cursor)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportBackup() throws -> Data {
        try BackupService.exportData(context: modelContext)
    }

    private func importBackup(_ data: Data) throws {
        try BackupService.importData(data, context: modelContext)
    }

    private func ensureAppSettings() {
        do {
            try PlannerDataService.ensureAppSettings(context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
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

private enum IOSTodayListMode: String, CaseIterable, Identifiable {
    case today
    case upcoming

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today:
            "Сегодня"
        case .upcoming:
            "Позже"
        }
    }
}
#endif
