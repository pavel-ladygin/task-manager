import Foundation
import SwiftUI

enum HabitColor: String, CaseIterable, Codable, Identifiable {
    case ocean, mint, violet, amber, rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ocean: "Океан"
        case .mint: "Мята"
        case .violet: "Фиолетовый"
        case .amber: "Янтарь"
        case .rose: "Розовый"
        }
    }

    var color: Color {
        switch self {
        case .ocean: PlannerTheme.accent
        case .mint: Color(red: 0.18, green: 0.85, blue: 0.76)
        case .violet: Color(red: 0.62, green: 0.42, blue: 1.0)
        case .amber: PlannerTheme.warning
        case .rose: Color(red: 1.0, green: 0.33, blue: 0.60)
        }
    }
}

struct Habit: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var icon: String
    var color: HabitColor
    var completionDayKeys: Set<String> = []
    var createdAt: Date = .now
    var updatedAt: Date = .now

    func isCompleted(on date: Date = .now, calendar: Calendar = .current) -> Bool {
        completionDayKeys.contains(Self.dayKey(for: date, calendar: calendar))
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct HabitMilestone: Identifiable, Equatable {
    let days: Int
    let title: String
    let symbol: String

    var id: Int { days }

    static let all: [HabitMilestone] = [
        HabitMilestone(days: 7, title: "Первая неделя", symbol: "flame.fill"),
        HabitMilestone(days: 30, title: "Месяц потока", symbol: "medal.fill"),
        HabitMilestone(days: 60, title: "Два месяца", symbol: "sparkles"),
        HabitMilestone(days: 180, title: "Полгода силы", symbol: "trophy.fill"),
        HabitMilestone(days: 365, title: "Год в ритме", symbol: "crown.fill")
    ]
}

enum HabitProgressService {
    static func currentStreak(for habit: Habit, date: Date = .now, calendar: Calendar = .current) -> Int {
        var cursor = calendar.startOfDay(for: date)
        if !habit.isCompleted(on: cursor, calendar: calendar) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  habit.isCompleted(on: yesterday, calendar: calendar) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while habit.isCompleted(on: cursor, calendar: calendar) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }
        return streak
    }
}

@MainActor
final class HabitStore: ObservableObject {
    @Published private(set) var habits: [Habit] = []

    private static let defaultsKey = "planner.habits.v1"
    private static let didChangeNotification = Notification.Name("planner.habits.didChange")
    private var persistenceObserver: NSObjectProtocol?

    init() {
        load()
        persistenceObserver = NotificationCenter.default.addObserver(
            forName: Self.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.load() }
        }
    }

    deinit {
        if let persistenceObserver {
            NotificationCenter.default.removeObserver(persistenceObserver)
        }
    }

    var completedTodayCount: Int {
        habits.filter { $0.isCompleted() }.count
    }

    var nextDailyMilestone: HabitMilestone? {
        HabitMilestone.all.first { completedTodayCount < $0.days }
    }

    func toggle(_ habit: Habit, on date: Date = .now, calendar: Calendar = .current) -> HabitMilestone? {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else { return nil }
        let key = Habit.dayKey(for: date, calendar: calendar)
        let wasCompleted = habits[index].completionDayKeys.contains(key)
        if wasCompleted {
            habits[index].completionDayKeys.remove(key)
        } else {
            habits[index].completionDayKeys.insert(key)
        }
        habits[index].updatedAt = .now
        persist()

        guard !wasCompleted else { return nil }
        let streak = currentStreak(for: habits[index], date: date, calendar: calendar)
        return HabitMilestone.all.first { $0.days == streak }
    }

    func create(title: String, icon: String, color: HabitColor) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        habits.append(Habit(title: normalized, icon: icon, color: color))
        persist()
    }

    func update(_ habit: Habit, title: String, icon: String, color: HabitColor) {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        habits[index].title = normalized
        habits[index].icon = icon
        habits[index].color = color
        habits[index].updatedAt = .now
        persist()
    }

    func delete(_ habit: Habit) {
        habits.removeAll { $0.id == habit.id }
        persist()
    }

    func currentStreak(for habit: Habit, date: Date = .now, calendar: Calendar = .current) -> Int {
        HabitProgressService.currentStreak(for: habit, date: date, calendar: calendar)
    }

    func isCompleted(_ habit: Habit, on date: Date, calendar: Calendar = .current) -> Bool {
        habit.isCompleted(on: date, calendar: calendar)
    }

    private func load() {
        habits = Self.persistedHabits()
    }

    private func persist() {
        Self.replacePersistedHabits(habits)
    }

    static func persistedHabits() -> [Habit] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Habit].self, from: data) else { return [] }
        return decoded.sorted { $0.createdAt < $1.createdAt }
    }

    static func replacePersistedHabits(_ habits: [Habit]) {
        guard let data = try? JSONEncoder().encode(habits) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
