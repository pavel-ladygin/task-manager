import CryptoKit
import Foundation

final class SyncClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, certificateFingerprint: String) {
        self.baseURL = baseURL
        self.token = token
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedCertificateDelegate(expectedFingerprint: certificateFingerprint),
            delegateQueue: nil
        )
    }

    func status() async throws -> SyncStatusResponse {
        try await request(path: "/v1/sync/status", method: "GET", body: Optional<Data>.none)
    }

    func push(_ payload: SyncPushRequest) async throws -> SyncPushResponse {
        try await request(path: "/v1/sync/push", method: "POST", body: encode(payload))
    }

    func bootstrap(_ payload: SyncPushRequest) async throws -> SyncPushResponse {
        try await request(path: "/v1/sync/bootstrap", method: "POST", body: encode(payload))
    }

    func pull(cursor: Int64) async throws -> SyncPullResponse {
        try await request(path: "/v1/sync/pull?cursor=\(cursor)", method: "GET", body: Optional<Data>.none)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SyncError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SyncError.network(error.localizedDescription)
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SyncError.server(message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

final class PinnedCertificateDelegate: NSObject, URLSessionDelegate {
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
            let certificate = SecTrustGetCertificateAtIndex(trust, 0)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certificateData = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: certificateData)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()

        if Self.normalized(fingerprint) == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func normalized(_ fingerprint: String) -> String {
        fingerprint
            .lowercased()
            .filter { $0.isHexDigit }
    }
}

enum SyncError: LocalizedError {
    case disabled
    case invalidServerURL
    case missingToken
    case missingCertificateFingerprint
    case invalidResponse
    case network(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Синхронизация отключена."
        case .invalidServerURL:
            "Некорректный URL сервера синхронизации."
        case .missingToken:
            "Укажите API token для синхронизации."
        case .missingCertificateFingerprint:
            "Укажите SHA256 fingerprint сертификата сервера."
        case .invalidResponse:
            "Сервер синхронизации вернул некорректный ответ."
        case .network(let message):
            "Ошибка подключения к серверу синхронизации: \(message)"
        case .server(let message):
            "Ошибка сервера синхронизации: \(message)"
        }
    }
}
