import CryptoKit
import Foundation
import Security

struct PlannerWidgetServerSnapshot: Decodable {
    let serverCursor: Int64
    let generatedAt: Date
    let tasks: [Task]
    let projects: [Project]

    struct Task: Decodable {
        let id: UUID
        let title: String
        let status: String
        let priority: String
        let scheduled: Date?
        let due: Date?
        let createdAt: Date
        let projectID: UUID?
    }

    struct Project: Decodable {
        let id: UUID
        let title: String
        let color: String?
    }

    func widgetSnapshot() -> PlannerWidgetSnapshot {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let activeTasks = tasks
            .filter { $0.status != "done" && $0.status != "cancelled" }
            .map { task in
                let project = task.projectID.flatMap { projectsByID[$0] }
                return PlannerWidgetTask(
                    id: task.id,
                    title: task.title,
                    priorityRawValue: task.priority,
                    scheduled: task.scheduled,
                    due: task.due,
                    createdAt: task.createdAt,
                    projectTitle: project?.title,
                    projectColorRawValue: project?.color
                )
            }
        return PlannerWidgetSnapshot(generatedAt: generatedAt, tasks: activeTasks)
    }
}

enum PlannerWidgetClient {
    static func fetch(token: String) async throws -> PlannerWidgetSnapshot {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw PlannerWidgetClientError.missingToken
        }

        let url = PlannerWidgetShared.serverURL.appendingPathComponent("v2/widget/snapshot")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: PlannerWidgetPinnedCertificateDelegate(
                expectedFingerprint: PlannerWidgetShared.certificateFingerprint
            ),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlannerWidgetClientError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerWidgetClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw PlannerWidgetClientError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PlannerWidgetClientError.server
        }

        do {
            return try decoder.decode(PlannerWidgetServerSnapshot.self, from: data).widgetSnapshot()
        } catch {
            throw PlannerWidgetClientError.invalidResponse
        }
    }

    static func loadCachedSnapshot() -> PlannerWidgetSnapshot? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PlannerWidgetSnapshot.self, from: data)
    }

    static func saveCachedSnapshot(_ snapshot: PlannerWidgetSnapshot) {
        guard let cacheURL,
              let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static var cacheURL: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("planner-today-widget-v2.json", isDirectory: false)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = RFC3339.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid RFC3339 date"
                )
            }
            return date
        }
        return decoder
    }
}

private enum RFC3339 {
    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

private final class PlannerWidgetPinnedCertificateDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = Self.normalized(expectedFingerprint)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            !expectedFingerprint.isEmpty,
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let certificate = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        let actualFingerprint = digest.map { String(format: "%02x", $0) }.joined()
        if Self.normalized(actualFingerprint) == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func normalized(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter(\.isHexDigit)
    }
}

enum PlannerWidgetClientError: Error {
    case missingToken
    case unauthorized
    case network
    case server
    case invalidResponse
}
