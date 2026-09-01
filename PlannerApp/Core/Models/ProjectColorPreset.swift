import Foundation

enum ProjectColorPreset: String, CaseIterable, Identifiable {
    case ocean
    case sky
    case violet
    case rose
    case amber
    case emerald
    case mint
    case graphite
    case sunset
    case aurora

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ocean:
            "Океан"
        case .sky:
            "Небо"
        case .violet:
            "Фиолетовый"
        case .rose:
            "Роза"
        case .amber:
            "Янтарь"
        case .emerald:
            "Изумруд"
        case .mint:
            "Мята"
        case .graphite:
            "Графит"
        case .sunset:
            "Закат"
        case .aurora:
            "Северное сияние"
        }
    }
}
