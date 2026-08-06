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

    private var canDial: Bool {
        digits.filter(\.isNumber).count >= 7 && !isEmergency && !exhausted
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
        .task { withAnimation(RMotion.content) { appeared = true } }
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
            Text(digits.isEmpty
                 ? String(localized: "Enter a number")
                 : PhoneFormat.national(digits))
                .font(RFont.mono(30, weight: .semibold))
                .foregroundStyle(digits.isEmpty ? theme.text3 : theme.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(RMotion.value, value: digits)

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
                Image(systemName: RIcon.phone)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(canDial ? theme.onInk : theme.text3)
                    .frame(width: 68, height: 68)
                    .background(canDial ? theme.live : theme.chipBg, in: .circle)
                    .shadow(color: canDial ? theme.live.opacity(0.35) : .clear,
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
                        Button { onKey(key) } label: {
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
                    }
                }
            }
        }
    }
}
