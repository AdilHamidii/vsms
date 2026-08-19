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

    /// Seconds the server asked us to wait, when it sent one.
    ///
    /// `cancel-order` returns `retry_after_seconds` alongside its 429
    /// `cancel_too_early`, and it is the only figure computed on the server's
    /// own clock against the server's own constant — so it is right even when
    /// this client's mirror of that constant is a release out of date. Read it
    /// rather than counting locally wherever both are available.
    var retryAfterSeconds: Int? {
        guard case .http(_, let body) = self else { return nil }
        return parseRetryAfterSeconds(body)
    }

    /// The backend's own `{"error": "..."}` code, when there is one.
    ///
    /// 🔴 This exists so a caller can classify an error WITHOUT comparing the
    /// rendered sentence. `ErrorBanner` used to decide "informational vs
    /// blocking" by rendering every known code with an empty body and testing
    /// the live message for set membership — which silently fails for any
    /// message that interpolates server data. `cancel_too_early` is exactly
    /// that: with `retry_after_seconds` it renders "Hang on. You can cancel in
    /// 42 seconds…", which matches nothing in the precomputed set, so a purely
    /// informational wait was shown as a blocking red error with a warning
    /// haptic and a "Check your orders" escape — on the screen with the
    /// highest cancel pressure in the app. Classify on the CODE.
    ///
    /// Deliberately nil for GoTrue responses: auth speaks a different envelope
    /// and `parseErrorType` must never be pointed at it (see `parseGoTrueError`).
    var businessCode: String? {
        guard case .http(_, let body) = self else { return nil }
        if parseGoTrueError(body) != nil { return nil }
        return parseErrorType(body)
    }

    /// Short, user-facing — safe to show in the error banner.
    var userMessage: String {
        switch self {
        case .notAuthenticated:
            return String(localized: "Please sign in again to continue.")
        case .appleSignInCanceled:
            return ""
        case .appleSignInFailed:
            return String(localized: "Sign in didn't complete. Please try again.")
        case .badResponse:
            return String(localized: "Couldn't reach the server. Check your connection and try again.")
        case .decoding:
            // NOT a connectivity message. A decode failure means the request
            // SUCCEEDED and we could not read the reply — blaming the user's
            // connection sends them to re-check their wifi and, worse, to retry
            // an action the server already performed. That is exactly what
            // happened with support messages: sent, relayed, and reported as a
            // network failure.
            return String(localized: "Something went wrong on our side. Your last action may have gone through, so check before retrying.")
        case .http(let status, let body):
            // 🔴 GoTrue FIRST, and it must stay first.
            //
            // Auth speaks a DIFFERENT envelope from our own backend —
            // `{"code":400,"error_code":"invalid_credentials","msg":"…"}` —
            // where `code` is the HTTP status, not a business code. Before
            // this, none of it was parsed, so every wrong password fell
            // through to the status ladder below and rendered "Not available
            // right now." Worse, a bad confirmation code is a **403**, which
            // that ladder answers with "Please sign in again" — advice that
            // sends the user backwards out of a flow they are halfway through.
            if let kind = parseGoTrueError(body), let message = goTrueMessage(kind) {
                return message
            }
            // Surface a known business-logic error from our own backend.
            if let kind = parseErrorType(body) {
                switch kind {
                case "insufficient_credits":
                    return String(localized: "Not enough credits. Tap Top up to buy more.")
                case "no_numbers_available", "route_unavailable":
                    return String(localized: "No numbers available for this combination right now. Try another country or service.")
                case "premium_unavailable":
                    return String(localized: "Real-SIM numbers just sold out here. Try Standard, or another country.")
                // This service refuses VoIP numbers, so only Real SIM is sold
                // here. Shipped clients that predate the Real-SIM-only routes
                // would otherwise fall through to the generic 4xx text.
                case "real_sim_required":
                    return String(localized: "This service only works with a Real SIM number. Pick Real SIM to continue.")
                case "smspva_error":
                    return String(localized: "Numbers aren't available right now. Please try a different country or service.")
                // The backend sends `provider_unreachable` (not the older
                // `smspva_unreachable`) for a provider that is down, rate
                // limited, or OUT OF BALANCE. Unmapped, it fell through to the
                // 5xx fallback and blamed us for a third-party outage — and
                // told the user to retry into a wall.
                case "provider_unreachable", "smspva_unreachable":
                    return String(localized: "The number provider is unreachable. Please try again in a moment.")
                // Product-neutral on purpose: create-email-order and
                // create-esim-order emit this too, and the old copy told an
                // EMAIL buyer that a "number" costs too much and to try another
                // "country" — neither exists in that product.
                case "margin_too_low":
                    return String(localized: "That costs more than expected right now. Please try a different option, or try again later.")
                // `unknown_order` is check-email-order's spelling of the same
                // thing; unmapped it fell to the generic 404.
                case "order_not_found", "unknown_order":
                    return String(localized: "We couldn't find that order anymore.")
                case "not_cancelable":
                    return String(localized: "This order can't be canceled.")
                // The minimum hold. Codes arrive at a median of 58s, so an early
                // cancel is impatience rather than a dead number — and it
                // destroys a code that is often already on its way.
                //
                // ⚠️ NEVER hardcode the window here. This copy said "within
                // three minutes" for weeks after the hold went 180 → 90, so the
                // app quoted a THIRD number matching neither the server constant
                // nor the countdown on the waiting screen. The server sends
                // `retry_after_seconds` with every refusal; quote that when it
                // is there and stay vague when it is not.
                case "cancel_too_early":
                    if let secs = retryAfterSeconds, secs > 0 {
                        return String(localized: "Hang on. You can cancel in \(secs) seconds. Most codes arrive in the first couple of minutes.")
                    }
                    return String(localized: "Hang on. Codes usually arrive within a couple of minutes. You can cancel shortly.")
                // eSIM codes. Unmapped, every one of these fell through to the
                // 5xx fallback and blamed our infrastructure for SMSPool being
                // out of stock or out of balance.
                case "esim_out_of_stock":
                    return String(localized: "That eSIM plan just sold out. Try another plan or country.")
                case "esim_purchase_failed":
                    return String(localized: "That eSIM couldn't be purchased right now. Please try again.")
                case "plan_unavailable":
                    return String(localized: "That eSIM plan isn't available anymore.")
                case "duplicate_request":
                    return String(localized: "That purchase is already going through. Give it a moment.")
                // Temporary email. Mapped in the same commit as the edge
                // functions that emit them: an unmapped code falls through to
                // the 5xx fallback and blames our infrastructure for a stockout.
                case "email_out_of_stock":
                    return String(localized: "That email domain just ran out. Try another one.")
                case "domain_unavailable":
                    return String(localized: "We don't offer that email domain.")
                case "email_unsupported_service":
                    // 11 of 265 services have no domain, so the provider has no
                    // target site to bind the address to.
                    return String(localized: "Email addresses aren't available for this service yet.")
                case "email_purchase_failed":
                    return String(localized: "We couldn't get an address right now. Please try again.")
                // No iCloud here: icloud.com was removed from the product on
                // 2026-07-31 and create-email-order refuses it — naming it sent
                // users to an option the app itself rejects.
                case "free_limit_reached":
                    return String(localized: "You've used today's free addresses. Try again tomorrow, or pick Gmail.")
                case "subscription_required":
                    // "unlimited" was a promise the server does not keep —
                    // subscribers are capped daily and refused with
                    // `daily_cap_reached`, whose copy sits three lines below
                    // this one. The app contradicted itself.
                    return String(localized: "You've used your free address. Subscribe for more addresses each day on Outlook and Hotmail.")
                case "daily_cap_reached":
                    return String(localized: "You've hit today's limit on addresses. It resets at midnight UTC.")
                // Both are 409s from `record_email_subscription`, and both are
                // reached almost exclusively from RESTORE — the device still
                // holds a signed transaction the server has since marked dead.
                //
                // 🔴 Without these two cases they fell to the generic 409 copy,
                // "Not available right now. Try a different option.", which
                // tells someone whose subscription was REFUNDED to go and buy
                // something else. That is the worst possible reading: it invites
                // a second purchase to fix a refund they asked for.
                case "subscription_revoked":
                    return String(localized: "That subscription was refunded, so it's no longer active. Subscribe again whenever you'd like more addresses.")
                case "subscription_expired":
                    return String(localized: "That subscription has ended. Subscribe again whenever you'd like more addresses.")
                case "unknown_service":
                    return String(localized: "That service isn't available anymore.")
                case "order_persist_failed":
                    return String(localized: "Something went wrong saving that. Your credits are unchanged.")
                // Apple took the money and the credit did not land. The
                // generic 409 text is "Not available right now. Try a different
                // option." — which on a paid purchase reads as "pick another
                // pack", the one thing that would charge them twice.
                case "credit_pending":
                    return String(localized: "Your purchase went through and your credits are on their way. They'll appear shortly, so there's no need to buy again.")
                case "credit_failed":
                    return String(localized: "Your purchase went through but we couldn't add the credits. Contact support and we'll sort it. Don't buy again.")
                case "spend_failed", "refund_failed":
                    return String(localized: "We couldn't complete that. Your credits are unchanged. Please try again.")
                case "verification_failed":
                    return String(localized: "We couldn't verify that purchase. Please try again.")
                case "unknown_product":
                    return String(localized: "That credit pack isn't available right now.")
                // Rented second numbers. Mapped in the same commit as the edge
                // functions that emit them — an unmapped code falls through to
                // the HTTP-class fallback and blames our infrastructure for a
                // stockout, a pause, or the user's own existing line.
                case "lines_paused":
                    return String(localized: "Second numbers aren't available right now. Please check back soon.")
                case "line_exists":
                    return String(localized: "You already have a second number. You can only have one at a time.")
                case "number_taken":
                    // Someone took it between the picker and the tap. Ordinary,
                    // and recoverable by just picking again — so the copy must
                    // not sound like a fault.
                    return String(localized: "That number was just taken. Pick another one. There are plenty.")
                case "line_unavailable":
                    // The Telnyx float guard. Deliberately does NOT say "we're
                    // out of money": it is our problem, not something the user
                    // can act on, and no charge was made.
                    return String(localized: "We can't set up new numbers right now. Please try again later. You haven't been charged.")
                case "subscription_bound":
                    return String(localized: "That subscription is already linked to another account.")
                case "sandbox_not_provisioned":
                    return String(localized: "Test purchases don't create a real number.")
                case "provision_failed", "subscription_record_failed":
                    // The one path where Apple holds the money and we cannot
                    // refund it ourselves. "Don't buy again" is the important
                    // half — a second subscription makes it worse.
                    return String(localized: "Your subscription went through but we couldn't set the number up. We've been alerted. Please don't subscribe again.")
                // Emitted by `send-line-message` on a provider fault. It was
                // absent from this switch, so it fell to the generic 5xx copy —
                // which `ErrorBanner` cannot recognise as informational, so a
                // transient Telnyx hiccup closed the conversation and threw the
                // draft away. The message says the text was not sent and that
                // nothing was spent, because the allowance IS handed back.
                case "message_send_failed":
                    return String(localized: "That message didn't send. Nothing was used from your allowance — try again.")
                case "allowance_exhausted":
                    return String(localized: "You've used this month's allowance. It resets when your subscription renews.")
                case "line_suspended":
                    return String(localized: "Your number is on hold. Resubscribe to start using it again.")
                case "emergency_blocked":
                    return String(localized: "This number can't call emergency services. Use your phone's own number.")
                // International calling. `destination_unavailable` covers both
                // "we have no price for this country" and "we have a price but
                // the destination is not switched on at the carrier" — the two
                // are indistinguishable to the user and the action is the same,
                // so they deliberately share one message rather than one of
                // them leaking our provider configuration into the app.
                case "destination_unavailable":
                    return String(localized: "We can't call this country yet.")
                // Outbound SMS was retired product-wide on 2026-08-18, so
                // `send-line-message` refuses every send with this code. The
                // message must not read as a fault or a temporary outage —
                // nothing is coming back — and it points at the capability that
                // DOES work outward, which is calling.
                case "outbound_sms_retired":
                    return String(localized: "This number receives texts but doesn't send them. Calls work — tap the phone icon.")
                case "recipient_blocked":
                    return String(localized: "You've blocked this number. Unblock it to send a message.")
                // Names the real limit instead of the carrier's rejection.
                // Every cross-border send has come back "the sending number is
                // not 10DLC-registered", which is true, unfixable by the user,
                // and meaningless to them. What they can act on is: this number
                // texts Canada today, and it can still RECEIVE from anywhere.
                case "cross_border_sms":
                    return String(localized: "Your Canadian number can only text Canadian numbers right now. It can still receive texts from anywhere.")
                // Separate from the cross-border case on purpose: "text a
                // Canadian number instead" is useless advice to someone
                // messaging Europe, and telling them the wrong workaround is
                // worse than telling them none.
                case "international_sms":
                    return String(localized: "This number can't text outside Canada and the US yet. It can still receive texts from anywhere.")
                // Emitted by `begin-line-call`. All four were absent, so every
                // one fell through to the HTTP-status fallback — which for
                // `bad_number` meant reporting the user's own typo as a fault
                // on our side, and told them to retry something that will fail
                // identically every time.
                case "bad_number":
                    return String(localized: "That doesn't look like a valid phone number. Check it and try again.")
                case "lookup_failed", "call_failed":
                    return String(localized: "We couldn't start that call. Please try again.")
                // NOTE: `begin-line-call` also emits `line_unavailable`, which
                // is already handled above for the provisioning float guard. The
                // copy there ("we can't set up new numbers right now") is a
                // reasonable read for both, and a second case here would be
                // unreachable — Swift warns about exactly that.
                case "unauthorized":
                    return String(localized: "Please sign in again.")
                default:
                    break
                }
            }
            // Generic HTTP class fallbacks — no codes leaked.
            switch status {
            case 401, 403: return String(localized: "Please sign in again.")
            case 402:      return String(localized: "Not enough credits. Tap Top up to buy more.")
            case 404:      return String(localized: "That isn't available right now.")
            case 409:      return String(localized: "Not available right now. Try a different option.")
            case 429:      return String(localized: "You're going a bit fast. Please wait a moment and try again.")
            case 500...599:return String(localized: "Something went wrong on our side. Please try again.")
            default:       return String(localized: "Something went wrong. Please try again.")
            }
        }
    }
}

