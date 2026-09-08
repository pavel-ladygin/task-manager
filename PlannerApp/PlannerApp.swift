import CryptoKit
import Foundation
import SwiftData
import SwiftUI

@main
struct PlannerApp: App {
    @StateObject private var store = PlannerStoreBootstrap()
    #if os(iOS)
    @StateObject private var habits = HabitStore()
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = store.container {
                    #if os(macOS)
                    MacMainView()
                        .modelContainer(container)
                    #else
                    IOSMainView()
                        .modelContainer(container)
                        .environmentObject(habits)
                    #endif
                } else {
                    PlannerStoreRecoveryView(store: store)
                }
            }
        }
        #if os(macOS)
        .commands {
            PlannerCommands()
        }
        #endif
    }
}

@MainActor
final class PlannerStoreBootstrap: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestBackupURL: URL?
    @Published private(set) var diagnosticText = ""

    private let schema = Schema(versionedSchema: PlannerSchemaV2.self)
    private lazy var configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

    init() { load() }

    func retry() { load() }

    func restoreLatestBackup() {
        guard let latestBackupURL else { return }
        do {
            try PlannerStoreBackup.restore(backupDirectory: latestBackupURL, storeURL: configuration.url)
            load(createBackup: false)
        } catch {
            errorMessage = "Не удалось восстановить резервную копию: \(error.localizedDescription)"
        }
    }

    private func load(createBackup: Bool = true) {
        container = nil
        errorMessage = nil
        do {
            if createBackup {
                latestBackupURL = try PlannerStoreBackup.snapshotIfNeeded(storeURL: configuration.url)
            } else {
                latestBackupURL = PlannerStoreBackup.latestBackup()
            }
            let candidate = try ModelContainer(
                for: schema,
                migrationPlan: PlannerMigrationPlan.self,
                configurations: [configuration]
            )
            _ = try PlannerDataService.ensureAppSettings(context: candidate.mainContext)
            try PlannerStoreValidator.validate(candidate)
            container = candidate
        } catch {
            latestBackupURL = PlannerStoreBackup.latestBackup()
            errorMessage = error.localizedDescription
            diagnosticText = [
                "PlannerApp store recovery diagnostic",
                "Date: \(ISO8601DateFormatter().string(from: .now))",
                "Store: \(configuration.url.path)",
                "Backup: \(latestBackupURL?.path ?? "none")",
                "Error: \(String(reflecting: error))"
            ].joined(separator: "\n")
        }
    }
}

private struct PlannerStoreRecoveryView: View {
    @ObservedObject var store: PlannerStoreBootstrap
    @State private var showsDiagnostics = false

    var body: some View {
        ContentUnavailableView {
            Label("Хранилище не открыто", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(store.errorMessage ?? "Неизвестная ошибка миграции")
        } actions: {
            HStack {
                Button("Повторить", action: store.retry)
                if store.latestBackupURL != nil {
                    Button("Восстановить последнюю копию", action: store.restoreLatestBackup)
                }
                Button("Диагностика") { showsDiagnostics.toggle() }
            }
            if showsDiagnostics {
                ScrollView {
                    Text(store.diagnosticText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 320)
    }
}

private enum PlannerStoreValidationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): "Проверка мигрированного хранилища не пройдена: \(message)"
        }
    }
}

