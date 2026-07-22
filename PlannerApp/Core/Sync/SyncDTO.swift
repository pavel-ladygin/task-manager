import Foundation

enum SyncEntityType: String, Codable, CaseIterable {
    case task
    case project
    case tag
    case settings
}

struct SyncItemDTO: Codable {
    var entityType: String
    var entityID: String
    var payloadJSON: String?
    var clientUpdatedAt: Date
    var serverUpdatedAt: String?
    var deletedAt: Date?
    var version: Int64
    var sourceDeviceID: String
}

struct SyncPushRequest: Codable {
    var deviceID: String
    var items: [SyncItemDTO]
}

struct SyncPushResponse: Codable {
    var serverCursor: Int64
    var accepted: Int
    var ignored: Int
}

struct SyncPullResponse: Codable {
    var serverCursor: Int64
    var serverTime: String
    var items: [SyncItemDTO]
}

struct SyncStatusResponse: Codable {
    var serverCursor: Int64
    var serverTime: String
}

struct SyncResult {
    let pushed: Int
    let ignored: Int
    let pulled: Int
    let cursor: Int64
}
