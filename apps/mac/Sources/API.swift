import Foundation

// The disk-web JSON API (crates/disk-web/src/main.rs). The app is a client of the local server
// only; the server proxies other machines under /api/h/<id>/ and holds their tokens.

struct HostDTO: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let local: Bool
}

struct SpaceDTO: Codable, Hashable {
    let total: Int64
    let free: Int64
    let available: Int64
}

struct TotalsDTO: Codable, Hashable {
    let bytes: Int64
    let files: Int64
    let dirs: Int64
}

struct ProgressDTO: Codable, Hashable {
    let files: Int64?
    let bytes: Int64?
}

struct StatusDTO: Codable, Hashable {
    let root: String
    let scanning: Bool
    let progress: ProgressDTO?
    let noSnapshot: Bool?
    let scanError: String?
    let scannedAt: Int64
    let scanSeconds: Double?
    let unreadable: Int64?
    let fullDiskAccess: Bool?
    let excluded: [String]?
    let tree: TotalsDTO?
    let space: SpaceDTO?
    let trash: String
    let trashAvailable: Bool
    let removing: Bool
}

struct RestDTO: Codable, Hashable {
    let bytes: Int64
    let count: Int64
}

struct TrailStep: Codable, Hashable {
    let name: String
    let crumbs: [Int]
}

struct NodeDTO: Codable, Hashable {
    let name: String
    let crumbs: [Int]
    let dir: Bool
    let link: Bool
    let bytes: Int64
    let files: Int64
    let dirs: Int64
    let modified: Int64
    let ageDays: Int64
    let category: String
    let reclaim: String?
    let readError: Bool
    let hasChildren: Bool
    let children: [NodeDTO]?
    let rest: RestDTO?
    // Only on the node a request asked for.
    let path: String?
    let trail: [TrailStep]?
    let share: Double?
}

struct InsightDTO: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let name: String?
    let bytes: Int64
    let why: String
    let markable: Bool
}

struct InsightsDTO: Codable { let items: [InsightDTO] }

struct PointDTO: Codable, Hashable {
    let t: Int64
    let total: Int64?
    let available: Int64?
    let bytes: Int64
}

struct HistoryDTO: Codable { let points: [PointDTO] }

struct GrowthItem: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let delta: Int64
    let bytes: Int64
}

struct GrowthDTO: Codable, Hashable {
    let items: [GrowthItem]
    let baseAt: Int64?
}

struct SuggestItem: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let bytes: Int64
    let why: String
    let markable: Bool
    let category: String
    let ageDays: Int64
}

struct SuggestSection: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let bytes: Int64
    let items: [SuggestItem]
}

struct SuggestDTO: Codable, Hashable {
    let sections: [SuggestSection]
}

struct PlanTarget: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64
}

struct Blocked: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let reason: String
}

struct PlanDTO: Codable, Hashable {
    let mode: String
    let bytes: Int64
    let targets: [PlanTarget]
    let covered: [String]
    let blocked: [Blocked]
}

struct RemovedItem: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let error: String?
}

struct RemovalDone: Codable, Hashable {
    let removed: Int64
    let bytes: Int64
    let failed: Int64
    let gained: Int64
}

struct RemovalDTO: Codable, Hashable {
    let mode: String
    let total: Int64
    let items: [RemovedItem]
    let done: RemovalDone?
}

struct APIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

enum API {
    static let base = URL(string: "http://127.0.0.1:7321/")!

    // A path in a query must survive the server's form decoding, which reads "+" as a space.
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()

    static func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value)"
            }.joined(separator: "&")
        }
        return components.url!
    }

    static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: url(path, query))
        request.timeoutInterval = 30
        return try await send(request)
    }

    static func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The server refuses a POST without it: another site's page cannot set it without a preflight.
        request.setValue("1", forHTTPHeaderField: "X-Disk")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return try await send(request)
    }

    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(message: message ?? "HTTP \(status)", status: status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// `null` bodies (no removal yet) decode to this.
struct Optionally<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = container.decodeNil() ? nil : try container.decode(T.self)
    }
}