@MainActor
private enum PlannerStoreValidator {
    static func validate(_ container: ModelContainer) throws {
        let context = container.mainContext
        let tasks = try context.fetch(FetchDescriptor<PlannerTask>())
        let projects = try context.fetch(FetchDescriptor<Project>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let checklist = try context.fetch(FetchDescriptor<ChecklistItem>())
        let settings = try context.fetch(FetchDescriptor<AppSettings>())
        let outbox = try context.fetch(FetchDescriptor<SyncOutboxItem>())

        try requireUnique(tasks.map(\.id), name: "задач")
        try requireUnique(projects.map(\.id), name: "проектов")
        try requireUnique(tags.map(\.id), name: "тегов")
        try requireUnique(checklist.map(\.id), name: "пунктов чеклиста")
        try requireUnique(outbox.map(\.mutationID), name: "sync-мутаций")
        guard settings.count == 1 else {
            throw PlannerStoreValidationError.invalid("ожидался один объект настроек, найдено \(settings.count)")
        }

        let projectIDs = Set(projects.map(\.id))
        let tagIDs = Set(tags.map(\.id))
        let checklistIDs = Set(checklist.map(\.id))
        var seriesKeys = Set<String>()
        for task in tasks {
            if let projectID = task.project?.id, !projectIDs.contains(projectID) {
                throw PlannerStoreValidationError.invalid("задача \(task.id) ссылается на отсутствующий проект")
            }
            if task.tags.contains(where: { !tagIDs.contains($0.id) })
                || task.checklistItems.contains(where: { !checklistIDs.contains($0.id) }) {
                throw PlannerStoreValidationError.invalid("нарушены связи задачи \(task.id)")
            }
            if task.recurrence != .none {
                guard let seriesID = task.recurrenceSeriesID,
                      task.recurrenceAnchorDate != nil,
                      task.scheduled != nil || task.due != nil,
                      task.recurrenceSequence >= 0 else {
                    throw PlannerStoreValidationError.invalid("некорректная серия повторения у задачи \(task.id)")
                }
                let key = "\(seriesID.uuidString):\(task.recurrenceSequence)"
                guard seriesKeys.insert(key).inserted else {
                    throw PlannerStoreValidationError.invalid("дубликат экземпляра серии \(key)")
                }
            }
        }
    }

    private static func requireUnique<T: Hashable>(_ values: [T], name: String) throws {
        guard Set(values).count == values.count else {
            throw PlannerStoreValidationError.invalid("обнаружены повторяющиеся ID \(name)")
        }
    }
}

private enum PlannerStoreBackup {
    private static var backupRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PlannerApp/MigrationBackups", isDirectory: true)
    }

    static func snapshotIfNeeded(storeURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path), let backupRoot else { return latestBackup() }
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeDate = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let temporary = backupRoot.appendingPathComponent(".\(safeDate)-\(UUID().uuidString)", isDirectory: true)
        let destination = backupRoot.appendingPathComponent(safeDate, isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        var manifest: [String: String] = [:]
        for source in storeFamily(storeURL) where fileManager.fileExists(atPath: source.path) {
            let target = temporary.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: target)
            let data = try Data(contentsOf: target)
            manifest[source.lastPathComponent] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
        try fileManager.moveItem(at: temporary, to: destination)
        try prune(keeping: 3)
        return destination
    }

    static func latestBackup() -> URL? {
        guard let backupRoot else { return nil }
        return try? FileManager.default.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    static func restore(backupDirectory: URL, storeURL: URL) throws {
        let fileManager = FileManager.default
        let manifestURL = backupDirectory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
        guard !manifest.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        for (name, expectedHash) in manifest {
            let source = backupDirectory.appendingPathComponent(name)
            let data = try Data(contentsOf: source)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == expectedHash else { throw CocoaError(.fileReadCorruptFile) }
        }

        for target in storeFamily(storeURL) where fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        for name in manifest.keys {
            try fileManager.copyItem(
                at: backupDirectory.appendingPathComponent(name),
                to: storeURL.deletingLastPathComponent().appendingPathComponent(name)
            )
        }
    }

    private static func storeFamily(_ storeURL: URL) -> [URL] {
        [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
    }

    private static func prune(keeping count: Int) throws {
        guard let backupRoot else { return }
        let directories = try FileManager.default.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for directory in directories.dropFirst(count) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

#if os(macOS)
struct PlannerCommands: Commands {
    @FocusedValue(\.plannerCommandActions) private var plannerCommandActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая задача") {
                plannerCommandActions?.focusQuickAdd()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(plannerCommandActions == nil)
        }

        CommandMenu("Планировщик") {
            Button("Поиск") {
                plannerCommandActions?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(plannerCommandActions == nil)

            Button("Показать/скрыть инспектор") {
                plannerCommandActions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(plannerCommandActions == nil)

            Divider()

            Button("Отметить выполненной") {
                plannerCommandActions?.markSelectedTaskDone()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(plannerCommandActions?.canMarkSelectedTaskDone != true)
        }
    }
}
#endif
