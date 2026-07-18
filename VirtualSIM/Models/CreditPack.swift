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
        // Larger packs for eSIM data plans (which run pricier than OTP numbers).
        .init(id: "xl", productId: "com.anthersystems.VirtualSIM.credits.60",
              credits: 60, price: "$24.99", perCredit: "$0.42 / cr", bestValue: false),
        .init(id: "xxl", productId: "com.anthersystems.VirtualSIM.credits.150",
              credits: 150, price: "$59.99", perCredit: "$0.40 / cr", bestValue: false),
    ]

    static let allProductIds: [String] = all.map(\.productId)
}