/// Extract `retry_after_seconds` from a JSON-shaped response body if present.
///
/// Accepts a number or a numeric string: the value is generated by
/// `Math.ceil` on the server today, but a body that arrives as `"12"` should
/// re-lock the button rather than silently reading as "no hold at all".
private func parseRetryAfterSeconds(_ body: String?) -> Int? {
    guard let body, let data = body.data(using: .utf8) else { return nil }
    guard let parsed = try? JSONSerialization.jsonObject(with: data),
          let obj = parsed as? [String: Any] else { return nil }
    if let n = obj["retry_after_seconds"] as? NSNumber { return n.intValue }
    if let s = obj["retry_after_seconds"] as? String { return Int(s) }
    return nil
}

/// Extract the `error` field from a JSON-shaped response body if present.
/// GoTrue's error code, or nil when this is not a GoTrue response.
///
/// Kept separate from `parseErrorType` on purpose. Our backend answers
/// `{"error":"insufficient_credits"}` while GoTrue answers
/// `{"code":400,"error_code":"…","msg":"…"}` — and some `/token` paths use the
/// OAuth shape `{"error":"invalid_grant","error_description":"…"}`. Merging the
/// two readers would let an OAuth `error` be looked up in our own table of
/// business codes, which is how a wrong password could end up rendering
/// somebody else's copy.
private func parseGoTrueError(_ body: String?) -> String? {
    guard let body, let data = body.data(using: .utf8) else { return nil }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    if let code = obj["error_code"] as? String { return code }
    // The OAuth envelope — only trust `error` here when `error_description`
    // is alongside it, which is what distinguishes it from ours.
    if obj["error_description"] != nil, let code = obj["error"] as? String { return code }
    return nil
}

