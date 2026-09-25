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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var state: SplashState = .indeterminate
    /// The app is ready: hand off. The background fades while the wordmark
    /// glides up and out (`RMotion.handoff`); under Reduce Motion it is a plain
    /// crossfade. Taps pass through from the first frame of the handoff — the
    /// first screen never waits on this animation.
    var revealing: Bool = false
    /// Screenshot fixtures only (`splash`, `splashSlow`): hold one frame
    /// instead of running the timers and the breath. nil in every real launch.
    var pinned: SplashPin? = nil
    var onRetry: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil

    /// Two escalating delays. A slow launch should say so, but a fast one must
    /// never flash reassurance on and off — so both are armed on a timer and
    /// only ever fire if we are still on screen. There is ONE splash per
    /// launch (see `LaunchCover`), so both count from the first frame of the
    /// app, not from whichever phase happens to be loading.
    @State private var slow = false        // ~1.5s: show the progress line
    @State private var verySlow = false    // ~3.5s: say it out loud

    /// Room held under the wordmark for the loading footer: the gap, the
    /// hairline, a second gap and two caption lines. The same amount is
    /// reserved ABOVE the wordmark, so on a loading launch it sits at the
    /// exact centre and never moves when the line or the caption fades in.
    private let footerReserve: CGFloat = 80

    /// How far the wordmark travels up as it hands off.
    private let glide: CGFloat = 40

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // minHeight, NOT height, below: the failure footer — title,
                // body and two buttons — is far taller than the reserve and
                // must be free to grow. It is not mirrored above, so the
                // wordmark rises instead of the buttons being pushed onto the
                // bottom edge (a flat 96 once pushed "Continue anyway" there).
                if state != .failed {
                    Color.clear.frame(height: footerReserve)
                }
                lockup
                    .offset(y: revealing && !reduceMotion ? -glide : 0)
                footer
                    .padding(.top, RSpace.xl)
                    .frame(minHeight: footerReserve, alignment: .top)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RSpace.xxl)
            .padding(.bottom, RSpace.xl)
            // The foreground (mark, line, caption) fades FASTER than the
            // cover. At one shared opacity the background vanishes into the
            // identical screen colour behind it by mid-fade while the glyphs,
            // still half-opaque, ghost over the store's cards — seen in a
            // recording of `-screenshot splashHandoff`. Scoped to the opacity,
            // so the glide keeps `RMotion.handoff`.
            .animation(RMotion.content) { content in
                content.opacity(revealing ? 0 : 1)
            }
        }
        // The whole cover fades: under Reduce Motion that IS the handoff (a
        // crossfade onto the first screen, whose rise-in is also off).
        .opacity(revealing ? 0 : 1)
        .animation(RMotion.handoff, value: revealing)
        .allowsHitTesting(!revealing)
        .accessibilityHidden(revealing)
        // Keyed on `pinned`: a fixture's pin arrives with `ContentView`'s
        // first report, after this instance was created for the bootstrap.
        .task(id: pinned) {
            switch pinned {
            case .calm:
                slow = false
                verySlow = false
                return
            case .slow, .failed:
                slow = true
                verySlow = true
                return
            case nil:
                break
            }
            // 1.5s: past a healthy launch, so a normal cold start shows the
            // breathing wordmark and nothing else.
            //
            // `do`/`return`, never `try?`: a cancelled sleep throws at once,
            // and `try?` would fall straight through and show the line and
            // the caption the instant the task is replaced (a fixture's pin
            // arriving is exactly that).
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeOut(duration: 0.3)) { slow = true }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) { verySlow = true }
            } catch {
                return
            }
        }
    }

    // MARK: - Mark

    /// The mark IS the loading indicator — see `BrandWordmark`. It is drawn in
    /// full on the first frame and breathes while we are still fetching, so
    /// there is no spinner competing with the logo for the same job.
    ///
    /// Still in the failure state: a logo cheerfully pulsing under the words
    /// "Couldn't reach the server" would read as "still trying". Still in a
    /// pinned fixture too, so a frame never catches it mid-breath — except
    /// `splashFailed`, whose pin deliberately leaves breathing to the STATE,
    /// so its frames prove the failure state is what stops it.
    private var lockup: some View {
        BrandWordmark(size: 46, breathes: state != .failed && (pinned == nil || pinned == .failed))
    }

    // MARK: - Footer

    /// On a healthy launch this stays EMPTY — the breathing wordmark already
    /// says "loading", and stacking a line under it is the same information
    /// twice.
    /// The bar earns its place only once the wait is long enough that "is this
    /// moving at all?" becomes a real question.
    @ViewBuilder
    private var footer: some View {
        switch state {
        case .failed:
            failure
        case .indeterminate:
            // Session bootstrap: a Keychain read and maybe one refresh. There
            // are no countable steps, so the track stays empty rather than
            // showing a fill that would claim progress.
            loading(nil)
        case .progress(let value):
            loading(value)
        }
    }

    /// The hairline's slot is held even before it fades in at ~1.5s, so the
    /// caption under it never shifts.
    private func loading(_ fraction: Double?) -> some View {
        VStack(spacing: RSpace.lg) {
            hairline(fraction)
                .opacity(slow ? 1 : 0)
            caption
        }
    }

    /// A 2pt track under the wordmark. Determinate: filled by steps that
    /// finished (see `AppState.coldStart`), floored at 4% so a started load
    /// is never an empty track. Indeterminate (`nil`): the empty track only —
    /// with no countable steps, any fill would claim progress that is not
    /// happening, the same lie as a bar filled on a timer.
    private func hairline(_ fraction: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                if let fraction {
                    Capsule()
                        .fill(theme.ink)
                        .frame(width: geo.size.width * max(0.04, min(1, fraction)))
                        .animation(RMotion.value, value: fraction)
                }
            }
        }
        .frame(width: 120, height: 2)
        .accessibilityHidden(true)
    }

    private var caption: some View {
        Text("Still loading. A slow connection can take a moment.")
            .font(RFont.text(13))
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
        VStack(spacing: RSpace.sm) {
            Text("Couldn't reach the server")
                .font(RFont.display(15, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Check your connection and try again.")
                .font(RFont.text(13))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)

            VStack(spacing: RSpace.md) {
                if let onRetry {
                    PrimaryButton(label: "Try again", icon: RIcon.refresh, action: onRetry)
                }
                // Never trap the user behind a failed fetch: orders, credits
                // and account still work off already-fetched data.
                if let onContinue {
                    GhostButton(label: "Continue anyway", action: onContinue)
                }
            }
            .padding(.top, RSpace.lg)
        }
    }
}

