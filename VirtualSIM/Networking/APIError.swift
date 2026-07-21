import Foundation

enum APIError: Error, LocalizedError {
    case badResponse
    case http(status: Int, body: String?)
    case decoding(Error)
    case notAuthenticated
    case appleSignInCanceled
    case appleSignInFailed(String)

    /// Verbose, developer-facing — never put this in a banner.
    var errorDescription: String? {
        switch self {
        case .badResponse:                return "Bad response"
        case .http(let s, let b):         return "HTTP \(s)\(b.map { ": \($0)" } ?? "")"
        case .decoding(let err):          return "Decoding error: \(err.localizedDescription)"
        case .notAuthenticated:           return "Not signed in"
        case .appleSignInCanceled:        return "Sign in canceled"
        case .appleSignInFailed(let msg): return "Sign in failed: \(msg)"
        }
    }

    /// Short, user-facing — safe to show in the error banner.
    var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Please sign in again to continue."
        case .appleSignInCanceled:
            return ""
        case .appleSignInFailed:
            return "Sign in didn't complete. Please try again."
        case .badResponse, .decoding:
            return "Couldn't reach the server. Check your connection and try again."
        case .http(let status, let body):
            // Surface a known business-logic error from our own backend.
            if let kind = parseErrorType(body) {
                switch kind {
                case "insufficient_credits":
                    return "Not enough credits. Tap Top up to buy more."
                case "no_numbers_available", "route_unavailable":
                    return "No numbers available for this combination right now. Try another country or service."
                case "smspva_error":
                    return "Numbers aren't available right now. Please try a different country or service."
                // The backend sends `provider_unreachable` (not the older
                // `smspva_unreachable`) for a provider that is down, rate
                // limited, or OUT OF BALANCE. Unmapped, it fell through to the
                // 5xx fallback and blamed us for a third-party outage — and
                // told the user to retry into a wall.
                case "provider_unreachable", "smspva_unreachable":
                    return "The number provider is unreachable. Please try again in a moment."
                case "margin_too_low":
                    return "That number costs more than expected right now. Try another country or service."
                case "order_not_found":
                    return "We couldn't find that order anymore."
                case "not_cancelable":
                    return "This order can't be canceled."
                case "verification_failed":
                    return "We couldn't verify that purchase. Please try again."
                case "unknown_product":
                    return "That credit pack isn't available right now."
                case "unauthorized":
                    return "Please sign in again."
                default:
                    break
                }
            }
            // Generic HTTP class fallbacks — no codes leaked.
            switch status {
            case 401, 403: return "Please sign in again."
            case 402:      return "Not enough credits. Tap Top up to buy more."
            case 404:      return "That isn't available right now."
            case 409:      return "Not available right now. Try a different option."
            case 429:      return "You're going a bit fast — please wait a moment and try again."
            case 500...599:return "Something went wrong on our side. Please try again."
            default:       return "Something went wrong. Please try again."
            }
        }
    }
}

/// Extract the `error` field from a JSON-shaped response body if present.
private func parseErrorType(_ body: String?) -> String? {
    guard let body, let data = body.data(using: .utf8) else { return nil }
    guard let parsed = try? JSONSerialization.jsonObject(with: data),
          let obj = parsed as? [String: Any] else { return nil }
    return obj["error"] as? String
}
