import Foundation
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
enum AutoSyncService {
    static let debounceDelayNanoseconds: UInt64 = 2_500_000_000
    static let activePollingIntervalNanoseconds: UInt64 = 10_000_000_000

    static func canSync(settings: AppSettings?, token: String) -> Bool {
        guard let settings, settings.syncEnabled else {
            return false
        }

        return !settings.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.syncCertificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Requests a fresh widget timeline after local data has reached the server.
    /// WidgetKit is not available in every target that shares the sync service.
    static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: PlannerWidgetShared.todayWidgetKind)
        #endif
    }

    static func syncNow(
        context: ModelContext,
        settings: AppSettings,
        token: String
    ) async throws -> SyncResult {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await SyncService.syncNow(context: context, settings: settings, token: token)
            } catch {
                lastError = error
                guard isTransient(error), attempt < 2 else { throw error }
                let base = UInt64(1 << attempt) * 1_000_000_000
                let jitter = UInt64.random(in: 0...350_000_000)
                try await Task.sleep(nanoseconds: base + jitter)
            }
        }
        throw lastError ?? SyncError.invalidResponse
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let syncError = error as? SyncError else { return true }
        switch syncError {
        case .network, .server, .invalidResponse:
            return true
        case .disabled, .invalidServerURL, .missingToken, .missingCertificateFingerprint,
             .protocolMismatch, .serverNotInitialized, .syncInProgress:
            return false
        }
    }
}
