import Foundation

enum TaskStatus: String, CaseIterable, Codable, Hashable, Identifiable {
    case inbox
    case planned
    case inProgress = "in-progress"
    case done
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inbox:
            "Входящие"
        case .planned:
            "Запланировано"
        case .inProgress:
            "В работе"
        case .done:
            "Выполнено"
        case .cancelled:
            "Отменено"
        }
    }
}
