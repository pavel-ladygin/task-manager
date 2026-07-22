import SwiftData

enum PlannerSchema {
    static let models: [any PersistentModel.Type] = [
        PlannerTask.self,
        Project.self,
        Tag.self,
        ChecklistItem.self,
        AppSettings.self,
        SyncTombstone.self
    ]
}
