import Foundation
import SwiftData

@Model
final class SyncTombstone {
    var id: UUID = UUID()
    var entityType: String = ""
    var entityID: UUID = UUID()
    var clientUpdatedAt: Date = Date.now
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: UUID,
        clientUpdatedAt: Date = Date.now,
        createdAt: Date = Date.now
    ) {
        self.id = id
        self.entityType = entityType.rawValue
        self.entityID = entityID
        self.clientUpdatedAt = clientUpdatedAt
        self.createdAt = createdAt
    }

    var syncEntityType: SyncEntityType? {
        SyncEntityType(rawValue: entityType)
    }
}
