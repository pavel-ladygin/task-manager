import SwiftData
import SwiftUI

#if os(iOS)
private enum IOSCalendarEventAction {
    case save(CalendarEvent, CalendarEventOccurrence, CalendarEventEditorValues)
    case delete(CalendarEvent, CalendarEventOccurrence)
    case move(CalendarEvent, CalendarEventOccurrence, Date)
    case resize(CalendarEvent, CalendarEventOccurrence, Date)
}

struct IOSMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \PlannerTask.createdAt, order: .forward) private var tasks: [PlannerTask]
    @Query(sort: \Project.createdAt, order: .forward) private var projects: [Project]
    @Query(sort: \AppSettings.createdAt, order: .forward) private var appSettings: [AppSettings]
    @Query(sort: \CalendarEvent.start, order: .forward) private var calendarEvents: [CalendarEvent]
    @Query private var calendarEventExceptions: [CalendarEventException]

    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var todayListMode: IOSTodayListMode = .today
    @State private var upcomingRange: UpcomingRange = .nextWeek
    @State private var selectedCalendarDate = Date.now
    @State private var syncToken = ""
    @State private var syncStatus = "Не синхронизировано"
    @State private var autoSyncTask: Task<Void, Never>?
    @State private var activeSyncPollingTask: Task<Void, Never>?
    @State private var isAutoSyncing = false
    @State private var taskEditorSession: TaskEditorSession?
    @State private var calendarEventEditorEvent: CalendarEvent?
    @State private var calendarEventEditorOccurrence: CalendarEventOccurrence?
    @State private var calendarEventEditorStart = Date.now
    @State private var isCalendarEventEditorPresented = false
    @State private var pendingCalendarEventAction: IOSCalendarEventAction?
    @StateObject private var voiceInputController = TaskVoiceInputController()

    private var currentSettings: AppSettings? {
        appSettings.first
    }

    var body: some View {
        ZStack {
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
                    createTask: createKanbanTask,
                    moveTask: moveTask,
                    openTask: openTaskEditor,
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
                    eventOccurrences: calendarEventOccurrences(for: week),
                    searchText: $searchText,
                    isCurrentWeek: isCurrentCalendarWeek,
                    goToPreviousWeek: { moveSelectedCalendarWeek(by: -1) },
                    goToNextWeek: { moveSelectedCalendarWeek(by: 1) },
                    goToCurrentWeek: goToCurrentCalendarWeek,
                    movePlacement: moveCalendarPlacement,
                    resizePlacement: resizeCalendarPlacement,
                    openTask: openTaskEditor,
                    completeTask: completeTask,
                    openEvent: { occurrence in
                        calendarEventEditorEvent = calendarEvents.first { $0.id == occurrence.eventID }
                        calendarEventEditorOccurrence = occurrence
                        calendarEventEditorStart = occurrence.start
                        isCalendarEventEditorPresented = true
                    },
                    moveEvent: { occurrence, date in
                        guard let event = calendarEvents.first(where: { $0.id == occurrence.eventID }) else { return }
                        pendingCalendarEventAction = .move(event, occurrence, date)
                    },
                    resizeEvent: { occurrence, date in
                        guard let event = calendarEvents.first(where: { $0.id == occurrence.eventID }) else { return }
                        pendingCalendarEventAction = .resize(event, occurrence, date)
                    },
                    createEvent: { date in
                        calendarEventEditorEvent = nil
                        calendarEventEditorOccurrence = nil
                        calendarEventEditorStart = date
                        isCalendarEventEditorPresented = true
                    }
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

            if let taskEditorSession {
                taskEditorOverlay(taskEditorSession)
                    .zIndex(10)
            }
        }
        .environmentObject(voiceInputController)
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
            triggerAutoSyncNow(reason: "Запуск")
            startActiveSyncPolling()
        }
        .onDisappear {
            stopActiveSyncPolling()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                triggerAutoSyncNow(reason: "Вход")
                startActiveSyncPolling()
            case .inactive, .background:
                stopActiveSyncPolling()
                triggerAutoSyncNow(reason: "Выход")
            @unknown default:
                break
            }
        }
        .onChange(of: taskSyncSignature) { _, _ in
            taskEditorSession?.refreshIfClean()
            scheduleAutoSync(reason: "Изменения задач")
        }
        .onChange(of: projectSyncSignature) { _, _ in
            scheduleAutoSync(reason: "Изменения проектов")
        }
        .sheet(isPresented: $isCalendarEventEditorPresented) {
            NavigationStack {
                CalendarEventEditorView(
                    event: calendarEventEditorEvent,
                    occurrence: calendarEventEditorOccurrence,
                    projects: projects,
                    defaultStart: calendarEventEditorStart,
                    defaultReminder: currentSettings.map { CalendarEventReminder(rawValue: $0.defaultReminderLeadMinutes) ?? .fifteenMinutes } ?? .fifteenMinutes,
                    onSave: saveCalendarEvent,
                    onDelete: calendarEventEditorEvent == nil ? nil : requestDeleteCalendarEvent,
                    onCancel: { isCalendarEventEditorPresented = false }
                )
            }
        }
        .confirmationDialog("Изменить повторяющееся событие", isPresented: calendarEventActionBinding) {
            Button("Только это событие") { performPendingCalendarEventAction(onlyOccurrence: true) }
            Button("Всю серию") { performPendingCalendarEventAction(onlyOccurrence: false) }
            Button("Отмена", role: .cancel) { pendingCalendarEventAction = nil }
        } message: {
            Text("Выберите область изменения.")
        }
    }

    private var moreNavigation: some View {
        NavigationStack {
            List {
                Section("Разделы") {
                    NavigationLink {
                        HabitManagementView()
                    } label: {
                        Label("Привычки", systemImage: "sparkles")
                    }

                    NavigationLink {
                        IOSProjectsView(
                            projects: TaskListService.activeProjects(from: projects, searchText: searchText),
                            tasks: tasks,
                            searchText: $searchText,
                            createProject: createProject,
                            deleteProject: deleteProject,
                            openTask: openTaskEditor,
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
                            completedTaskCount: completedTaskCount,
                            clearCompletedTasks: clearCompletedTasks,
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
                searchText: $searchText,
                createTask: createTask,
                deleteTask: deleteTask,
                openTask: openTaskEditor,
                completeTask: completeTask
            )
        }
    }

    private func taskEditorOverlay(_ session: TaskEditorSession) -> some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: saveAndCloseTaskEditor)

                NavigationStack {
                    IOSTaskDetailView(
                        session: session,
                        projects: projects,
                        saveAndClose: saveAndCloseTaskEditor,
                        discardAndClose: discardAndCloseTaskEditor,
                        deleteTask: deleteTaskFromEditor
                    )
                }
                .frame(
                    width: min(max(proxy.size.width - 24, 300), 620),
                    height: min(max(proxy.size.height - 48, 420), 780)
                )
                .background(PlannerTheme.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(12)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func openTaskEditor(_ task: PlannerTask) {
        voiceInputController.stop()
        if let taskEditorSession {
            guard taskEditorSession.saveAndSwitch(
                to: task,
                projects: projects,
                context: modelContext
            ) else {
                return
            }
        } else {
            taskEditorSession = TaskEditorSession.open(task)
        }
    }

    private func saveAndCloseTaskEditor() {
        guard let taskEditorSession else { return }
        taskEditorSession.saveAndClose(projects: projects, context: modelContext) {
            self.taskEditorSession = nil
            scheduleAutoSync(reason: "Изменена задача")
        }
    }

    private func discardAndCloseTaskEditor() {
        guard let taskEditorSession else { return }
        taskEditorSession.discardAndClose {
            self.taskEditorSession = nil
        }
    }

    private func deleteTaskFromEditor(_ task: PlannerTask) {
        deleteTask(task)
        taskEditorSession = nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
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

    private var completedTaskCount: Int {
        tasks.filter { $0.status == .done }.count
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

    private func calendarEventOccurrences(for week: CalendarWeek) -> [CalendarEventOccurrence] {
        guard let first = week.days.first?.date, let last = week.days.last?.date,
              let upper = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return [] }
        return calendarEvents.flatMap {
            CalendarEventService.occurrences(for: $0, from: first, to: upper,
                                             exceptions: calendarEventExceptions)
        }.filter {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.notes.localizedCaseInsensitiveContains(searchText)
                || ($0.project?.title.localizedCaseInsensitiveContains(searchText) ?? false)
        }.sorted { $0.start < $1.start }
    }

    private func saveCalendarEvent(_ values: CalendarEventEditorValues) {
        do {
            let project = values.projectID.flatMap { id in projects.first { $0.id == id } }
            if let event = calendarEventEditorEvent {
                if event.recurrence != .none, let occurrence = calendarEventEditorOccurrence {
                    pendingCalendarEventAction = .save(event, occurrence, values)
                    isCalendarEventEditorPresented = false
                    return
                }
                try CalendarEventService.update(event, title: values.title, notes: values.notes,
                                               start: values.start, end: values.end,
                                               timeZoneIdentifier: event.timeZoneIdentifier,
                                               recurrence: values.recurrence,
                                               recurrenceEndDate: values.recurrenceEndDate,
                                               reminder: values.reminder, project: project,
                                               context: modelContext)
            } else {
                _ = try CalendarEventService.create(title: values.title, notes: values.notes,
                                                    start: values.start, end: values.end,
                                                    recurrence: values.recurrence,
                                                    recurrenceEndDate: values.recurrenceEndDate,
                                                    reminder: values.reminder, project: project,
                                                    context: modelContext)
            }
            isCalendarEventEditorPresented = false
            scheduleAutoSync(reason: "Изменено расписание")
        } catch { errorMessage = error.localizedDescription }
    }

    private func requestDeleteCalendarEvent() {
        guard let event = calendarEventEditorEvent else { return }
        if event.recurrence != .none, let occurrence = calendarEventEditorOccurrence {
            pendingCalendarEventAction = .delete(event, occurrence)
            isCalendarEventEditorPresented = false
        } else {
            do { try CalendarEventService.deleteSeries(event, context: modelContext); isCalendarEventEditorPresented = false; scheduleAutoSync(reason: "Удалено событие") }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var calendarEventActionBinding: Binding<Bool> {
        Binding(get: { pendingCalendarEventAction != nil }, set: { if !$0 { pendingCalendarEventAction = nil } })
    }

    private func performPendingCalendarEventAction(onlyOccurrence: Bool) {
        guard let action = pendingCalendarEventAction else { return }
        defer { pendingCalendarEventAction = nil }
        do {
            switch action {
            case let .save(event, occurrence, values):
                let project = values.projectID.flatMap { id in projects.first { $0.id == id } }
                if onlyOccurrence {
                    try CalendarEventService.updateOccurrence(of: event, on: occurrence.occurrenceDate,
                        title: values.title, notes: values.notes, start: values.start, end: values.end,
                        reminder: values.reminder, projectOverrideSet: true, project: project, context: modelContext)
                } else {
                    try CalendarEventService.update(event, title: values.title, notes: values.notes,
                        start: values.start, end: values.end, timeZoneIdentifier: event.timeZoneIdentifier,
                        recurrence: values.recurrence, recurrenceEndDate: values.recurrenceEndDate,
                        reminder: values.reminder, project: project, context: modelContext)
                }
            case let .delete(event, occurrence):
                if onlyOccurrence { try CalendarEventService.deleteOccurrence(of: event, on: occurrence.occurrenceDate, context: modelContext) }
                else { try CalendarEventService.deleteSeries(event, context: modelContext) }
            case let .move(event, occurrence, date):
                if onlyOccurrence {
                    try CalendarEventService.updateOccurrence(of: event, on: occurrence.occurrenceDate,
                        start: date, end: date.addingTimeInterval(occurrence.end.timeIntervalSince(occurrence.start)), context: modelContext)
                } else {
                    let delta = date.timeIntervalSince(occurrence.start)
                    try CalendarEventService.update(event, title: event.title, notes: event.notes,
                        start: event.start.addingTimeInterval(delta), end: event.end.addingTimeInterval(delta),
                        timeZoneIdentifier: event.timeZoneIdentifier, recurrence: event.recurrence,
                        recurrenceEndDate: event.recurrenceEndDate, reminder: event.reminder, project: event.project, context: modelContext)
                }
            case let .resize(event, occurrence, end):
                if onlyOccurrence { try CalendarEventService.updateOccurrence(of: event, on: occurrence.occurrenceDate, start: occurrence.start, end: end, context: modelContext) }
                else { try CalendarEventService.update(event, title: event.title, notes: event.notes, start: event.start,
                    end: event.start.addingTimeInterval(end.timeIntervalSince(occurrence.start)), timeZoneIdentifier: event.timeZoneIdentifier,
                    recurrence: event.recurrence, recurrenceEndDate: event.recurrenceEndDate, reminder: event.reminder, project: event.project, context: modelContext) }
            }
            scheduleAutoSync(reason: "Изменено расписание")
        } catch { errorMessage = error.localizedDescription }
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
                HabitRitualCard()

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
            scheduleAutoSync(reason: "Создана задача")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createKanbanTask(_ title: String, status: TaskStatus) {
        do {
            let columnTasks = tasks.filter { $0.status == status && $0.showInKanban }
            let task = try PlannerDataService.createTask(title: title, context: modelContext, status: status)
            task.manualOrder = KanbanService.nextManualOrder(in: columnTasks)
            try PlannerDataService.markTaskUpdated(task, context: modelContext)
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteTask(_ task: PlannerTask) {
        do {
            try PlannerDataService.deleteTask(task, context: modelContext)
            scheduleAutoSync(reason: "Удалена задача")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func clearCompletedTasks() throws -> Int {
        let deletedCount = try PlannerDataService.deleteCompletedTasks(from: tasks, context: modelContext)

        if deletedCount > 0 {
            scheduleAutoSync(reason: "Очищены выполненные задачи")
        }

        return deletedCount
    }

    private func completeTask(_ task: PlannerTask) {
        guard task.status != .done else {
            return
        }

        do {
            try PlannerDataService.setTaskStatus(task, status: .done, context: modelContext)
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
            scheduleAutoSync(reason: "Задача перенесена")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveCalendarPlacement(_ placement: CalendarTaskPlacement, to date: Date) {
        do {
            if placement.kind == .due {
                try PlannerDataService.setTaskDue(placement.task, to: date, context: modelContext)
            } else {
                try PlannerDataService.rescheduleTask(placement.task, to: date, context: modelContext)
            }
            scheduleAutoSync(reason: "Задача перенесена")
        } catch { errorMessage = error.localizedDescription }
    }

    private func resizeCalendarPlacement(_ placement: CalendarTaskPlacement, to due: Date) {
        do {
            try PlannerDataService.setTaskDue(placement.task, to: due, context: modelContext)
            scheduleAutoSync(reason: "Изменена длительность задачи")
        } catch { errorMessage = error.localizedDescription }
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
            scheduleAutoSync(reason: "Создан проект")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProject(_ project: Project) {
        do {
            try PlannerDataService.deleteProject(project, context: modelContext)
            scheduleAutoSync(reason: "Удален проект")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setTheme(_ theme: AppTheme, settings: AppSettings) {
        do {
            try PlannerDataService.setTheme(theme, settings: settings, context: modelContext)
            scheduleAutoSync(reason: "Изменена тема")
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
            scheduleAutoSync(reason: "Изменены настройки")
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
                startActiveSyncPolling()
            } else {
                stopActiveSyncPolling()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncServerURL(_ serverURL: String, settings: AppSettings) {
        do {
            try PlannerDataService.setSyncServerURL(serverURL, settings: settings, context: modelContext)
            startActiveSyncPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncCertificateFingerprint(_ fingerprint: String, settings: AppSettings) {
        do {
            try PlannerDataService.setSyncCertificateFingerprint(fingerprint, settings: settings, context: modelContext)
            startActiveSyncPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSyncToken(_ token: String) {
        syncToken = token
        do {
            try KeychainService.saveSyncToken(token)
            startActiveSyncPolling()
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
        scheduleAutoSync(reason: "Импортирована резервная копия")
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
        autoSyncTask = Task {
            do {
                try await Task.sleep(nanoseconds: AutoSyncService.debounceDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
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
        Task {
            await performAutoSync(reason: reason, showErrors: false)
        }
    }

    private func startActiveSyncPolling() {
        stopActiveSyncPolling()
        guard
            scenePhase == .active,
            AutoSyncService.canSync(settings: currentSettings, token: syncToken)
        else {
            return
        }
        activeSyncPollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: AutoSyncService.activePollingIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await performAutoSync(reason: "Периодическое обновление", showErrors: false)
            }
        }
    }

    private func stopActiveSyncPolling() {
        activeSyncPollingTask?.cancel()
        activeSyncPollingTask = nil
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
