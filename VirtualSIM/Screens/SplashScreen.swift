import SwiftUI

/// What the splash is currently covering.
///
/// `indeterminate` is the session bootstrap in `AuthGate`: a Keychain read and
/// at most one token refresh, with no countable steps. `progress` is the cold
/// data load in `ContentView`, where the steps ARE countable — so the bar is
/// driven by work that actually completed rather than by a timer. A synthetic
/// bar that fills on a schedule is the same class of lie as a seeded success
/// rate: it looks like information and carries none.
enum SplashState: Equatable {
    case indeterminate
    case progress(Double)
    case failed
}

/// Cold-launch cover, shown from the first app frame until Home can render
/// something true.
///
/// WHAT IT REPLACES. `AppState` starts from `SeedData` with `routes = []`, so
/// `cost(for:country:)` returns nil for every pair — meaning the launch path
/// was: blank system launch screen → a bare `ProgressView` spinner → a Home
/// screen whose primary CTA read **"Unavailable · Pick another country"** for
/// the entire fetch. The seed default pair is WhatsApp/United States, which is
/// in `blocked_routes` and so is never bookable at all; it stayed wrong until
/// `applyStartupSelection()` ran at the very end of the chain. Measured
/// 2026-07-30: the catalog alone is 18,492 routes (3.48 MB raw, 179 KB gzipped,
/// ~0.8–1.5 s), and it is one of six sequential round-trips.
///
/// A first-run user therefore met a screen stating the product was unavailable.
/// That is expensive here specifically: activation is a single-session event —
/// median signup → first order is 2 minutes, and exactly one user in the
/// product's history first ordered after day one.
struct SplashScreen: View {
    @Environment(\.theme) private var theme

    var state: SplashState = .indeterminate
    var onRetry: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil

    /// Drives the glow breath.
    @State private var animating = false
    /// Two escalating delays. A slow launch should say so, but a fast one must
    /// never flash reassurance on and off — so both are armed on a timer and
    /// only ever fire if we are still on screen.
    @State private var slow = false        // ~1.2s: show the progress bar
    @State private var verySlow = false    // ~3.5s: say it out loud

    private let barWidth: CGFloat = 132

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                lockup
                Spacer()
                // minHeight, NOT height: the loading footer reserves enough
                // room that the lockup does not jump when the slow-connection
                // line fades in, while the failure footer — title, body, a
                // button and a link — is free to grow past it. Pinned at a flat
                // 96 it overflowed the safe area and pushed "Continue anyway"
                // onto the screen edge.
                footer
                    .frame(minHeight: 96, alignment: .top)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 28)
        }
        .onAppear {
            // `repeatForever` has to start after the first frame or the initial
            // state is what renders.
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                animating = true
            }
        }
        .task {
            // 1.2s ≈ the measured healthy launch, so a normal cold start shows
            // the wordmark animation and nothing else.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.3)) { slow = true }
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            withAnimation(.easeOut(duration: 0.3)) { verySlow = true }
        }
    }

    // MARK: - Mark

    /// The mark IS the loading indicator — see `BrandWordmark`. The letters
    /// write on, then the `v` spins for as long as we are still fetching, so
    /// there is no spinner competing with the logo for the same job.
    private var lockup: some View {
        ZStack {
            // The breathing accent halo that sat behind the mark was removed
            // with every other glow app-wide (owner request, 2026-08-27). The
            // spinning `v` alone is the "working" signal.
            //
            // Static in the failure state: a logo still cheerfully spinning
            // under the words "Couldn't reach the server" would be absurd.
            BrandWordmark(size: 46, spins: state != .failed)
        }
        .frame(height: 150)
    }

    // MARK: - Footer

    /// On a healthy launch this stays EMPTY — the spinning `v` already says
    /// "loading", and stacking a bar under it is the same information twice.
    /// The bar earns its place only once the wait is long enough that "is this
    /// moving at all?" becomes a real question.
    @ViewBuilder
    private var footer: some View {
        switch state {
        case .failed:
            failure
        case .indeterminate:
            // Session bootstrap: a Keychain read and maybe one refresh. There
            // are no countable steps, so there is nothing honest to draw.
            caption
        case .progress(let value):
            VStack(spacing: 14) {
                if slow { progressBar(value) }
                caption
            }
        }
    }

    /// Determinate: filled by steps that finished. See `AppState.coldStart`.
    private func progressBar(_ value: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.sep)
                .frame(width: barWidth, height: 3)
            Capsule().fill(theme.ink)
                .frame(width: barWidth * max(0.04, min(1, value)), height: 3)
        }
        .animation(.easeOut(duration: 0.45), value: value)
    }

    private var caption: some View {
        Text("Still loading. A slow connection can take a moment.")
            .font(RFont.text(12))
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.text3)
            .opacity(verySlow ? 1 : 0)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The catalog is the one fetch Home cannot render truthfully without, so
    /// its failure gets a real screen.
    ///
    /// Failing silently is what used to happen — `loadCatalog` swallowed the
    /// error and left the seed catalog in place, so an offline launch showed a
    /// full Home screen on which every single service read "Unavailable". That
    /// is indistinguishable from "this product is broken". Saying we could not
    /// reach the server is both true and far less damaging.
    private var failure: some View {
        VStack(spacing: 10) {
            Text("Couldn't reach the server")
                .font(RFont.display(15, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Check your connection and try again.")
                .font(RFont.text(12))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)

            if let onRetry {
                PrimaryButton(label: "Try again", icon: RIcon.refresh, action: onRetry)
                    .padding(.top, 4)
            }
            // Never trap the user behind a failed fetch: orders, credits and
            // account still work off already-fetched data.
            if let onContinue {
                Button(action: onContinue) {
                    Text("Continue anyway")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
