import SwiftUI

/// The keypad.
///
/// Two things it refuses to do, both deliberate: it will not dial an emergency
/// number, and it will not dial when the month's minutes are gone. Both are
/// also enforced server-side in `begin-line-call` — the client copy exists so
/// the refusal is instant and explains itself, not because it is the boundary.
struct DialerScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(CallController.self) private var calls

    @State private var digits = ""
    @State private var appeared = false

    /// E911 is disabled on these numbers at the provider, so an emergency call
    /// would fail at the worst possible moment. Same set as the server.
    private static let emergency: Set<String> = ["911", "112", "999", "000", "110", "119", "988"]

    private var isEmergency: Bool {
        Self.emergency.contains(digits.filter(\.isNumber))
    }

    private var remaining: Int? { state.line?.voiceSecondsRemaining }

    private var exhausted: Bool {
        if let remaining { return remaining <= 0 }
        return false
    }

    /// The priced destination for what has been typed so far, if any.
    private var destination: VoiceRate? {
        state.voiceRates.match(dialled: digits)
    }

    /// True when this call is paid in credits rather than plan minutes.
    private var isInternational: Bool {
        guard digits.hasPrefix("+") else { return false }
        guard let d = destination else { return false }
        return !d.coveredByAllowance
    }

    /// Credits needed for the server's reservation block, mirroring
    /// `begin_intl_call_claim`: RESERVE_SECONDS (120) at this destination's
    /// rate, rounded up, minimum 1.
    private var creditsNeeded: Int? {
        guard isInternational, let d = destination else { return nil }
        return max(Int((120.0 * d.creditsPerMin / 60.0).rounded(.up)), 1)
    }

    private var shortOnCredits: Bool {
        guard let need = creditsNeeded else { return false }
        return state.balance < need
    }

    private var canDial: Bool {
        // A tap that is already being answered must not be tappable again —
        // each one reserves credits server-side.
        guard !calls.isStarting else { return false }
        guard digits.filter(\.isNumber).count >= 7, !isEmergency else { return false }
        if digits.hasPrefix("+") {
            // International: the wallet pays, so plan minutes are irrelevant —
            // an exhausted allowance must NOT block a call the user is paying
            // cash for. It needs a price we know and a balance that covers it.
            guard let d = destination else { return false }
            if d.coveredByAllowance { return !exhausted }
            return !shortOnCredits
        }
        return !exhausted
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                readout
                Spacer(minLength: 0)
                Dialpad { key in
                    RHaptic.select()
                    if key == "⌫" {
                        if !digits.isEmpty { digits.removeLast() }
                    } else if key == "+" {
                        // Only ever leading, as on every real dialer. A `+`
                        // mid-number is not a country code, it is a typo, and
                        // accepting it would produce a string `toE164` refuses
                        // AFTER the user has finished typing.
                        if digits.isEmpty { digits = "+" }
                    } else {
                        digits.append(key)
                    }
                }
                .riseIn(appeared, index: 1)
                callRow.padding(.top, 22).riseIn(appeared, index: 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        // DECLARE the intent and the amount, never let `creditsShortfall`
        // infer them. This is the pattern `PurchaseIntent` exists to enforce,
        // and both are cleared in `clearLineDraft()` on leaving the tab.
        // 🔴 THE CALL SCREEN CANNOT BE SEEN FROM HERE. `InCallOverlay` is an
        // overlay on the ROOT view and the dialer is a `fullScreenCover`, which
        // always renders above it — so pressing call left the keypad on screen
        // with the live call invisible behind it. Reported from a real call to
        // France, 2026-08-18.
        //
        // It watches `isCommitted`, NOT `isLive`: a call the server refuses
        // (no price for the country, not enough credits) must leave the keypad
        // up, because that is where the refusal is explained.
        .onChange(of: calls.isCommitted) { _, committed in
            if committed { state.flow = nil }
        }
        .onChange(of: creditsNeeded) { _, need in
            if let need {
                state.intent = .call
                state.callCreditsNeeded = need
                state.callDestinationLabel = destination?.label
            } else if state.intent == .call {
                state.intent = .line
                state.callCreditsNeeded = nil
                state.callDestinationLabel = nil
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // The rate card. Cheap, cached for the session, and the dialer is
            // the only screen that reads it — so it loads here rather than
            // lengthening the cold-launch chain, which is already six
            // sequential round-trips before the app is usable.
            if state.voiceRates.isEmpty {
                await state.loadVoiceRates(using: LineAPI(client: api))
            }
            // Mint the credential and open the WebRTC socket while the user is
            // still typing. `placeCall` calls this again and it returns
            // immediately when already registered, so this is latency the call
            // path does not have to pay — the difference between a number that
            // rings and one that sits silent for a second first.
            await calls.prepareVoice()
        }
    }

    private var header: some View {
        HStack {
            Button { state.flow = nil } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
                    .contentShape(.circle)
            }
            .pressable(0.9)
            Spacer()
            if let remaining {
                StatusPill(
                    text: "\(remaining / 60) min left",
                    tint: remaining < 300 ? theme.warn : theme.text2,
                    soft: remaining < 300 ? theme.warnSoft : theme.chipBg,
                    dot: false)
            }
        }
        .padding(.top, 12)
    }

    private var readout: some View {
        VStack(spacing: 10) {
            // `PhoneFormat.national` groups a NANP number and would mangle an
            // international one — it has no idea where the country code ends.
            // A leading `+` means the user is telling us the country, so show
            // exactly what they typed.
            Text(digits.isEmpty
                 ? String(localized: "Enter a number")
                 : (digits.hasPrefix("+") ? digits : PhoneFormat.national(digits)))
                .font(RFont.mono(30, weight: .semibold))
                .foregroundStyle(digits.isEmpty ? theme.text3 : theme.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(RMotion.value, value: digits)

            // What this call will cost, the moment the country is unambiguous.
            //
            // Only shown for a `+` number: a bare national string is NANP by
            // definition here, and quoting "included" against a number whose
            // country we inferred would be a claim we cannot stand behind.
            if digits.hasPrefix("+"), let rate = destination {
                HStack(spacing: 7) {
                    CodeFlag(code: rate.iso2, size: 18)
                    Text(verbatim: rate.label)
                        .font(RFont.text(12, weight: .semibold))
                        .foregroundStyle(theme.text2)
                    Text(verbatim: "·")
                        .font(RFont.text(12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                    Text(rate.rateSentence)
                        .font(RFont.text(12, weight: .semibold))
                        .foregroundStyle(rate.coveredByAllowance ? theme.text2 : theme.ink)
                }
                .transition(.opacity)
            } else if digits.hasPrefix("+"), digits.filter(\.isNumber).count >= 2 {
                // A country we have no price for is NOT callable. Saying so
                // here is the whole point — the server refuses it anyway, and
                // discovering that after tapping call is a worse experience
                // than being told while typing.
                Text("We can't call this country yet.")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.text3)
            }

            // Short on credits: name the number, don't just grey the button.
            // A disabled call button with no reason is the thing that makes a
            // user think the app is broken rather than that they need credits.
            if shortOnCredits, let need = creditsNeeded {
                Text("You need \(need) credits to start this call — you have \(state.balance).")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.warn)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The refusals, each stating WHY rather than just greying a button.
            if isEmergency {
                Text("This number can't reach emergency services. Use your phone's own number.")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.fail)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if exhausted {
                Text("You've used this month's minutes. They reset when your subscription renews.")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.warn)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let err = calls.lastError {
                Text(err)
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.fail)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(height: 96)
        .padding(.horizontal, 8)
    }

    private var callRow: some View {
        HStack(spacing: 20) {
            // Balances the layout so the call button sits centred, and gives
            // backspace a permanent home rather than only appearing with text.
            Color.clear.frame(width: 62, height: 62)

            Button {
                guard let line = state.line else { return }
                Task { await calls.placeCall(to: digits, from: line.e164) }
            } label: {
                Group {
                    if calls.isStarting {
                        ProgressView().tint(theme.onInk)
                    } else {
                        Image(systemName: RIcon.phone)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(canDial ? theme.onInk : theme.text3)
                    }
                }
                    .frame(width: 68, height: 68)
                    .background(canDial || calls.isStarting ? theme.live : theme.chipBg, in: .circle)
                    .shadow(color: canDial || calls.isStarting ? theme.live.opacity(0.35) : .clear,
                            radius: 16, y: 7)
                    .contentShape(.circle)
            }
            .pressable(0.92)
            .disabled(!canDial)

            Button {
                RHaptic.select()
                if !digits.isEmpty { digits.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(digits.isEmpty ? .clear : theme.text2)
                    .frame(width: 62, height: 62)
                    .contentShape(.circle)
            }
            .pressable(0.9)
            .disabled(digits.isEmpty)
        }
    }
}

/// A 4×3 keypad. Digits carry their letters because a phone keypad without
/// them does not read as one.
struct Dialpad: View {
    @Environment(\.theme) private var theme
    var onKey: (String) -> Void

    /// When the 0 key's long press last emitted a `+`.
    ///
    /// 🔴 A `simultaneousGesture` DOES NOT SUPPRESS THE BUTTON'S OWN ACTION.
    /// The long press fired `onKey("+")` at 0.4s and then, on finger-up, the
    /// Button ALSO fired `onKey("0")` — so the only way to type a `+` produced
    /// `"+0"`, France became `+033…`, `voiceRates.match(dialled:)` matched no
    /// prefix, and the readout said "We can't call this country yet." with the
    /// call button disabled. International calling — priced in credits and
    /// newly promoted on the store screen — was unreachable by construction.
    ///
    /// Timestamped rather than a bare flag so a long press the user drags away
    /// from (Button action never fires) cannot swallow the NEXT real tap on 0.
    @State private var plusEmittedAt: Date?

    private static let keys: [[(String, String)]] = [
        [("1", ""),    ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"),("8", "TUV"), ("9", "WXYZ")],
        [("*", ""),    ("0", "+"),   ("#", "")],
    ]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(Self.keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 26) {
                    ForEach(row, id: \.0) { key, letters in
                        Button {
                            // The long press below has already emitted the
                            // `+`; letting this fire too appended a `0` to it.
                            // See `plusEmittedAt`.
                            if key == "0", let at = plusEmittedAt,
                               Date().timeIntervalSince(at) < 1.5 {
                                plusEmittedAt = nil
                                return
                            }
                            onKey(key)
                        } label: {
                            VStack(spacing: 1) {
                                Text(verbatim: key)
                                    .font(RFont.display(27, weight: .regular))
                                    .foregroundStyle(theme.text)
                                if !letters.isEmpty {
                                    Text(verbatim: letters)
                                        .font(RFont.text(10, weight: .semibold))
                                        .tracking(1.2)
                                        .foregroundStyle(theme.text3)
                                }
                            }
                            .frame(width: 72, height: 62)
                            .background(theme.chipBg, in: .circle)
                            .contentShape(.circle)
                        }
                        .pressable(0.9)
                        // 🔴 `+` WAS UNREACHABLE. The 0 key has always PRINTED
                        // "+" as its subtitle, exactly like a hardware phone —
                        // but nothing was bound to it, so no user could ever
                        // type an international number. Long-press is the iOS
                        // convention every phone keypad uses, and it is what
                        // the printed glyph has been promising all along.
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .onEnded { _ in
                                    guard key == "0" else { return }
                                    RHaptic.select()
                                    // Stamped BEFORE emitting, because the
                                    // Button's own action fires on finger-up
                                    // and reads this to stand down.
                                    plusEmittedAt = Date()
                                    onKey("+")
                                }
                        )
                    }
                }
            }
        }
    }
}
