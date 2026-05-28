import Foundation

struct CreditPack: Identifiable, Hashable {
    let id: String
    let productId: String
    let credits: Int
    let price: String
    let perCredit: String
    let bestValue: Bool
}

extension CreditPack {
    static let all: [CreditPack] = [
        .init(id: "sm", productId: "com.anthersystems.VirtualSIM.credits.5",
              credits: 5,  price: "$2.99",  perCredit: "$0.60 / cr", bestValue: false),
        .init(id: "md", productId: "com.anthersystems.VirtualSIM.credits.12",
              credits: 12, price: "$5.99",  perCredit: "$0.50 / cr", bestValue: true),
        .init(id: "lg", productId: "com.anthersystems.VirtualSIM.credits.30",
              credits: 30, price: "$12.99", perCredit: "$0.43 / cr", bestValue: false),
    ]

    static let allProductIds: [String] = all.map(\.productId)
}
