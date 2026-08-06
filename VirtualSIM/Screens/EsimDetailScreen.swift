import SwiftUI
import CoreImage.CIFilterBuiltins

struct EsimDetailScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    let order: EsimOrder
    @State private var copied = false
    @State private var showReinstallConfirm = false
    @State private var pendingLpa: String?

    /// Prefer the live copy in state (usage updates flow in there).
    private var live: EsimOrder { state.activeEsimOrder ?? order }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    header
                    // Branch on STATUS first, not on activationCode.
                    //
                    // This used to fall through to `provisioningCard` whenever
                    // there was no LPA — so a FAILED, REFUNDED or EXPIRED eSIM
                    // showed a spinner and "This usually takes a few seconds."
                    // forever, with the real state visible only as 13pt grey
                    // text in the header. Those are documented real states: the
                    // double-insert bug left orphan rows exactly like this.
                    switch live.status {
                    case .failed, .refunded:
                        terminalCard
                    case .expired, .depleted:
                        terminalCard
                    default:
                        if let lpa = live.activationCode, !lpa.isEmpty {
                            qrCard(lpa)
                            manualCard
                        } else {
                            provisioningCard
                        }
                    }
                    if live.dataTotalMb != nil, live.status != .failed, live.status != .refunded {
                        usageCard
                    }
                }
                .padding(.top, 6).padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            await state.refreshEsimUsage(using: EsimOrdersAPI(client: api))
            // Terminal orders can't change, so don't keep hitting SMSPool for
            // them — this loop calls a provider-backed edge function every 8s
            // for as long as the screen is open.
            while !Task.isCancelled, state.flow == .esimDetail, live.status.keepsPolling {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await state.refreshEsimUsage(using: EsimOrdersAPI(client: api))
            }
        }
        .confirmationDialog(
            "Install this eSIM again?",
            isPresented: $showReinstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Install again") {
                if let lpa = pendingLpa { installDirect(lpa) }
            }
            Button("Cancel", role: .cancel) { pendingLpa = nil }
        } message: {
            Text("This eSIM can only be installed once. If it's already on your device, check Settings → Cellular instead. Installing again will fail.")
        }
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)
            Spacer()
            Text("Your eSIM").font(RFont.display(16, weight: .semibold)).foregroundStyle(theme.text)
            Spacer()
            Button { state.flow = nil; state.tab = .esim } label: {
                Image(systemName: RIcon.close).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text2).frame(width: 36, height: 36).background(theme.chipBg, in: .circle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(flagEmoji(live.plan?.countryCode ?? "")).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text(live.name).font(RFont.display(18, weight: .semibold)).foregroundStyle(theme.text)
                Text("\(live.plan?.dataLabel ?? "") · \(live.plan?.validityLabel ?? "") · \(live.status.label)")
                    .font(RFont.text(13)).foregroundStyle(theme.text2)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
    }

    private func qrCard(_ lpa: String) -> some View {
        Card {
            VStack(spacing: 16) {
                Text("SCAN TO INSTALL").font(RFont.text(12, weight: .medium)).tracking(0.3).foregroundStyle(theme.text2)
                // QR must sit on white to scan reliably in any theme.
                Group {
                    if let img = Self.qrImage(from: lpa) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 200, height: 200)
                .padding(14).background(Color.white, in: .rect(cornerRadius: 16))
                if #available(iOS 17.4, *) {
                    // Second and later taps confirm first — the activation
                    // profile is single-use, so re-running a successful
                    // install just yields an opaque Apple failure.
                    Button {
                        if state.hasStartedEsimInstall(live.id) {
                            pendingLpa = lpa
                            showReinstallConfirm = true
                        } else {
                            installDirect(lpa)
                        }
                    } label: {
                        Text(state.hasStartedEsimInstall(live.id)
                             ? "Install again" : "Install eSIM")
                            .font(RFont.display(16, weight: .semibold))
                            .foregroundStyle(theme.onInk).frame(maxWidth: .infinity).frame(height: 50)
                            .background(theme.ink, in: .rect(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
                Text("Settings → Cellular → Add eSIM → Use QR Code, or tap Install.")
                    .font(RFont.text(12)).foregroundStyle(theme.text3).multilineTextAlignment(.center)

                // iOS asks for the SIM PIN DURING this flow, so it has to be
                // on screen at this moment — not buried below. Without it the
                // line never comes up and the plan looks broken.
                if let pin = live.simPin, !pin.isEmpty {
                    VStack(spacing: 4) {
                        Text("iOS will ask for a SIM PIN")
                            .font(RFont.text(12, weight: .medium)).foregroundStyle(theme.text2)
                        Text(pin)
                            .font(RFont.mono(20)).foregroundStyle(theme.text)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.chipBg, in: .rect(cornerRadius: 12))
                }
            }
            .padding(20)
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var manualCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("MANUAL INSTALL").font(RFont.text(12, weight: .medium)).tracking(0.2).foregroundStyle(theme.text2)
                labelValue("SM-DP+ Address", live.smdp ?? "—")
                labelValue("Activation Code", live.manualCode ?? "—")
                if let apn = live.apn { labelValue("APN", apn) }
                if let pin = live.simPin, !pin.isEmpty { labelValue("SIM PIN", pin) }
                if let puk = live.simPuk, !puk.isEmpty { labelValue("SIM PUK", puk) }
                Button(action: copyManual) {
                    HStack(spacing: 7) {
                        Image(systemName: copied ? RIcon.check : RIcon.copy)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(copied ? theme.live : theme.text)
                        Text(copied ? "Copied" : "Copy details").font(RFont.text(14, weight: .medium))
                            .foregroundStyle(copied ? theme.live : theme.text)
                    }
                    .frame(maxWidth: .infinity).frame(height: 44).background(theme.chipBg, in: .rect(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
            .padding(16)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    /// Terminal states get a real card naming the outcome AND the refund.
    ///
    /// The SMS side has enforced "refunds must be visible twice" since the
    /// reconcile work — in the moment (recovery card) and durably (history row).
    /// The eSIM flow had no counterpart at all: a refunded eSIM showed a
    /// spinner. `EsimOrder` has carried `costCredits` the whole time.
    private var terminalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: live.status == .failed || live.status == .refunded
                          ? "arrow.uturn.left.circle.fill" : "clock.badge.xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(live.status == .failed || live.status == .refunded
                                         ? theme.live : theme.text2)
                    Text(live.status.label)
                        .font(RFont.display(16, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                Text(terminalExplanation)
                    .font(RFont.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if live.status == .failed || live.status == .refunded {
                    HStack(spacing: 6) {
                        CoinIcon(size: 14, color: theme.live)
                        Text("+\(order.server.costCredits) credits refunded")
                            .font(RFont.text(13, weight: .semibold))
                            .foregroundStyle(theme.live)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var terminalExplanation: String {
        switch live.status {
        case .failed, .refunded:
            return String(localized: "This eSIM couldn't be provisioned, so your credits went straight back to your balance.")
        case .expired:
            return String(localized: "This plan's validity period has ended. Buy another to get back online.")
        case .depleted:
            return String(localized: "All the data on this plan has been used.")
        default:
            return ""
        }
    }

    private var provisioningCard: some View {
        Card {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Preparing your eSIM…").font(RFont.display(16, weight: .semibold)).foregroundStyle(theme.text)
                Text("This usually takes a few seconds.").font(RFont.text(13)).foregroundStyle(theme.text2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var usageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("DATA").font(RFont.text(12, weight: .medium)).tracking(0.2).foregroundStyle(theme.text2)
                    Spacer()
                    Text(live.dataRemainingLabel).font(RFont.mono(13, weight: .medium)).foregroundStyle(theme.text)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.chipBg)
                        Capsule().fill(live.dataUsedFraction >= 1 ? theme.warn : theme.live)
                            .frame(width: max(6, geo.size.width * live.dataUsedFraction))
                    }
                }
                .frame(height: 8)
                if let exp = live.expiresAt {
                    Text("Valid until \(exp.formatted(date: .abbreviated, time: .omitted))")
                        .font(RFont.text(12)).foregroundStyle(theme.text3)
                }
            }
            .padding(16)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(RFont.text(11)).foregroundStyle(theme.text3)
            Text(value).font(RFont.mono(13)).foregroundStyle(theme.text).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    private func copyManual() {
        var s = "SM-DP+: \(live.smdp ?? "")\nActivation code: \(live.manualCode ?? "")"
        // The PIN is needed to finish activation, so it belongs in the copy too
        // — a user pasting these into Settings shouldn't have to come back.
        if let pin = live.simPin, !pin.isEmpty { s += "\nSIM PIN: \(pin)" }
        if let puk = live.simPuk, !puk.isEmpty { s += "\nSIM PUK: \(puk)" }
        UIPasteboard.general.string = s
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
    }

    private func installDirect(_ lpa: String) {
        state.markEsimInstallStarted(live.id)
        let encoded = lpa.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? lpa
        if let url = URL(string: "https://esimsetup.apple.com/esim_qrcode_provisioning?carddata=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    static func qrImage(from string: String) -> UIImage? {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
