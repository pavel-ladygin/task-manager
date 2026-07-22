import Foundation

enum TaskRecurrence: String, CaseIterable, Codable, Hashable, Identifiable {
    case none
    case weekly
    case biweekly
    case monthly
    case yearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "Без повтора"
        case .weekly:
            "Каждую неделю"
        case .biweekly:
            "Через неделю"
        case .monthly:
            "Раз в месяц"
        case .yearly:
            "Раз в год"
        }
    }
}
