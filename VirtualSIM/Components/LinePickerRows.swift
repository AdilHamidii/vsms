import SwiftUI

/// The rows the rented-line pickers are built from — shared by the store
/// (`LineStoreScreen`) and the number-change flow (`LineSwapSheet`), so a
/// country, a city and a candidate number look identical wherever a user is
/// choosing one.
///
/// Extracted 2026-09-05, when "Change number" gained the picker. Until then
/// every row had exactly one caller and lived privately in the store; a second
/// caller meant either a copy of ~150 lines that would drift, or this file.
///
/// Pure presentation: each row takes its model and an action. Selection
/// SEMANTICS — what a country change invalidates, which analytics fire — stay
/// with the caller, because the two flows genuinely differ there.

// MARK: - Countries

/// Flag, name, and what the number can DO.
///
/// The capability strip is the whole point of showing unsellable countries
/// at all: a voice-only country is an honest "call out" line, and a user
/// who buys one expecting texts is a refund. Green means supported, GRAY
/// means not — never red. Red is an error, and a number that simply does
/// not carry MMS is not an error.
struct LineCountryRow: View {
    @Environment(\.theme) private var theme
    let country: LineCountry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // A real flag asset rather than the emoji, at the 44pt leading
                // slot every other list row in the redesigned tab uses — the
                // emoji renders as a tofu box wherever the font lacks the pair,
                // and `CodeFlag` cascades bundled PNG → flagcdn → emoji.
                CodeFlag(code: country.countryCode, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: country.displayName)
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !country.isAvailable {
                        Text("Not available yet")
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text3)
                    }
                }
                Spacer(minLength: 8)
                LineCapabilityStrip(country: country)
                if country.isAvailable {
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .opacity(country.isAvailable ? 1 : 0.45)
        .disabled(!country.isAvailable)
        .accessibilityHint(country.isAvailable ? Text("") : Text(country.pickerHint))
    }
}

/// Four glyphs, always all four, in a fixed order. A strip that only shows
/// what IS supported reads as a feature list and hides the absence — which
/// is the thing the buyer needs to see.
struct LineCapabilityStrip: View {
    let country: LineCountry

    var body: some View {
        HStack(spacing: 9) {
            LineCapabilityIcon(symbol: "phone.fill", on: country.canVoice,
                               label: String(localized: "Calls"))
            LineCapabilityIcon(symbol: "message.fill", on: country.canSms,
                               label: String(localized: "Texts"))
            LineCapabilityIcon(symbol: "photo.fill", on: country.canMms,
                               label: String(localized: "Picture messages"))
            LineCapabilityIcon(symbol: "cross.case.fill", on: country.canEmergency,
                               label: String(localized: "Emergency calls"))
        }
    }
}

struct LineCapabilityIcon: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let on: Bool
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            // `live` is the semantic success green, and that is exactly the
            // claim being made here: this works. Absence is `text3`, the same
            // muted ink every other "nothing to report" uses.
            .foregroundStyle(on ? theme.live : theme.text3)
            .opacity(on ? 1 : 0.55)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(on ? Text("Supported") : Text("Not supported"))
    }
}

extension LineCountry {
    /// The machine key becomes a sentence HERE, never on the server. Anything
    /// unrecognised falls back to the vaguer line rather than rendering a raw
    /// key — an untranslated `documents_required` on a French phone is worse
    /// than saying less.
    var pickerHint: LocalizedStringKey {
        switch sellReason {
        case "documents_required": "Requires local registration we don't support yet"
        default:                   "Coming soon"
        }
    }
}

extension Array where Element == LineCountry {
    /// Only sellable countries count toward "is there a choice here". A list
    /// of one buyable country and eleven grayed ones is a wall of "no"
    /// standing between the user and the only thing they can actually do — so
    /// with a single sellable country the pickers open straight on the cities
    /// and the grayed rows are simply not shown anywhere.
    var sellable: [LineCountry] { filter(\.isAvailable) }

    /// Whether a country list is worth showing at all.
    var offersCountryChoice: Bool { sellable.count > 1 }

