import Foundation

struct KanbanColumn: Identifiable {
    let status: TaskStatus
    let title: String
    let tasks: [PlannerTask]

    var id: String { status.id }
}

enum KanbanService {
    static func columns(
        from tasks: [PlannerTask],
        searchText: String,
        hideEmptyColumns: Bool
    ) -> [KanbanColumn] {
        TaskStatus.allCases.compactMap { status in
            let columnTasks = KanbanService.tasks(for: status, from: tasks, searchText: searchText)

            if hideEmptyColumns, columnTasks.isEmpty {
                return nil
            }

            return KanbanColumn(
                status: status,
                title: status.displayName,
                tasks: columnTasks
            )
        }
    }

    static func tasks(
        for status: TaskStatus,
        from tasks: [PlannerTask],
        searchText: String
    ) -> [PlannerTask] {
        tasks
            .filter { !isHiddenFromKanban($0) }
            .filter { $0.status == status }
            .filter { TaskListService.matchesSearch($0, searchText: searchText) }
            .sorted(by: compareManualOrderThenCreated)
    }

    static func nextManualOrder(in tasks: [PlannerTask]) -> Double {
        (tasks.map(\.manualOrder).max() ?? 0) + 1_000
    }

    static func manualOrderBetween(previous: PlannerTask?, next: PlannerTask?) -> Double {
        switch (previous?.manualOrder, next?.manualOrder) {
        case let (previous?, next?):
            guard previous < next else {
                return next - 1_000
            }

            return previous + ((next - previous) / 2)
        case let (previous?, nil):
            return previous + 1_000
        case let (nil, next?):
            return next - 1_000
        case (nil, nil):
            return 1_000
        }
    }

    static func shouldNormalize(previous: PlannerTask?, next: PlannerTask?) -> Bool {
        guard let previous, let next else { return false }
        return !previous.manualOrder.isFinite
            || !next.manualOrder.isFinite
            || abs(next.manualOrder - previous.manualOrder) < 0.001
    }

    static func normalize(_ tasks: [PlannerTask]) {
        for (index, task) in tasks.sorted(by: compareManualOrderThenCreated).enumerated() {
            task.manualOrder = Double(index + 1) * 1_000
        }
    }

    private static func compareManualOrderThenCreated(_ lhs: PlannerTask, _ rhs: PlannerTask) -> Bool {
        if lhs.manualOrder != rhs.manualOrder {
            return lhs.manualOrder < rhs.manualOrder
        }

        return lhs.createdAt < rhs.createdAt
    }

    private static func isHiddenFromKanban(_ task: PlannerTask) -> Bool {
        !task.showInKanban
    }
}
