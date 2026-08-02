import Foundation

enum SyncEntityType: String, Codable, CaseIterable {
    case task, project, tag, settings
}

enum SyncMutationOperation: String, Codable {
    case upsert, delete
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct SyncMutationDTO: Codable {
    var mutationID: String
    var entityType: String
    var entityID: String
    var operation: String
    var payload: JSONValue?
    var baseRevision: Int64
    var createdAt: Date
}

struct SyncMutationRequest: Codable {
    var deviceID: String
    var mutations: [SyncMutationDTO]
}

struct SyncServerChangeDTO: Codable {
    var revision: Int64
    var entityType: String
    var entityID: String
    var operation: String
    var payload: JSONValue?
    var sourceDeviceID: String
    var serverUpdatedAt: Date
}

struct SyncMutationResultDTO: Codable {
    var mutationID: String
    var status: String
    var serverRevision: Int64
    var current: SyncServerChangeDTO?
}

struct SyncMutationResponse: Codable {
    var serverCursor: Int64
    var results: [SyncMutationResultDTO]
}

struct SyncChangesResponse: Codable {
    var serverCursor: Int64
    var hasMore: Bool
    var changes: [SyncServerChangeDTO]
}

struct SyncStatusResponse: Codable {
    var serverCursor: Int64
    var serverTime: Date
    var protocolVersion: Int
    var isEmpty: Bool
}

struct SyncResult {
    let pushed: Int
    let ignored: Int
    let pulled: Int
    let cursor: Int64
}