    /// Available first, then A–Z by the name the reader actually sees. Sorting
    /// by the server's English `country_name` would scramble the order on
    /// every non-English locale.
    var pickerOrder: [LineCountry] {
        sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

// MARK: - Cities

/// Cities, never area codes.
///
/// Canada's prestige codes are exhausted — 416 and 647 (Toronto), 514
/// (Montreal), 613 (Ottawa) and 403 (Calgary) all return zero stock — while
/// their overlays are full. A raw area-code picker would offer "416 —
/// Toronto" and then fail, so the server takes a CITY and walks its codes
/// in order until one has stock.
struct LineCityRow: View {
    @Environment(\.theme) private var theme
    let city: LineCity
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // The same 34pt leading slot the country rows use, so the two
                // lists read as one sequence rather than two list styles. A
                // place glyph, not a flag: every city here is in the one
                // country already chosen, so a repeated flag would be seven
                // copies of the same information.
                LinePickerTile(symbol: "mappin.and.ellipse")
                Text(city.label)
                    .font(RFont.display(16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                // The province is a disambiguator, not a second title — two
                // Ontario rows (Toronto, Ottawa) are the only reason it is on
                // screen at all. Trailing and secondary, so the column of city
                // names stays the thing the eye scans.
                Text(city.region)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 16)
            // 11 + 11 around a 34pt tile clears the 44pt minimum target with
            // room to spare; the explicit `minHeight` is what guarantees it if
            // the tile ever shrinks.
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Some countries have no curated cities — the server sells country-wide.
/// One honest row beats an empty list, which reads as "sold out".
struct LineCountryWideRow: View {
    @Environment(\.theme) private var theme
    let countryLabel: String?
    let action: () -> Void

    var body: some View {
        Card(elevation: .flat) {
            Button(action: action) {
                HStack(spacing: 12) {
                    LinePickerTile(symbol: RIcon.globe)
                    Text(countryLabel.map { String(localized: "Anywhere in \($0)") }
                         ?? String(localized: "Anywhere available"))
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 8)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 56)
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle())
        }
    }
}

/// The leading glyph slot shared by the city and country-wide rows.
///
/// Sized to match `CodeFlag(size: 34)` exactly so a list that leads with a
/// flag and a list that leads with an icon put their titles on the same
/// x-position — the thing that makes a picker feel like one screen changing
/// rather than two different lists.
struct LinePickerTile: View {
    @Environment(\.theme) private var theme
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.text2)
            .frame(width: 34, height: 34)
            .background(theme.chipBg, in: .circle)
    }
}

/// Same rhythm as the city rows it stands in for, at their height.
struct LinePickerRowSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(theme.elev)
                    .frame(height: 56)
                    .opacity(1 - Double(i) * 0.18)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Numbers

/// One candidate number, presented as a contact card.
///
/// `PeerAvatar` is the same deterministic circle the recents and thread
/// rows use, keyed on the E.164 — so the colour a user sees beside a number
/// here is the colour it keeps on the checkout hero and, once bought,
/// everywhere in the tab. That continuity is the whole reason to spend the
/// leading slot on it: it makes the number feel like a thing being adopted
/// rather than a row in a stock list.
///
/// ⚠️ **No price is rendered here, deliberately.** `monthlyCents` /
/// `upfrontCents` on this model are the WHOLESALE quote — the cost book,
/// which the app never shows a user — and the retail figure is the same on
/// every row, so printing it would be noise on top of a leak. The price is
/// stated once by the caller, on the screen immediately before payment.
struct LineOfferRow: View {
    @Environment(\.theme) private var theme
    let offer: LineNumberOffer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Card(radius: RRadius.md, elevation: .raised) {
                HStack(spacing: 13) {
                    PeerAvatar(e164: offer.phoneNumber, size: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(PhoneFormat.national(offer.phoneNumber))
                            .font(RFont.mono(18, weight: .medium))
                            .foregroundStyle(theme.text)
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                        capabilities
                    }
                    Spacer(minLength: 0)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
    }

    /// What THIS number can do, when Telnyx told us.
    ///
    /// `features` is optional on the model because the deployed server does not
    /// always send it, and an absent list means "we do not know" — never "it
    /// cannot". So the strip renders nothing at all rather than four gray
    /// glyphs, which would read as a number that does nothing. When the list IS
    /// present the same rule as the country strip applies: green means
    /// supported, gray means not, never red. The region, when the search names
    /// one, stands in when there are no features to show.
    @ViewBuilder
    private var capabilities: some View {
        if offer.features != nil {
            HStack(spacing: 9) {
                LineCapabilityIcon(symbol: "phone.fill", on: offer.supports("voice") == true,
                                   label: String(localized: "Calls"))
                LineCapabilityIcon(symbol: "message.fill", on: offer.supports("sms") == true,
                                   label: String(localized: "Texts"))
                LineCapabilityIcon(symbol: "photo.fill", on: offer.supports("mms") == true,
                                   label: String(localized: "Picture messages"))
                LineCapabilityIcon(symbol: "cross.case.fill", on: offer.supports("emergency") == true,
                                   label: String(localized: "Emergency calls"))
            }
        } else if let region = offer.region, !region.isEmpty {
            Text(verbatim: region)
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
        }
    }
}

/// Real rows at the real height, so the section does not jump when it
/// fills. A spinner gives no sense of what is coming; these do. The count
/// matches what the caller will render — a five-row skeleton resolving to
/// three rows is a collapse, which reads as something having gone wrong.
struct LineOfferSkeleton: View {
    @Environment(\.theme) private var theme
    var rows: Int = 3

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<max(rows, 1), id: \.self) { i in
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(theme.elev)
                    // Matches the contact card exactly — 42pt avatar plus 14+14
                    // of padding — so the list does not jump as it fills.
                    .frame(height: 70)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 13) {
                            Circle()
                                .fill(theme.chipBg)
                                .frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 7) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.chipBg)
                                    .frame(width: 140, height: 15)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.chipBg)
                                    .frame(width: 72, height: 10)
                            }
                        }
                        .padding(.leading, 14)
                    }
                    .opacity(1 - Double(i) * 0.15)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Nothing to sell

