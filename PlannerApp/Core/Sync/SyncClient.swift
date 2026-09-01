import CryptoKit
import Foundation

final class SyncClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, certificateFingerprint: String) {
        self.baseURL = baseURL
        self.token = token
        session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedCertificateDelegate(expectedFingerprint: certificateFingerprint),
            delegateQueue: nil
        )
    }

    func status() async throws -> SyncStatusResponse {
        try await request(path: "/v2/sync/status", method: "GET", body: Optional<Data>.none)
    }

    func initialize(_ payload: SyncMutationRequest) async throws -> SyncMutationResponse {
        try await request(path: "/v2/sync/initialize", method: "POST", body: encode(payload))
    }

    func mutations(_ payload: SyncMutationRequest) async throws -> SyncMutationResponse {
        try await request(path: "/v2/sync/mutations", method: "POST", body: encode(payload))
    }

    func changes(after cursor: Int64, limit: Int = 200) async throws -> SyncChangesResponse {
        try await request(path: "/v2/sync/changes?after=\(cursor)&limit=\(limit)", method: "GET", body: Optional<Data>.none)
    }

    private func request<Response: Decodable>(path: String, method: String, body: Data?) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw SyncError.invalidServerURL }
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
        do { (data, response) = try await session.data(for: request) }
        catch { throw SyncError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SyncError.server(message)
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try Self.encoder.encode(value) }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RFC3339.string(from: date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = RFC3339.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC3339 date")
            }
            return date
        }
        return decoder
    }
}

private enum RFC3339 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

final class PinnedCertificateDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String
    init(expectedFingerprint: String) { self.expectedFingerprint = Self.normalized(expectedFingerprint) }

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
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        if Self.normalized(fingerprint) == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func normalized(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter(\.isHexDigit)
    }
}

enum SyncError: LocalizedError {
    case disabled, invalidServerURL, missingToken, missingCertificateFingerprint, invalidResponse, protocolMismatch
    case serverNotInitialized, syncInProgress
    case network(String), server(String)

    var errorDescription: String? {
        switch self {
        case .disabled: "Синхронизация отключена."
        case .invalidServerURL: "Укажите корректный HTTPS URL сервера синхронизации."
        case .missingToken: "Укажите API token для синхронизации."
        case .missingCertificateFingerprint: "Укажите SHA256 fingerprint сертификата сервера."
        case .invalidResponse: "Сервер синхронизации вернул некорректный ответ."
        case .protocolMismatch: "Сервер не поддерживает протокол синхронизации v2."
        case .serverNotInitialized: "Сервер пуст. Сначала выполните «Инициализировать пустой сервер»."
        case .syncInProgress: "Другой сеанс синхронизации ещё выполняется. Повторите через несколько секунд."
        case .network(let message): "Ошибка подключения к серверу синхронизации: \(message)"
        case .server(let message): "Ошибка сервера синхронизации: \(message)"
        }
    }
}
