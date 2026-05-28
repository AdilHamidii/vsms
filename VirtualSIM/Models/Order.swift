import Foundation

struct Order: Identifiable, Hashable {
    let id: String
    let service: Service
    let country: Country
    let number: String
    var otp: String?
    var status: OrderStatus
    var ago: String
}
