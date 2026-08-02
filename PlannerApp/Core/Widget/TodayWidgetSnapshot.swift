import Foundation

enum PlannerWidgetShared {
    static let todayWidgetKind = "PlannerTodayWidget"
    static let serverURL = URL(string: "https://91.108.189.121:8443")!
    static let certificateFingerprint = "4C:47:F0:8A:77:02:1E:48:EB:C5:D6:C1:56:D9:97:CB:F1:B8:33:3C:B4:58:72:02:1A:CF:4C:93:B2:29:43:03"
}

struct PlannerWidgetSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let tasks: [PlannerWidgetTask]

    init(generatedAt: Date = .now, tasks: [PlannerWidgetTask]) {
        schemaVersion = 2
        self.generatedAt = generatedAt
        self.tasks = tasks
    }
}

struct PlannerWidgetTask: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let priorityRawValue: String
    let scheduled: Date?
    let due: Date?
    let createdAt: Date
    let projectTitle: String?
    let projectColorRawValue: String?

    var priorityRank: Int {
        switch priorityRawValue {
        case "urgent":
            4
        case "high":
            3
        case "medium":
            2
        case "low":
            1
        default:
            0
        }
    }
}

enum PlannerWidgetTaskList {
    static func tasks(
        for date: Date,
        from tasks: [PlannerWidgetTask],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PlannerWidgetTask] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date

        return tasks
            .filter { task in
                (task.scheduled.map { $0 <= end } ?? false)
                    || (task.due.map { $0 <= end } ?? false)
            }
            .sorted(by: compareTasks)
    }

    private static func compareTasks(_ lhs: PlannerWidgetTask, _ rhs: PlannerWidgetTask) -> Bool {
        if lhs.priorityRank != rhs.priorityRank {
            return lhs.priorityRank > rhs.priorityRank
        }

        if let comparison = compareOptionalDates(lhs.due, rhs.due) {
            return comparison
        }

        if let comparison = compareOptionalDates(lhs.scheduled, rhs.scheduled) {
            return comparison
        }

        return lhs.createdAt < rhs.createdAt
    }

    private static func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            lhs < rhs
        case (_?, nil):
            true
        case (nil, _?):
            false
        default:
            nil
        }
    }
}
