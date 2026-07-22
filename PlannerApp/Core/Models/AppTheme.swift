import Foundation

enum AppTheme: String, CaseIterable, Codable, Hashable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            "Системная"
        case .light:
            "Светлая"
        case .dark:
            "Темная"
        }
    }
}