/// A screenshot fixture's frozen splash. `calm` is a healthy launch (the mark
/// alone); `slow` is past both timers (the line and the caption showing).
enum SplashPin: Equatable {
    case calm
    case slow
    /// The failure footer (`splashFailed`), held so a burst of stills can
    /// show the mark has stopped breathing.
    case failed
}

// MARK: - One splash per launch

/// What the launch cover is doing: still covering the app (with the splash
/// state to draw), or handing off because the first screen is ready.
struct LaunchCoverPhase: Equatable {
    var state: SplashState
    var revealed: Bool
    /// `bootPhase == .ready`, which never goes back (only the failure
    /// footer's Try again re-runs `coldStart`). A handoff onto MAINTENANCE is
    /// revealed but not settled: the cover may still have to come back.
    var settled: Bool = false
    var pinned: SplashPin? = nil

    static let bootstrapping = LaunchCoverPhase(state: .indeterminate, revealed: false)
}

/// The signed-in app's half of the cover, published by `ContentView` (which
/// owns `AppState` and therefore `bootPhase`) up to `AuthGate`, which hosts
/// the one splash. The closures ride along because only `ContentView` holds
/// what Try again / Continue anyway act on — and ONLY in the failure state:
/// a fresh closure per `ContentView` body would make every report differ from
/// the last, so `AuthGate`'s overlay would re-run on every update. Without
/// them the report is a plain value that stops changing once the app is ready.
struct LaunchCoverReport {
    var phase: LaunchCoverPhase
    var onRetry: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil
}

struct LaunchCoverKey: PreferenceKey {
    static var defaultValue: LaunchCoverReport? { nil }
    static func reduce(value: inout LaunchCoverReport?, nextValue: () -> LaunchCoverReport?) {
        value = nextValue() ?? value
    }
}

/// The ONE splash of a launch, hosted by `AuthGate` above both the session
/// bootstrap and `ContentView`'s cold chain.
///
/// 🔴 **Why it lives here and not in either phase.** Until 2026-09-24 there
/// were two `SplashScreen`s: `AuthGate` showed one while `session.bootstrap()`
/// ran, and `ContentView` overlaid a NEW one until `bootPhase == .ready`. The
/// second started from scratch, so the wordmark's type-on replayed and its
/// spin restarted at the exact moment the app was getting somewhere. One
/// instance, fed by whichever phase is current, is the smallest change that
/// makes that impossible: the view's identity survives the bootstrap →
/// signed-in swap, so the breath, the 1.5s / 3.5s timers and the line all
/// carry straight through.
///
/// It stays mounted through the handoff and unmounts exactly
/// `RMotion.handoffSeconds` later; hit-testing is off from the first frame of
/// the handoff, so nothing on the first screen waits for it.
struct LaunchCover: View {
    let phase: LaunchCoverPhase
    var onRetry: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil
    /// Called once the cover has unmounted after a SETTLED handoff, so
    /// `AuthGate` can latch it off for the rest of the session.
    var onFinished: () -> Void = {}

    @State private var mounted = true
    /// The last state drawn while covering. The handoff keeps drawing it, so
    /// "Continue anyway" fades the failure footer out rather than swapping it
    /// for the loading footer mid-fade (which would also move the mark).
    @State private var lastCovering: SplashState = .indeterminate

    var body: some View {
        ZStack {
            if mounted {
                SplashScreen(
                    state: phase.revealed ? lastCovering : phase.state,
                    revealing: phase.revealed,
                    pinned: phase.pinned,
                    onRetry: onRetry,
                    onContinue: onContinue
                )
                // Only ever seen on a REMOUNT (below): the first mount is
                // already on screen, and the unmount happens after the cover
                // has faded to nothing.
                .transition(.opacity)
            }
        }
        .onChange(of: phase, initial: true) { _, phase in
            if !phase.revealed { lastCovering = phase.state }
        }
        .task(id: phase.revealed) {
            // Covering again (maintenance ended mid-load): fade back in, as
            // the pre-2026-09-24 overlay did.
            guard phase.revealed else {
                if !mounted {
                    withAnimation(RMotion.handoff) { mounted = true }
                }
                return
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(RMotion.handoffSeconds * 1_000_000_000))
            } catch {
                return  // covering again before the handoff finished
            }
            mounted = false
            if phase.settled { onFinished() }
        }
    }
}
