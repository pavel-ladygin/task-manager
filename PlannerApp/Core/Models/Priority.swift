import Foundation

enum Priority: String, CaseIterable, Codable, Hashable, Identifiable {
    case none
    case low
    case medium
    case high
    case urgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "Без приоритета"
        case .low:
            "Низкий"
        case .medium:
            "Средний"
        case .high:
            "Высокий"
        case .urgent:
            "Срочный"
        }
    }

    var sortOrder: Int {
        switch self {
        case .urgent:
            4
        case .high:
            3
        case .medium:
            2
        case .low:
            1
        case .none:
            0
        }
    }
}
