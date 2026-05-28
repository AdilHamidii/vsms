import Foundation

enum NumberGenerator {
    static func phoneNumber(for country: Country) -> String {
        let r = { Int.random(in: 0...9) }
        let n3 = { "\(r())\(r())\(r())" }
        let n4 = { "\(r())\(r())\(r())\(r())" }
        switch country.code {
        case "+1":   return "+1 (\(n3())) 555-\(n4())"
        case "+44":  return "+44 7700 \(n3())\(n3())"
        case "+49":  return "+49 15\(r()) \(n4()) \(n4())"
        case "+33":  return "+33 6 \(n4()) \(n4())"
        case "+91":  return "+91 \(r())\(r())\(r())\(r())\(r()) \(n4())\(r())"
        case "+55":  return "+55 11 9\(n4())-\(n4())"
        case "+63":  return "+63 9\(n3()) \(n3()) \(n4())"
        case "+234": return "+234 80\(r()) \(n3()) \(n4())"
        default:     return "\(country.code) \(n3()) \(n4())"
        }
    }

    static func otp(length: Int = 6) -> String {
        (0..<length).map { _ in String(Int.random(in: 0...9)) }.joined()
    }
}
