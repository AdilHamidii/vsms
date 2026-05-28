import Foundation

/// Thin wrapper over URLSession aimed at Supabase's REST + Auth API.
/// Holds the access token. Refreshes when it sees a 401 and retries once.
@Observable
final class APIClient {
    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String
    private weak var sessionStore: Session?

    init(session: URLSession = .shared,
         baseURL: URL = Secrets.supabaseURL,
         anonKey: String = Secrets.supabaseAnonKey) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
    }

    func attach(_ store: Session) { self.sessionStore = store }

    enum Method: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }

    struct Empty: Codable {}

    func request<Response: Decodable>(
        _ method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        authenticated: Bool = true,
        as: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await rawRequest(method, path: path, query: query, body: body, authenticated: authenticated)
        if Response.self == Empty.self {
            return Empty() as! Response
        }
        do {
            return try JSONDecoder.relay.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    @discardableResult
    func rawRequest(
        _ method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        authenticated: Bool = true,
        allowRefresh: Bool = true
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var req = URLRequest(url: components.url!)
        req.httpMethod = method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if authenticated {
            guard let token = sessionStore?.accessToken else {
                throw APIError.notAuthenticated
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = try JSONEncoder.relay.encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }

        if http.statusCode == 401, authenticated, allowRefresh, let store = sessionStore {
            let refreshed = await store.refresh()
            if refreshed {
                return try await rawRequest(method, path: path, query: query, body: body,
                                             authenticated: authenticated, allowRefresh: false)
            }
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw APIError.http(status: http.statusCode, body: body)
        }
        return data
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension JSONDecoder {
    static let relay: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let relay: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
