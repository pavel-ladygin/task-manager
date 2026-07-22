import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct IOSSettingsView: View {
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
    let importBackup: (Data) throws -> Void
    let exportBackup: () throws -> Data

    @State private var notificationStatus = "Неизвестно"
    @State private var backupDocument = JSONBackupDocument()
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

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
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    SecureField(
                        "API token",
                        text: Binding(
                            get: { syncToken },
                            set: { setSyncToken($0) }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "SHA256 fingerprint",
                        text: Binding(
                            get: { settings.syncCertificateFingerprint },
                            set: { setSyncCertificateFingerprint($0, settings) }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    LabeledContent("Device ID", value: settings.syncDeviceID)
                    LabeledContent("Cursor", value: "\(settings.syncLastCursor)")
                    LabeledContent("Последняя синхронизация", value: settings.syncLastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Нет")
                    LabeledContent("Статус", value: syncStatus)

                    Button("Test connection") {
                        testSyncConnection(settings)
                    }

                    Button("Bootstrap server") {
                        bootstrapSync(settings)
                    }

                    Button("Sync now") {
                        syncNow(settings)
                    }
                } else {
                    LabeledContent("Синхронизация", value: "Загрузка")
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
        }
    }

    private var statusBinding: Binding<Bool> {
        Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )
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
