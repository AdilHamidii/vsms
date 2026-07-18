import SwiftUI
import CoreImage.CIFilterBuiltins

struct EsimDetailScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    let order: EsimOrder
    @State private var copied = false

    /// Prefer the live copy in state (usage updates flow in there).
    private var live: EsimOrder { state.activeEsimOrder ?? order }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    header
                    if let lpa = live.activationCode, !lpa.isEmpty {
                        qrCard(lpa)
                        manualCard
                    } else {
                        provisioningCard
                    }
                    if live.dataTotalMb != nil { usageCard }
                }
                .padding(.top, 6).padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            await state.refreshEsimUsage(using: EsimOrdersAPI(client: api))
            while !Task.isCancelled, state.flow == .esimDetail {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await state.refreshEsimUsage(using: EsimOrdersAPI(client: api))
            }
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
                    Button { installDirect(lpa) } label: {
                        Text("Install eSIM").font(RFont.display(16, weight: .semibold))
                            .foregroundStyle(theme.onInk).frame(maxWidth: .infinity).frame(height: 50)
                            .background(theme.ink, in: .rect(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
                Text("Settings → Cellular → Add eSIM → Use QR Code, or tap Install.")
                    .font(RFont.text(12)).foregroundStyle(theme.text3).multilineTextAlignment(.center)
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
        let s = "SM-DP+: \(live.smdp ?? "")\nActivation code: \(live.manualCode ?? "")"
        UIPasteboard.general.string = s
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
    }

    private func installDirect(_ lpa: String) {
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
