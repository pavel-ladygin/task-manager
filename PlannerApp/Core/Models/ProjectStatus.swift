import Foundation

enum ProjectStatus: String, CaseIterable, Codable, Hashable, Identifiable {
    case active
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active:
            "Активный"
        case .archived:
            "Архив"
        }
    }
}
