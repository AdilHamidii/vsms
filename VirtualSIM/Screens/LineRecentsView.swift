import SwiftUI

/// Call history, the way a phone app does it: day headers, one row per call,
/// and the row itself is the menu.
///
/// It was a flat, untappable list of grey rows — the one screen in the product
/// where the user already knows exactly what they want to do next (call that
/// person back) and had no way to do it. Every action here starts from a number
/// that is already on screen; nothing needs typing.
///
/// The minutes meter stays at the top of THIS segment and nowhere else: it
/// meters calls, so it belongs over the calls. It sat above the segmented
/// control once and metered a subscriber's empty inbox with "78 minutes left".
struct LineRecentsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(CallController.self) private var calling

    let line: Line

    /// One expanded row at a time — an accordion, not a set. Two open rows put
    /// two "Call back" buttons on screen, and the one you tap is decided by
    /// which chunk of the list you happen to be looking at.
    @State private var expanded: String?
    @State private var naming: PeerRef?
    @State private var copied: String?

    private var calls: [LineCall] { state.callsForSelectedLine }

    var body: some View {
        Group {
            if calls.isEmpty {
                VStack(spacing: 0) {
                    strip
                    EmptyState(
                        icon: RIcon.phone,
                        title: "No calls yet",
                        message: "Calls you make from this number appear here."
                    )
                    .padding(.top, 6)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        strip.padding(.bottom, 6)
                        ForEach(days) { day in
                            dayHeader(day.date)
                            ForEach(day.calls) { call in
                                RecentRow(
                                    call: call,
                                    name: state.contactName(for: call.peerE164),
                                    isExpanded: expanded == call.id,
                                    canCall: calling.isVoiceAvailable,
                                    thread: thread(for: call.peerE164),
                                    justCopied: copied == call.id,
                                    onTap: { toggle(call) },
                                    onCallBack: { callBack(call) },
                                    onOpenThread: { open(thread(for: call.peerE164)) },
                                    onCopy: { copy(call) },
                                    onAddName: { naming = PeerRef(id: call.peerE164) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    // Clears the floating tab bar AND the dial FAB, which sits
                    // over the bottom-trailing corner of this list.
                    .padding(.bottom, 140)
                }
            }
        }
        .sheet(item: $naming) { peer in
            PeerNameSheet(e164: peer.id)
                .modifier(LineEnv(theme: theme, state: state, api: api,
                                  subs: subs, calling: calling))
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
    }

    private var strip: some View {
        // The hero header already states the renewal date and the allowance
        // resets on renewal, so the strip's own copy of it would print the same
        // date twice on one screen.
        AllowanceStrip(line: line, showsResetDate: false)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
    }

    // MARK: - Grouping

    private struct Day: Identifiable {
        let date: Date
        let calls: [LineCall]
        var id: Date { date }
    }

    /// Grouped by CALENDAR day of `createdAt`, newest first, preserving the
    /// order the server returned inside each day. Computed in the view because
    /// a rented line's history is tens of rows, not thousands — the catalog
    /// rule about deriving data once in `AppState` is about 18k-row tables.
    private var days: [Day] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [LineCall]] = [:]
        for call in calls {
            let key = cal.startOfDay(for: call.createdAt)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(call)
        }
        return order.map { Day(date: $0, calls: buckets[$0] ?? []) }
    }

    @ViewBuilder
    private func dayHeader(_ date: Date) -> some View {
        Group {
            if Calendar.current.isDateInToday(date) {
                Text("Today")
            } else if Calendar.current.isDateInYesterday(date) {
                Text("Yesterday")
            } else {
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            }
        }
        .font(RFont.display(12, weight: .semibold))
        .tracking(0.2)
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: - Actions

    private func thread(for peer: String) -> LineThread? {
        state.threadsForSelectedLine.first { $0.peerE164 == peer }
    }

    private func toggle(_ call: LineCall) {
        RHaptic.select()
        withAnimation(RMotion.select) {
            expanded = expanded == call.id ? nil : call.id
        }
    }

    /// Gated exactly as the FAB is: no voice client, no offer to dial. A
    /// disabled "Call back" still advertises a capability the build cannot
    /// deliver.
    private func callBack(_ call: LineCall) {
        guard calling.isVoiceAvailable else { return }
        RHaptic.select()
        state.dialerPrefill = call.peerE164
        state.flow = .dialer
    }

    private func open(_ thread: LineThread?) {
        guard let thread else { return }
        RHaptic.select()
        state.openThreadId = thread.id
        state.flow = .thread
    }

    private func copy(_ call: LineCall) {
        UIPasteboard.general.string = call.peerE164
        RHaptic.select()
        withAnimation(RMotion.select) { copied = call.id }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(RMotion.select) {
                if copied == call.id { copied = nil }
            }
        }
    }
}

/// One call. Collapsed it is a phone-app row; expanded it is that row plus the
/// four things you can do with the number on it.
///
/// Expanding INLINE rather than pushing a detail screen: every action here is a
/// single tap away from the list, and a detail screen for "you called this
/// person for 42 seconds" is a navigation level that earns nothing.
private struct RecentRow: View {
    @Environment(\.theme) private var theme

    let call: LineCall
    let name: String?
    let isExpanded: Bool
    let canCall: Bool
    let thread: LineThread?
    let justCopied: Bool
    let onTap: () -> Void
    let onCallBack: () -> Void
    let onOpenThread: () -> Void
    let onCopy: () -> Void
    let onAddName: () -> Void

    private var title: String {
        name ?? PhoneFormat.compact(call.peerE164)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    PeerAvatar(e164: call.peerE164, name: name, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: title)
                            .font(RFont.text(15, weight: .semibold))
                            // Missed calls are the one thing on this screen a
                            // user scans for, so they keep the red they had.
                            .foregroundStyle(call.status.isMissed ? theme.fail : theme.text)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(call.status.isMissed ? theme.fail : theme.text3)
                            Text(subtitle)
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(call.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                    // The one action worth a permanent glyph: calling back is
                    // why anyone opens a recents list.
                    if canCall {
                        Button(action: onCallBack) {
                            Image(systemName: RIcon.phone)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.ink)
                                .frame(width: 34, height: 34)
                                .background(theme.chipBg, in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .pressable(0.9)
                    }
                }
                .padding(14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(theme.sep).frame(height: 0.5)
                    Text(verbatim: detailLine)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                    HStack(spacing: 8) {
                        if canCall {
                            action(icon: RIcon.phone, label: "Call back", tint: theme.ink,
                                   run: onCallBack)
                        }
                        if thread != nil {
                            action(icon: RIcon.message, label: "Messages",
                                   tint: theme.text, run: onOpenThread)
                        }
                        action(icon: justCopied ? RIcon.check : RIcon.copy,
                               label: justCopied ? "Copied" : "Copy",
                               tint: justCopied ? theme.live : theme.text, run: onCopy)
                        action(icon: "person.crop.circle.badge.plus",
                               label: name == nil ? "Add name" : "Rename",
                               tint: theme.text, run: onAddName)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(theme.elev, in: .rect(cornerRadius: 16))
    }

    private func action(icon: String, label: LocalizedStringKey, tint: Color,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(RFont.text(11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(theme.chipBg, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pressable(0.96)
    }

    private var icon: String {
        if call.status.isMissed { return "phone.down" }
        return call.direction == .inbound ? "phone.arrow.down.left" : "phone.arrow.up.right"
    }

    private var subtitle: String {
        if call.status.isMissed { return String(localized: "Missed") }
        // A completed call with no duration yet is waiting on the CDR, which
        // arrives minutes later. Saying "0:00" would claim a zero-length call.
        guard let s = call.displaySeconds, s > 0 else {
            return call.direction == .inbound
                ? String(localized: "Incoming") : String(localized: "Outgoing")
        }
        return PhoneFormat.duration(s)
    }

    /// The expanded row states the exact time, the full number and the duration
    /// when the CDR has landed — the three things the collapsed row rounds off.
    private var detailLine: String {
        var parts: [String] = [
            call.createdAt.formatted(date: .abbreviated, time: .shortened),
            PhoneFormat.national(call.peerE164),
        ]
        if let s = call.displaySeconds, s > 0 {
            parts.append(PhoneFormat.duration(s))
        }
        return parts.joined(separator: " · ")
    }
}
