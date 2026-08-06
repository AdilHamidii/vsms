import SwiftUI

/// Live support. The user types here; the owner answers from Telegram.
///
/// Polling rather than realtime: the app has no realtime channel today, adding
/// one for a handful of concurrent conversations is not worth the surface, and
/// an APNs push already wakes the user when a reply lands. 4s while the screen
/// is open is well inside what a human conversation needs.
struct SupportChatScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api

    @State private var messages: [SupportMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false
    @State private var error: String?

    private var api2: SupportAPI { SupportAPI(client: api) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Support")
            Divider().overlay(theme.sep)
            transcript
            composer
        }
        .background(theme.bg)
        .task {
            await refresh()
            loaded = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await refresh()
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if loaded && messages.isEmpty { intro }
                    ForEach(messages) { m in
                        bubble(m).id(m.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Sets expectations honestly: one person answers this, and they are not
    /// always awake. Promising "instant" would be a claim we cannot keep, which
    /// is the same failure as quoting an arrival time we never measured.
    private var intro: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.text3)
            Text("Ask us anything")
                .font(RFont.display(17, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("A real person reads these. If we're asleep you'll get a reply as soon as we're up, and you'll be notified.")
                .font(RFont.text(13))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }

    private func bubble(_ m: SupportMessage) -> some View {
        HStack {
            if m.isAgent { agentBubble(m); Spacer(minLength: 40) }
            else { Spacer(minLength: 40); userBubble(m) }
        }
    }

    private func agentBubble(_ m: SupportMessage) -> some View {
        Text(m.body)
            .font(RFont.text(14))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(theme.elev, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.sep, lineWidth: 0.5))
            .textSelection(.enabled)
    }

    private func userBubble(_ m: SupportMessage) -> some View {
        Text(m.body)
            .font(RFont.text(14))
            .foregroundStyle(theme.onInk)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(theme.ink, in: .rect(cornerRadius: 16))
            .textSelection(.enabled)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error)
                    .font(RFont.text(12))
                    .foregroundStyle(theme.fail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .font(RFont.text(15))
                    .lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(theme.chipBg, in: .rect(cornerRadius: 18))
                    .disabled(sending)

                Button(action: { Task { await send() } }) {
                    Image(systemName: RIcon.arrow)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.onInk)
                        .frame(width: 36, height: 36)
                        .background(canSend ? theme.ink : theme.text3, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .background(theme.bg)
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refresh() async {
        guard let fresh = try? await api2.messages() else { return }
        messages = fresh
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        error = nil
        do {
            try await api2.send(text)
            draft = ""
            await refresh()
        } catch {
            // Keep the draft on failure — silently clearing a message the user
            // typed and we never sent is the worst possible outcome here.
            self.error = (error as? APIError)?.userMessage
                ?? String(localized: "Couldn't send that. Please try again.")
        }
    }
}
