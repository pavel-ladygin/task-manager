import Foundation
import SwiftData

@Model
final class ChecklistItem {
    var id: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var order: Int = 0

    init(
        id: UUID = UUID(),
        title: String,
        isDone: Bool = false,
        order: Int = 0
    ) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.order = order
    }
}