/// Three causes, and we only ever know one of them.
///
/// `paused` is something the server told us and can be stated outright. An
/// empty search is an observation about ONE city and nothing more — and a
/// failed fetch looks identical from here, which is why the third case
/// claims no reason at all. Same discipline as `EsimStoreScreen.emptyCatalog`.
enum LineUnavailableCopy {
    static func title(for reason: LineUnavailableReason?) -> LocalizedStringKey {
        switch reason {
        case .paused:  "Second numbers are unavailable"
        case .noStock: "No numbers here right now"
        case .countryNotSellable: "We don't sell numbers here yet"
        default:       "We couldn't load any numbers"
        }
    }

    static func body(for reason: LineUnavailableReason?) -> LocalizedStringKey {
        switch reason {
        case .paused:  "We've paused new numbers while we make some improvements. Check back soon."
        case .noStock: "Stock moves through the day. Another city will have some."
        case .countryNotSellable: "We're working on this country. Another one is ready now."
        default:       "Check your connection and try again."
        }
    }
}

// MARK: - Place labels

extension AppState {
    /// The country the user is shopping in. Reads the SEARCH's answer first —
    /// it is what the stock on screen came from — and the catalogue row only
    /// as a fallback.
    var linePlaceCountryLabel: String? {
        guard let iso = lineCountry else { return nil }
        if let c = lineSearchCountry, c.countryCode == iso { return c.displayName }
        return lineCountries.first { $0.countryCode == iso }?.displayName
            ?? Locale.current.localizedString(forRegionCode: iso)
    }

    var linePlaceCityLabel: String? {
        lineCities.first { $0.id == lineCity }?.label
    }

    /// The city when the search picked one, the country otherwise. Never an
    /// ISO code — "CA" is not a place to a reader.
    var linePlaceLabel: String? { linePlaceCityLabel ?? linePlaceCountryLabel }
}
