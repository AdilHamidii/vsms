import Foundation

/// The last WebRTC credential `mint-line-token` issued, kept across launches.
///
/// ── Why this has to be persisted ──────────────────────────────────────────
///
/// 🔴 **A VoIP push wakes a TERMINATED app, and until this existed the SDK was
/// never handed that push.** `TelnyxVoiceClient` held the credential only in
/// memory, set by `connect(token:)`, which runs only when the user opens the
/// Number tab or the dialer. On a cold launch from a push the token was nil,
/// `handleVoIPPush` returned silently, `TxClient.isCallFromPush` stayed false,
/// and so `sendAttachCall()` (`TxClient.swift:1117-1118`) — the message that
/// actually asks Telnyx for the INVITE — was never sent. The phone rang,
/// answering threw `noActiveCall`, and the call died on the spot. Confirmed
/// against the provider: 116 inbound sessions in 30 days, every one 0 seconds
/// with no WebRTC leg.
///
/// So the credential is written to the Keychain on every successful mint and
/// read back by the push handler before any network call. The Keychain, not
/// `UserDefaults`, because it is a bearer credential for a paid voice line —
/// and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (what `KeychainStore`
/// already uses) is exactly the class a background push needs: readable while
/// the device is locked, provided it has been unlocked once since boot.
///
/// ⚠️ **A token that cannot be read is not an error worth surfacing** — it
/// means "mint a fresh one", which is what `CallController` does next.
enum VoiceCredentialStore {
    private enum Key {
        static let token = "telnyx.voice_token"
        static let savedAt = "telnyx.voice_token_saved_at"
        static let sipUser = "telnyx.sip_username"
        static let sipPassword = "telnyx.sip_password"
    }

    /// How long an unparseable token is trusted for.
    ///
    /// Telnyx issues a JWT and we read its own `exp`; this only covers a token
    /// whose shape we could not parse at all. Deliberately short — using a
    /// dead credential looks exactly like a push that never arrived, so the
    /// bias is towards re-minting.
    private static let fallbackTTL: TimeInterval = 10 * 60

    /// Treat a token as spent slightly before it really is: the login it is
    /// about to be used for is a round trip away.
    private static let expiryMargin: TimeInterval = 60

    static func save(_ credential: VoiceCredential) {
        switch credential {
        case let .sip(username, password):
            KeychainStore.set(username, for: Key.sipUser)
            KeychainStore.set(password, for: Key.sipPassword)
        case let .token(token):
            KeychainStore.set(token, for: Key.token)
            KeychainStore.set(String(Date().timeIntervalSince1970), for: Key.savedAt)
        }
    }

    static func clear() {
        KeychainStore.remove(Key.token)
        KeychainStore.remove(Key.savedAt)
        KeychainStore.remove(Key.sipUser)
        KeychainStore.remove(Key.sipPassword)
    }

    /// The best stored credential, or nil when there is none usable.
    ///
    /// 🔴 SIP credentials win whenever both are present, and they carry NO
    /// expiry check — they are the connection's own long-lived user, not a
    /// minted JWT, and they are the only credential an inbound call can be
    /// routed to. Preferring a still-valid token here would produce a session
    /// that dials out and never rings, which is the exact bug this replaced.
    static func validCredential(now: Date = Date()) -> VoiceCredential? {
        if let user = KeychainStore.get(Key.sipUser), !user.isEmpty,
           let password = KeychainStore.get(Key.sipPassword), !password.isEmpty {
            return .sip(username: user, password: password)
        }
        return validToken(now: now).map { .token($0) }
    }

    /// The stored credential, or nil when there is none or it has expired.
    static func validToken(now: Date = Date()) -> String? {
        guard let token = KeychainStore.get(Key.token), !token.isEmpty else { return nil }
        guard let expiry = expiry(of: token, now: now) else { return nil }
        return expiry.timeIntervalSince(now) > expiryMargin ? token : nil
    }

    /// When the token stops being usable: its own `exp` claim, else a short
    /// window from when we stored it.
    private static func expiry(of token: String, now: Date) -> Date? {
        if let exp = jwtExpiry(token) { return exp }
        guard let raw = KeychainStore.get(Key.savedAt), let saved = Double(raw) else {
            // Stored by a build that did not record the time. Refuse it rather
            // than guess — one extra mint costs a round trip.
            return nil
        }
        return Date(timeIntervalSince1970: saved).addingTimeInterval(fallbackTTL)
    }

    /// The `exp` claim of a JWT, without a dependency and without verifying the
    /// signature — we are not authenticating this token, only asking whether it
    /// is worth sending. Telnyx verifies it for real.
    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = object["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url drops the padding a Foundation decoder still requires.
        let remainder = b64.count % 4
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: b64)
    }
}
