import SwiftUI

struct ServiceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Binding var filter: SortFilter
    var onPick: (Service) -> Void

    @State private var query: String = ""
    @State private var category: String = "Popular"

    private var matches: [Service] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = state.services.filter { s in
            q.isEmpty || s.name.lowercased().contains(q) || s.category.lowercased().contains(q)
        }
        switch filter {
        case .all:      break
        case .cheapest: list.sort { $0.cost < $1.cost }
        case .fastest:  list.sort { $0.etaSeconds < $1.etaSeconds }
        }
        return list
    }

    private var filtered: [Service] {
        if category == "Popular" { return Array(matches.prefix(10)) }
        return matches.filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a service")
            searchField
            filterRow
            list
        }
        .background(theme.bg)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: RIcon.search)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.text2)
            TextField("Search service", text: $query)
                .font(RFont.text(16))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.chipBg, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ChipButton(label: "All",      icon: RIcon.filter, active: filter == .all)     { filter = .all }
                ChipButton(label: "Cheapest", icon: RIcon.coin,   active: filter == .cheapest) { filter = .cheapest }
                ChipButton(label: "Fastest",  icon: RIcon.bolt,   active: filter == .fastest)  { filter = .fastest }
                Rectangle().fill(theme.sep).frame(width: 1, height: 18).padding(.horizontal, 4)
                ForEach(serviceCategories, id: \.self) { cat in
                    ChipButton(label: cat, active: category == cat, soft: true) {
                        category = cat
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                if filtered.isEmpty {
                    Text("No services found")
                        .font(RFont.text(14))
                        .foregroundStyle(theme.text2)
                        .padding(.vertical, 24)
                } else {
                    Card {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, s in
                                ServiceRow(service: s, isLast: idx == filtered.count - 1) {
                                    onPick(s)
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
    }
}

private struct ServiceRow: View {
    @Environment(\.theme) private var theme
    let service: Service
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ServiceLogo(service: service, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
                        HStack(spacing: 8) {
                            Text(service.category)
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                            Text("·").foregroundStyle(theme.text3)
                            Text("~\(service.etaSeconds)s avg")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                            Text("·").foregroundStyle(theme.text3)
                            Text("\(service.successRate)% delivered")
                                .font(RFont.text(12, weight: .medium))
                                .foregroundStyle(theme.live)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(service.cost)")
                            .font(RFont.display(15, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text("cr")
                            .font(RFont.text(12, weight: .medium))
                            .foregroundStyle(theme.text2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if !isLast {
                    Rectangle().fill(theme.sep).frame(height: 0.5)
                        .padding(.leading, 66)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
