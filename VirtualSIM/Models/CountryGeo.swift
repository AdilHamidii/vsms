import CoreLocation

/// Approximate centroid for a country, by ISO 3166-1 alpha-2 code.
///
/// Only used to place a pin on the eSIM map. Precision genuinely does not
/// matter here — at the zoom levels where an individual country pin is visible,
/// a centroid tens of kilometres off is sub-pixel — but *presence* does: a code
/// with no entry gets no pin, and a country the user can buy would silently
/// vanish from the map while still appearing in the list. `missingCodes(in:)`
/// exists so that mismatch is assertable rather than discovered by a user.
///
/// Deliberately a static table rather than geocoding: CLGeocoder is a network
/// round-trip per country, rate-limited by Apple, and would make the map's
/// contents depend on connectivity. The catalog is 66 countries and moves when
/// the provider's does — not per launch.
enum CountryGeo {

    /// ISO2 (uppercase) → centroid.
    static let centroids: [String: CLLocationCoordinate2D] = [
        "AL": .init(latitude:  41.15, longitude:  20.17),   // Albania
        "AR": .init(latitude: -38.42, longitude: -63.62),   // Argentina
        "AT": .init(latitude:  47.52, longitude:  14.55),   // Austria
        "AU": .init(latitude: -25.27, longitude: 133.78),   // Australia
        "BA": .init(latitude:  43.92, longitude:  17.68),   // Bosnia and Herzegovina
        "BD": .init(latitude:  23.68, longitude:  90.36),   // Bangladesh
        "BE": .init(latitude:  50.50, longitude:   4.47),   // Belgium
        "BG": .init(latitude:  42.73, longitude:  25.49),   // Bulgaria
        "BO": .init(latitude: -16.29, longitude: -63.59),   // Bolivia
        "BR": .init(latitude: -14.24, longitude: -51.93),   // Brazil
        "CA": .init(latitude:  56.13, longitude: -106.35),  // Canada
        "CH": .init(latitude:  46.82, longitude:   8.23),   // Switzerland
        "CL": .init(latitude: -35.68, longitude: -71.54),   // Chile
        "CM": .init(latitude:   7.37, longitude:  12.35),   // Cameroon
        "CO": .init(latitude:   4.57, longitude: -74.30),   // Colombia
        "CY": .init(latitude:  35.13, longitude:  33.43),   // Cyprus
        "CZ": .init(latitude:  49.82, longitude:  15.47),   // Czechia
        "DE": .init(latitude:  51.17, longitude:  10.45),   // Germany
        "DK": .init(latitude:  56.26, longitude:   9.50),   // Denmark
        "EE": .init(latitude:  58.60, longitude:  25.01),   // Estonia
        "ES": .init(latitude:  40.46, longitude:  -3.75),   // Spain
        "FI": .init(latitude:  61.92, longitude:  25.75),   // Finland
        "FR": .init(latitude:  46.23, longitude:   2.21),   // France
        "GB": .init(latitude:  55.38, longitude:  -3.44),   // United Kingdom
        "GE": .init(latitude:  42.32, longitude:  43.36),   // Georgia
        "GI": .init(latitude:  36.14, longitude:  -5.35),   // Gibraltar
        "GR": .init(latitude:  39.07, longitude:  21.82),   // Greece
        "HK": .init(latitude:  22.32, longitude: 114.17),   // Hong Kong
        "HR": .init(latitude:  45.10, longitude:  15.20),   // Croatia
        "HU": .init(latitude:  47.16, longitude:  19.50),   // Hungary
        "ID": .init(latitude:  -0.79, longitude: 113.92),   // Indonesia
        "IE": .init(latitude:  53.41, longitude:  -8.24),   // Ireland
        "IL": .init(latitude:  31.05, longitude:  34.85),   // Israel
        "IT": .init(latitude:  41.87, longitude:  12.57),   // Italy
        "JP": .init(latitude:  36.20, longitude: 138.25),   // Japan
        "KE": .init(latitude:  -0.02, longitude:  37.91),   // Kenya
        "KG": .init(latitude:  41.20, longitude:  74.77),   // Kyrgyzstan
        "KH": .init(latitude:  12.57, longitude: 104.99),   // Cambodia
        "KZ": .init(latitude:  48.02, longitude:  66.92),   // Kazakhstan
        "LT": .init(latitude:  55.17, longitude:  23.88),   // Lithuania
        "LV": .init(latitude:  56.88, longitude:  24.60),   // Latvia
        "MA": .init(latitude:  31.79, longitude:  -7.09),   // Morocco
        "MD": .init(latitude:  47.41, longitude:  28.37),   // Moldova
        "MT": .init(latitude:  35.94, longitude:  14.38),   // Malta
        "MX": .init(latitude:  23.63, longitude: -102.55),  // Mexico
        "MY": .init(latitude:   4.21, longitude: 101.98),   // Malaysia
        "NL": .init(latitude:  52.13, longitude:   5.29),   // Netherlands
        "NZ": .init(latitude: -40.90, longitude: 174.89),   // New Zealand
        "PH": .init(latitude:  12.88, longitude: 121.77),   // Philippines
        "PK": .init(latitude:  30.38, longitude:  69.35),   // Pakistan
        "PL": .init(latitude:  51.92, longitude:  19.15),   // Poland
        "PT": .init(latitude:  39.40, longitude:  -8.22),   // Portugal
        "PY": .init(latitude: -23.44, longitude: -58.44),   // Paraguay
        "RO": .init(latitude:  45.94, longitude:  24.97),   // Romania
        "RS": .init(latitude:  44.02, longitude:  21.01),   // Serbia
        "SE": .init(latitude:  60.13, longitude:  18.64),   // Sweden
        "SG": .init(latitude:   1.35, longitude: 103.82),   // Singapore
        "SI": .init(latitude:  46.15, longitude:  14.99),   // Slovenia
        "SK": .init(latitude:  48.67, longitude:  19.70),   // Slovakia
        "TH": .init(latitude:  15.87, longitude: 100.99),   // Thailand
        "TR": .init(latitude:  38.96, longitude:  35.24),   // Turkey
        "TZ": .init(latitude:  -6.37, longitude:  34.89),   // Tanzania
        "UA": .init(latitude:  48.38, longitude:  31.17),   // Ukraine
        "US": .init(latitude:  37.09, longitude: -95.71),   // United States
        "VN": .init(latitude:  14.06, longitude: 108.28),   // Vietnam
        "ZA": .init(latitude: -30.56, longitude:  22.94),   // South Africa
    ]

    static func centroid(_ code: String) -> CLLocationCoordinate2D? {
        centroids[code.uppercased()]
    }

    /// Catalog codes we have no pin for. The map surfaces this count rather
    /// than dropping them silently — an incomplete map that admits it is
    /// incomplete beats one that looks authoritative and isn't.
    static func missingCodes(in codes: [String]) -> [String] {
        codes.filter { centroids[$0.uppercased()] == nil }.sorted()
    }
}
