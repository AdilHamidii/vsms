import Foundation

struct CreditPack: Identifiable, Hashable {
    let id: String
    let credits: Int
    let price: String
    let perCredit: String
    let bestValue: Bool
}

extension CreditPack {
    static let all: [CreditPack] = [
        .init(id: "sm", credits: 5,  price: "$2.99",  perCredit: "$0.60 / cr", bestValue: false),
        .init(id: "md", credits: 12, price: "$5.99",  perCredit: "$0.50 / cr", bestValue: true),
        .init(id: "lg", credits: 30, price: "$12.99", perCredit: "$0.43 / cr", bestValue: false),
    ]
}
