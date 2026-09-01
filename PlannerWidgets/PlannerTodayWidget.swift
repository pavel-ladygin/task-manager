import AppIntents
import SwiftUI
import WidgetKit

struct PlannerTodayConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Подключение Planner"
    static var description = IntentDescription("Отдельный read-only токен для загрузки задач.")

    @Parameter(title: "Read-only токен")
    var widgetToken: String?

    init() {
        widgetToken = nil
    }
}

@main
struct PlannerTodayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: PlannerWidgetShared.todayWidgetKind,
            intent: PlannerTodayConfigurationIntent.self,
            provider: PlannerTodayProvider()
        ) { entry in
            PlannerTodayWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.secondarySystemBackground)
                }
        }
        .configurationDisplayName("Задачи на сегодня")
        .description("Активные и просроченные задачи Planner на текущий день.")
        .supportedFamilies([.systemMedium])
    }
}

private struct PlannerTodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlannerTodayEntry {
        PlannerTodayEntry(
            date: .now,
            tasks: [
                PlannerWidgetTask(
                    id: UUID(),
                    title: "Подготовить материалы",
                    priorityRawValue: "high",
                    scheduled: .now,
                    due: nil,
                    createdAt: .now,
                    projectTitle: "Учёба",
                    projectColorRawValue: "ocean"
                ),
                PlannerWidgetTask(
                    id: UUID(),
                    title: "Ответить на сообщения",
                    priorityRawValue: "medium",
                    scheduled: nil,
                    due: .now,
                    createdAt: .now,
                    projectTitle: nil,
                    projectColorRawValue: nil
                )
            ],
            totalCount: 2,
            state: .ready
        )
    }

    func snapshot(
        for configuration: PlannerTodayConfigurationIntent,
        in context: Context
    ) async -> PlannerTodayEntry {
        guard !context.isPreview else {
            return placeholder(in: context)
        }
        let result = await loadSnapshot(for: configuration)
        return makeEntry(for: .now, snapshot: result.snapshot, state: result.state)
    }

    func timeline(
        for configuration: PlannerTodayConfigurationIntent,
        in context: Context
    ) async -> Timeline<PlannerTodayEntry> {
        let result = await loadSnapshot(for: configuration)
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let todayStart = calendar.startOfDay(for: now)
        var entries = [
            makeEntry(for: now, snapshot: result.snapshot, state: result.state)
        ]

        for offset in 1...7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: todayStart) else {
                continue
            }
            entries.append(makeEntry(for: date, snapshot: result.snapshot, state: result.state))
        }

        let refreshInterval: TimeInterval = result.state == .needsConfiguration ? 60 * 60 : 15 * 60
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(refreshInterval)))
    }

    private func loadSnapshot(
        for configuration: PlannerTodayConfigurationIntent
    ) async -> (snapshot: PlannerWidgetSnapshot?, state: PlannerTodayState) {
        let token = (configuration.widgetToken ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return (nil, .needsConfiguration)
        }

        do {
            let snapshot = try await PlannerWidgetClient.fetch(token: token)
            PlannerWidgetClient.saveCachedSnapshot(snapshot)
            return (snapshot, .ready)
        } catch let error as PlannerWidgetClientError {
            if let cached = PlannerWidgetClient.loadCachedSnapshot() {
                return (cached, .cached)
            }
            switch error {
            case .missingToken:
                return (nil, .needsConfiguration)
            case .unauthorized:
                return (nil, .unauthorized)
            case .network:
                return (nil, .networkUnavailable)
            case .server:
                return (nil, .serverError)
            case .invalidResponse:
                return (nil, .invalidResponse)
            }
        } catch {
            if let cached = PlannerWidgetClient.loadCachedSnapshot() {
                return (cached, .cached)
            }
            return (nil, .networkUnavailable)
        }
    }

    private func makeEntry(
        for date: Date,
        snapshot: PlannerWidgetSnapshot?,
        state: PlannerTodayState
    ) -> PlannerTodayEntry {
        let tasks = PlannerWidgetTaskList.tasks(
            for: date,
            from: snapshot?.tasks ?? []
        )

        return PlannerTodayEntry(
            date: date,
            tasks: Array(tasks.prefix(4)),
            totalCount: tasks.count,
            state: state
        )
    }
}

