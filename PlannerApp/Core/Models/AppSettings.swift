import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: UUID = UUID()
    var theme: String = AppTheme.system.rawValue
    var hideEmptyKanbanColumns: Bool = false
    var defaultReminderLeadMinutes: Int = 15
    var syncEnabled: Bool = false
    var syncServerURL: String = "https://91.108.189.121:8443"
    var syncCertificateFingerprint: String = ""
    var syncDeviceID: String = UUID().uuidString
    var syncLastCursor: Int64 = 0
    var syncLastSyncAt: Date?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        theme: String = "system",
        hideEmptyKanbanColumns: Bool = false,
        defaultReminderLeadMinutes: Int = 15,
        syncEnabled: Bool = false,
        syncServerURL: String = "https://91.108.189.121:8443",
        syncCertificateFingerprint: String = "",
        syncDeviceID: String = UUID().uuidString,
        syncLastCursor: Int64 = 0,
        syncLastSyncAt: Date? = nil,
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now
    ) {
        self.id = id
        self.theme = theme
        self.hideEmptyKanbanColumns = hideEmptyKanbanColumns
        self.defaultReminderLeadMinutes = defaultReminderLeadMinutes
        self.syncEnabled = syncEnabled
        self.syncServerURL = syncServerURL
        self.syncCertificateFingerprint = syncCertificateFingerprint
        self.syncDeviceID = syncDeviceID
        self.syncLastCursor = syncLastCursor
        self.syncLastSyncAt = syncLastSyncAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var appTheme: AppTheme {
        get { AppTheme(rawValue: theme) ?? .system }
        set { theme = newValue.rawValue }
    }
}
