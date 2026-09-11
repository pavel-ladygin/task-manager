import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct IOSSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SyncConflict.createdAt, order: .reverse) private var syncConflicts: [SyncConflict]
    let settings: AppSettings?
    let setTheme: (AppTheme, AppSettings) -> Void
    let setHideEmptyKanbanColumns: (Bool, AppSettings) -> Void
    let setDefaultReminderLeadMinutes: (Int, AppSettings) -> Void
    @Binding var syncToken: String
    let syncStatus: String
    let setSyncEnabled: (Bool, AppSettings) -> Void
    let setSyncServerURL: (String, AppSettings) -> Void
    let setSyncCertificateFingerprint: (String, AppSettings) -> Void
    let setSyncToken: (String) -> Void
    let testSyncConnection: (AppSettings) -> Void
    let bootstrapSync: (AppSettings) -> Void
    let syncNow: (AppSettings) -> Void
    let reloadCalendarEvents: (AppSettings) -> Void
    let completedTaskCount: Int
    let clearCompletedTasks: () throws -> Int
    let importBackup: (Data) throws -> Void
    let exportBackup: () throws -> Data

    @State private var notificationStatus = "Неизвестно"
    @State private var backupDocument = JSONBackupDocument()
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var isClearCompletedConfirmationPresented = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var serverURLDraft = ""
    @State private var fingerprintDraft = ""
    @State private var tokenDraft = ""

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

                Button {
                    requestNotifications()
                } label: {
                    Label("Запросить разрешение", systemImage: "bell.badge")
                }
            }

            Section("Резервная копия") {
                Button {
                    exportJSON()
                } label: {
                    Label("Экспорт JSON", systemImage: "square.and.arrow.up")
                }

                Button {
                    isImportingBackup = true
                } label: {
                    Label("Импорт JSON", systemImage: "square.and.arrow.down")
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
                        text: $serverURLDraft
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    SecureField(
                        "API token",
                        text: $tokenDraft
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "SHA256 fingerprint",
                        text: $fingerprintDraft
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    LabeledContent("Device ID", value: settings.syncDeviceID)
                    LabeledContent("Cursor", value: "\(settings.syncLastCursor)")
                    LabeledContent("Последняя синхронизация", value: settings.syncLastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Нет")
                    LabeledContent("Статус", value: syncStatus)

                    HStack {
                        Button("Отмена") { loadConnectionDrafts(settings) }
                            .disabled(!connectionIsDirty(settings))
                        Button("Применить подключение") {
                            setSyncServerURL(serverURLDraft, settings)
                            setSyncCertificateFingerprint(fingerprintDraft, settings)
                            setSyncToken(tokenDraft)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connectionIsDirty(settings))
                    }

                    Button("Test connection") {
                        testSyncConnection(settings)
                    }

                    Button("Инициализировать пустой сервер") {
                        bootstrapSync(settings)
                    }

                    Button("Sync now") {
                        syncNow(settings)
                    }

                    Button("Повторно загрузить календарь") {
                        reloadCalendarEvents(settings)
                    }
                } else {
                    LabeledContent("Синхронизация", value: "Загрузка")
                }
            }

            if !unresolvedConflicts.isEmpty {
                Section("Конфликты синхронизации") {
                    ForEach(unresolvedConflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(conflict.entityType): \(conflict.entityID)").font(.caption).lineLimit(1)
                            HStack {
                                Button("Сервер") { resolve(conflict, .keepServer) }
                                Button("Локально") { resolve(conflict, .keepLocal) }
                                if conflict.entityType == SyncEntityType.task.rawValue || conflict.entityType == SyncEntityType.project.rawValue {
                                    Button("Копия") { resolve(conflict, .duplicateLocal) }
                                }
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .navigationTitle("Настройки")
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "planner-backup.json"
        ) { result in
            switch result {
            case .success:
                statusMessage = "JSON-резервная копия экспортирована."
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importJSON(result)
        }
        .confirmationDialog(
            "Очистить выполненные задачи?",
            isPresented: $isClearCompletedConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить \(completedTaskCount)", role: .destructive) {
                clearCompleted()
            }

            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены задачи со статусом «Выполнено». Удаление попадет в синхронизацию.")
        }
        .alert("Планировщик", isPresented: statusBinding) {
            Button("ОК", role: .cancel) {
                statusMessage = nil
            }
        } message: {
            Text(statusMessage ?? "")
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            notificationStatus = await NotificationService.authorizationStatusDescription()
            if let settings { loadConnectionDrafts(settings) }
        }
        .onChange(of: settings?.id) { _, _ in if let settings { loadConnectionDrafts(settings) } }
    }

    private var statusBinding: Binding<Bool> {
        Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )
    }

    private var unresolvedConflicts: [SyncConflict] { syncConflicts.filter { $0.resolvedAt == nil } }

    private func resolve(_ conflict: SyncConflict, _ resolution: SyncConflictResolution) {
        Task { @MainActor in
            do {
                try SyncService.resolve(conflict, resolution: resolution, context: modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadConnectionDrafts(_ settings: AppSettings) {
        serverURLDraft = settings.syncServerURL
        fingerprintDraft = settings.syncCertificateFingerprint
        tokenDraft = syncToken
    }

    private func connectionIsDirty(_ settings: AppSettings) -> Bool {
        serverURLDraft != settings.syncServerURL
            || fingerprintDraft != settings.syncCertificateFingerprint
            || tokenDraft != syncToken
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func requestNotifications() {
        Task {
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

    private func exportJSON() {
        do {
            backupDocument = JSONBackupDocument(data: try exportBackup())
            isExportingBackup = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importJSON(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                return
            }

            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try importBackup(Data(contentsOf: url))
            statusMessage = "JSON-резервная копия импортирована."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCompleted() {
        do {
            let deletedCount = try clearCompletedTasks()
            statusMessage = deletedCount == 0
                ? "Выполненных задач для очистки нет."
                : "Удалено выполненных задач: \(deletedCount)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
