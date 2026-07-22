import Foundation
import SwiftData

@Model
final class Tag {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date.now
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}
