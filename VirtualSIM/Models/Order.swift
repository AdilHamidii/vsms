import Foundation

/// UI-facing order. Wraps the server row and the resolved Service/Country
/// from the catalog so existing screens (which read order.service.name etc.)
/// keep working with no API surface changes.
struct Order: Identifiable, Hashable {
    let server: ServerOrder
    let service: Service
    let country: Country

    var id: String { server.id }
    var number: String { server.smspvaNumber ?? "Pending…" }
    var otp: String? { server.otp }
    var status: OrderStatus { server.status }
    var createdAt: Date { server.createdAt }
    var expiresAt: Date { server.expiresAt }
    var costCredits: Int { server.costCredits }

    var ago: String {
        Self.relative.localizedString(for: server.createdAt, relativeTo: Date())
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
