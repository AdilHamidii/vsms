import SwiftUI

/// The in-call UI, rendered as a `ZStack` layer above the flow cover.
///
/// ── Why not a `FlowStage` ────────────────────────────────────────────────
///
/// A call can arrive while a `fullScreenCover` is already open, and
/// `fullScreenCover(item:)` cannot present a second cover — the call would
/// simply never appear. Swapping `flow` instead would destroy whatever the
/// user had in progress, including a half-finished checkout.
///
/// CallKit owns the incoming-call screen and the lock screen. This is what the
/// user comes back to INSIDE the app, so it deliberately does not try to
/// reproduce the system UI.
struct InCallOverlay: View {
    @Environment(\.theme) private var theme
    @Environment(CallController.self) private var calls
    /// OPTIONAL on purpose. This overlay is mounted twice — on the root view
    /// and inside the flow cover — and both call sites inject only `theme` and
    /// `calls`. Declaring `AppState` non-optionally would trap the moment a
    /// call goes live. The nickname is a nicety; the number underneath it is
    /// the thing that must always render.
    @Environment(AppState.self) private var state: AppState?

    @State private var tick = Date()
    @State private var showKeypad = false

    private var peerName: String? { state?.contactName(for: calls.peer) }

    var body: some View {
        ZStack {
            // Opaque, not a material: this sits over arbitrary app content and
            // a translucent call screen over a bright map or a photo is
            // unreadable exactly when the user needs to find "end".
            theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                identity
                Spacer(minLength: 0)
                if showKeypad {
                    Dialpad { digit in
                        Task { await calls.sendDigit(digit) }
                    }
                    .padding(.bottom, 26)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    controls.padding(.bottom, 26)
                }
                endButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = Date()
            }
        }
    }

    // MARK: - Who, and what state

    private var identity: some View {
        VStack(spacing: 10) {
            // The same avatar the peer wears on recents rows, conversation rows
            // and the thread header — a call must look like it is with the
            // person the rest of the app has been showing, not with a generic
            // phone glyph.
            PeerAvatar(e164: calls.peer, name: peerName, size: 96)

            // Named peers lead with the name and keep the number under it in
            // mono. Unnamed ones show the number alone, at the larger size —
            // never a placeholder like "Unknown", which is a claim.
            VStack(spacing: peerName == nil ? 0 : 4) {
                if let peerName {
                    Text(verbatim: peerName)
                        .font(RFont.display(27, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(theme.text)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(verbatim: PhoneFormat.national(calls.peer))
                        .font(RFont.mono(14))
                        .foregroundStyle(theme.text3)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                } else {
                    Text(verbatim: PhoneFormat.national(calls.peer))
                        .font(RFont.mono(27, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .padding(.top, 8)

            // Says which state the call is actually in. A screen that shows a
            // running timer before the other end has answered is claiming a
            // connection that does not exist yet.
            Text(statusLine)
                .font(RFont.text(14, weight: .medium))
                .foregroundStyle(calls.phase == .active ? theme.live : theme.text2)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private var statusLine: String {
        switch calls.phase {
        case .idle:       String(localized: "Ended")
        case .dialing:    String(localized: "Calling…")
        case .ringing:    String(localized: "Incoming call")
        case .connecting: String(localized: "Connecting…")
        case .ending:     String(localized: "Ending…")
        case .active:     PhoneFormat.duration(Int(tick.timeIntervalSince(calls.startedAt ?? tick)))
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 34) {
            circleToggle(icon: calls.isMuted ? "mic.slash.fill" : "mic.fill",
                         label: "Mute", on: calls.isMuted) {
                Task { await calls.toggleMute() }
            }
            circleToggle(icon: "circle.grid.3x3.fill",
                         label: "Keypad", on: showKeypad) {
                RHaptic.select()
                withAnimation(RMotion.panel) { showKeypad.toggle() }
            }
            circleToggle(icon: "speaker.wave.3.fill",
                         label: "Speaker", on: calls.isSpeaker) {
                Task { await calls.toggleSpeaker() }
            }
        }
    }

    private func circleToggle(icon: String, label: LocalizedStringKey,
                              on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(on ? theme.bg : theme.text)
                    .frame(width: 64, height: 64)
                    .background(on ? theme.text : theme.chipBg, in: .circle)
                Text(label)
                    .font(RFont.text(11, weight: .medium))
                    .foregroundStyle(theme.text2)
            }
            .contentShape(.rect)
        }
        .pressable(0.92)
    }

    /// Always visible, never behind the keypad toggle. The one control a user
    /// must be able to find without looking.
    private var endButton: some View {
        VStack(spacing: 12) {
            if showKeypad {
                Button {
                    RHaptic.select()
                    withAnimation(RMotion.panel) { showKeypad = false }
                } label: {
                    Text("Hide keypad")
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .pressable(0.95)
            }

            Button {
                Task { await calls.endCall() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(theme.fail, in: .circle)
                    .contentShape(.circle)
            }
            .pressable(0.92)
            .accessibilityLabel(Text("End call"))
        }
    }
}
