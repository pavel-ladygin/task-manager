import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID = UUID()
    var title: String = ""
    var statusRawValue: String = ProjectStatus.active.rawValue
    var deadline: Date?
    var notes: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        title: String,
        status: ProjectStatus = .active,
        deadline: Date? = nil,
        notes: String = "",
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now
    ) {
        self.id = id
        self.title = title
        self.statusRawValue = status.rawValue
        self.deadline = deadline
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRawValue) ?? .active }
        set { statusRawValue = newValue.rawValue }
    }
}