private enum PlannerTodayState: Equatable {
    case ready
    case cached
    case needsConfiguration
    case unauthorized
    case networkUnavailable
    case serverError
    case invalidResponse

    var isUnavailable: Bool {
        switch self {
        case .unauthorized, .networkUnavailable, .serverError, .invalidResponse:
            true
        case .ready, .cached, .needsConfiguration:
            false
        }
    }

    var failureMessage: String {
        switch self {
        case .unauthorized:
            "Read-only токен отклонён сервером"
        case .networkUnavailable:
            "Сервер недоступен или ошибка TLS"
        case .serverError:
            "Сервер вернул ошибку"
        case .invalidResponse:
            "Сервер вернул некорректные данные"
        case .ready, .cached, .needsConfiguration:
            ""
        }
    }
}

private struct PlannerTodayEntry: TimelineEntry {
    let date: Date
    let tasks: [PlannerWidgetTask]
    let totalCount: Int
    let state: PlannerTodayState
}

private struct PlannerTodayWidgetView: View {
    let entry: PlannerTodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .foregroundStyle(.blue)
                Text("Сегодня")
                    .font(.headline)
                Spacer()
                if entry.state == .cached {
                    Image(systemName: "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Показаны сохранённые данные")
                }
                Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.state == .needsConfiguration {
                configurationState
            } else if entry.state.isUnavailable {
                unavailableState
            } else if entry.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .padding(14)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(entry.tasks) { task in
                HStack(spacing: 8) {
                    Circle()
                        .fill(taskColor(task))
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        if let details = taskDetails(task) {
                            Text(details)
                                .font(.caption2)
                                .foregroundStyle(isOverdue(task) ? .red : .secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }

            if entry.totalCount > entry.tasks.count {
                Text("Ещё \(entry.totalCount - entry.tasks.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.leading, 15)
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("На сегодня всё")
                    .font(.subheadline.weight(.semibold))
                Text("Активных задач нет")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private var configurationState: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Настройте виджет")
                    .font(.subheadline.weight(.semibold))
                Text("Зажмите его → «Изменить виджет» → вставьте read-only токен")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private var unavailableState: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Не удалось загрузить задачи")
                    .font(.subheadline.weight(.semibold))
                Text(entry.state.failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private func taskDetails(_ task: PlannerWidgetTask) -> String? {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: entry.date)
        let dayEnd = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: dayStart) ?? entry.date
        var parts: [String] = []

        if isOverdue(task) {
            parts.append("Просрочено")
        } else if let scheduled = task.scheduled, scheduled >= dayStart, scheduled <= dayEnd {
            parts.append(scheduled.formatted(date: .omitted, time: .shortened))
        } else if let due = task.due, due >= dayStart, due <= dayEnd {
            parts.append("Срок \(due.formatted(date: .omitted, time: .shortened))")
        }

        if let projectTitle = task.projectTitle, !projectTitle.isEmpty {
            parts.append(projectTitle)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func isOverdue(_ task: PlannerWidgetTask) -> Bool {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: entry.date)
        if let due = task.due {
            return due < start
        }
        return task.scheduled.map { $0 < start } ?? false
    }

    private func taskColor(_ task: PlannerWidgetTask) -> Color {
        switch task.priorityRawValue {
        case "urgent":
            .red
        case "high":
            .orange
        case "medium":
            .blue
        case "low":
            .green
        default:
            projectColor(task.projectColorRawValue)
        }
    }

    private func projectColor(_ rawValue: String?) -> Color {
        switch rawValue {
        case "sky":
            .cyan
        case "violet":
            .purple
        case "rose":
            .pink
        case "amber":
            .yellow
        case "emerald", "mint", "aurora":
            .green
        case "graphite":
            .gray
        case "sunset":
            .orange
        default:
            .blue
        }
    }
}
