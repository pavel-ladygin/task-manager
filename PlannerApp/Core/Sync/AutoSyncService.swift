import Foundation
import SwiftData

@MainActor
enum AutoSyncService {
    static let debounceDelayNanoseconds: UInt64 = 2_500_000_000

    static func canSync(settings: AppSettings?, token: String) -> Bool {
        guard let settings, settings.syncEnabled else {
            return false
        }

        return !settings.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.syncCertificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func syncNow(
        context: ModelContext,
        settings: AppSettings,
        token: String
    ) async throws -> SyncResult {
        try await SyncService.syncNow(context: context, settings: settings, token: token)
    }
}
