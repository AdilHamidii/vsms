import Foundation
import StoreKit

/// First-party behavioural analytics. Fire-and-forget, in-memory only.
///
/// Three properties are load-bearing and none of them is a nicety:
///
/// - **It can never throw out, block, or surface an error.** `track` is a
///   synchronous enqueue onto the main actor; the flush swallows everything.
///   A measurement that can break the product is worse than no measurement —
///   the same rule `submitAttributionIfNeeded` already follows.
/// - **Events are QUEUED before sign-in and only FLUSHED once authenticated.**
///   `record-events` is JWT-verified, so a pre-sign-in flush would 401 and
///   drop the onboarding funnel — which is exactly the part nobody has ever
///   been able to see. Enqueue is ungated; flush is gated on `Session`.
/// - **Nothing is persisted.** Losing a batch to a force-quit is fine; a disk
///   queue would be one more thing to corrupt for data that is advisory.
///
/// Prop keys must stay lower_snake_case with no capitals: `JSONEncoder.relay`
/// applies `.convertToSnakeCase` to DICTIONARY keys as well as CodingKeys, so
/// a camelCase key would silently arrive renamed.
@MainActor
@Observable
final class Analytics {
    static let shared = Analytics()

    /// Server caps a batch at 50; the queue cap bounds memory when offline.
    private static let batchLimit = 50
    private static let flushAt = 25
    private static let queueCap = 200

    /// One per process launch, lowercased — the `providerSessionId` convention.
    private let sessionId = UUID().uuidString.lowercased()

    private var queue: [Event] = []
    private var isFlushing = false
    private var profileSends = 0
    private var storefront: String?
    private weak var client: APIClient?
    private weak var session: Session?
    private var timer: Task<Void, Never>?

    private init() {}

    /// Wired from `AuthGate`, alongside the other stores.
    func attach(api: APIClient, session: Session) {
        self.client = api
        self.session = session
        // Resolved once, off the critical path. Until it lands the profile is
        // sent without it, and a later flush sends the completed one.
        Task { [weak self] in
            let code = await Storefront.current?.countryCode
            self?.storefront = code
        }
        startTimer()
    }

    // MARK: - Enqueue

    func track(_ name: String, _ props: [String: AnalyticsValue]? = nil) {
        queue.append(Event(name: name,
                           props: props,
                           at: Date(),
                           sessionId: sessionId))
        if queue.count > Self.queueCap {
            queue.removeFirst(queue.count - Self.queueCap)
        }
        if queue.count >= Self.flushAt { flush() }
    }

    /// Call from the scenePhase observer. Background is the one moment we know
    /// a session is ending.
    func flushOnBackground() { flush() }

    // MARK: - Flush

    private func startTimer() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.flush()
            }
        }
    }

    private func flush() {
        guard !isFlushing, !queue.isEmpty, let client else { return }
        // The endpoint 401s without a session. Keep the events; the next flush
        // after sign-in carries them.
        guard case .signedIn = session?.status else { return }

        let batch = Array(queue.prefix(Self.batchLimit))
        queue.removeFirst(batch.count)
        let profile = profileSends < 2 ? currentProfile() : nil
        if profile != nil { profileSends += 1 }

        isFlushing = true
        Task { [weak self] in
            do {
                let _: APIClient.Empty = try await client.request(
                    .post,
                    path: "functions/v1/record-events",
                    body: Payload(events: batch, profile: profile))
            } catch {
                // Advisory endpoint: a delivered batch is never retried, but a
                // batch that never left keeps its place at the FRONT so the
                // funnel stays in order.
                self?.requeue(batch)
            }
            self?.isFlushing = false
        }
    }

    private func requeue(_ batch: [Event]) {
        queue.insert(contentsOf: batch, at: 0)
        if queue.count > Self.queueCap {
            queue.removeLast(queue.count - Self.queueCap)
        }
    }

    private func currentProfile() -> Profile {
        Profile(storefront: storefront,
                locale: Locale.current.identifier,
                timezone: TimeZone.current.identifier,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    // MARK: - Wire format

    private struct Event: Encodable {
        let name: String
        let props: [String: AnalyticsValue]?
        let at: Date
        let sessionId: String
    }

    private struct Profile: Encodable {
        let storefront: String?
        let locale: String
        let timezone: String
        let appVersion: String?
    }

    private struct Payload: Encodable {
        let events: [Event]
        let profile: Profile?
    }
}

/// The only prop shapes we send: coarse labels and integers. Deliberately not
/// `Any` — no message body, phone number, address or order id can be handed to
/// this by accident.
enum AnalyticsValue: Encodable {
    case string(String)
    case int(Int)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .bool(let v):   try c.encode(v)
        }
    }
}

extension AnalyticsValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String)  { self = .string(value) }
    init(integerLiteral value: Int)    { self = .int(value) }
    init(booleanLiteral value: Bool)   { self = .bool(value) }
}
