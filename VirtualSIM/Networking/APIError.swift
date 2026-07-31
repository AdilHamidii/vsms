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
        case .badResponse:
            return "Couldn't reach the server. Check your connection and try again."
        case .decoding:
            // NOT a connectivity message. A decode failure means the request
            // SUCCEEDED and we could not read the reply — blaming the user's
            // connection sends them to re-check their wifi and, worse, to retry
            // an action the server already performed. That is exactly what
            // happened with support messages: sent, relayed, and reported as a
            // network failure.
            return "Something went wrong on our side. Your last action may have gone through — check before retrying."
        case .http(let status, let body):
            // Surface a known business-logic error from our own backend.
            if let kind = parseErrorType(body) {
                switch kind {
                case "insufficient_credits":
                    return "Not enough credits. Tap Top up to buy more."
                case "no_numbers_available", "route_unavailable":
                    return "No numbers available for this combination right now. Try another country or service."
                case "premium_unavailable":
                    return "Real-SIM numbers just sold out here. Try Standard, or another country."
                // This service refuses VoIP numbers, so only Real SIM is sold
                // here. Shipped clients that predate the Real-SIM-only routes
                // would otherwise fall through to the generic 4xx text.
                case "real_sim_required":
                    return "This service only works with a Real SIM number. Pick Real SIM to continue."
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
                // The 180s minimum hold. Codes arrive at a median of 58s and a p90
                // of 134s, so a cancel inside three minutes is impatience rather
                // than a dead number — and it destroys a code that is often
                // already on its way.
                case "cancel_too_early":
                    return "Hang on — most codes arrive within three minutes. You can cancel shortly."
                // eSIM codes. Unmapped, every one of these fell through to the
                // 5xx fallback and blamed our infrastructure for SMSPool being
                // out of stock or out of balance.
                case "esim_out_of_stock":
                    return "That eSIM plan just sold out. Try another plan or country."
                case "esim_purchase_failed":
                    return "That eSIM couldn't be purchased right now. Please try again."
                case "plan_unavailable":
                    return "That eSIM plan isn't available anymore."
                case "duplicate_request":
                    return "That purchase is already going through — give it a moment."
                // Temporary email. Mapped in the same commit as the edge
                // functions that emit them: an unmapped code falls through to
                // the 5xx fallback and blames our infrastructure for a stockout.
                case "email_out_of_stock":
                    return "That email domain just ran out. Try another one."
                case "domain_unavailable":
                    return "We don't offer that email domain."
                case "email_unsupported_service":
                    // 11 of 265 services have no domain, so the provider has no
                    // target site to bind the address to.
                    return "Email addresses aren't available for this service yet."
                case "email_purchase_failed":
                    return "We couldn't get an address right now. Please try again."
                case "free_limit_reached":
                    return "You've used today's free addresses. Try again tomorrow, or pick Gmail or iCloud."
                case "unknown_service":
                    return "That service isn't available anymore."
                case "order_persist_failed":
                    return "Something went wrong saving that. Your credits are unchanged."
                // Apple took the money and the credit did not land. The
                // generic 409 text is "Not available right now. Try a different
                // option." — which on a paid purchase reads as "pick another
                // pack", the one thing that would charge them twice.
                case "credit_pending":
                    return "Your purchase went through and your credits are on their way. They'll appear shortly — no need to buy again."
                case "credit_failed":
                    return "Your purchase went through but we couldn't add the credits. Contact support and we'll sort it — don't buy again."
                case "spend_failed", "refund_failed":
                    return "We couldn't complete that. Your credits are unchanged — please try again."
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