/// Copy for the GoTrue codes this app can actually provoke.
private func goTrueMessage(_ code: String) -> String? {
    switch code {
    case "invalid_credentials", "invalid_grant":
        return String(localized: "That email and password don't match. Check them and try again.")
    case "email_not_confirmed":
        return String(localized: "Confirm your email first — we sent you a code.")
    case "email_exists", "user_already_exists":
        return String(localized: "There's already an account with that email. Sign in instead, or reset your password.")
    // ⚠️ NO NUMBER HERE. The threshold is a dashboard setting — probed
    // 2026-08-18 and currently **6**, while the sign-up screen asks for 8 as
    // our own stricter rule. Quoting either one in the SERVER's error means
    // printing a figure that something else can change underneath us, which is
    // the same trap as a hardcoded credit amount.
    case "weak_password":
        return String(localized: "That password is too short. Pick a longer one.")
    // ⚠️ ONE MESSAGE FOR BOTH CASES, BECAUSE GoTrue CANNOT TELL THEM APART.
    // A wrong code and an expired code both return 403 `otp_expired` with the
    // same body, so copy naming only one of them would be wrong half the time.
    case "otp_expired":
        return String(localized: "That code isn't right, or it's expired. Ask for a new one.")
    case "over_email_send_rate_limit", "over_request_rate_limit":
        return String(localized: "Too many attempts. Wait a few minutes and try again.")
    case "signup_disabled", "email_provider_disabled":
        return String(localized: "New accounts are paused right now. Try signing in with Apple.")
    case "email_address_invalid", "validation_failed":
        return String(localized: "That doesn't look like a valid email address.")
    case "same_password":
        return String(localized: "That's already your password. Pick a different one.")
    default:
        return nil
    }
}

private func parseErrorType(_ body: String?) -> String? {
    guard let body, let data = body.data(using: .utf8) else { return nil }
    guard let parsed = try? JSONSerialization.jsonObject(with: data),
          let obj = parsed as? [String: Any] else { return nil }
    return obj["error"] as? String
}
