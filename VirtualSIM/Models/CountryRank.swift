import Foundation

/// HeroSMS's own success rate for one (service, country), top 10 per service.
///
/// ⚠️ THIS IS NOT OUR DELIVERY. It is the provider's aggregate across all of
/// their customers, over a 24-hour window, counting only countries with more
/// than 50 successful activations in it. Two rules follow, and both are load
/// bearing:
///
/// 1. **It never becomes a badge.** `SuccessBadge` / `DeliveryRecord` state
///    what happened to orders *we* placed — "Worked 3 of 7 times". This is a
///    third party reporting on their own inventory. Rendering them in the same
///    visual language would repeat exactly the mistake that made SMSPVA's
///    seeded per-country grade rank never-sold routes as "proven" until it had
///    to be demoted to `.notTested`. Wherever this is shown it is attributed to
///    the provider in the same breath.
///
/// 2. **Absence means nothing.** A country missing from a service's list either
///    ranked 11th or did not clear the 50-activation threshold. It is never
///    evidence of a low rate, so nothing may be demoted for lacking a rank.
///
/// What it IS good for: breaking the tie between routes we have never sold.
/// That tie-break used to be price, which is the one rule guaranteed to select
/// the least-vetted inventory in the catalog.
struct CountryRank: Codable, Hashable {
    let serviceId: String
    let countryId: String
    /// 0-100. Their number, over their traffic.
    let vendorPercent: Double
    /// 1 = best of that service's ten.
    let vendorRank: Int

    private enum CodingKeys: String, CodingKey {
        case serviceId, countryId, vendorPercent, vendorRank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serviceId = try c.decode(String.self, forKey: .serviceId)
        countryId = try c.decode(String.self, forKey: .countryId)
        vendorRank = try c.decode(Int.self, forKey: .vendorRank)
        // PostgREST renders `numeric` as a bare JSON number, but it is
        // configuration-dependent and has been seen quoted. A throw here would
        // fail the WHOLE fetch and silently cost us the steering signal, so
        // accept either and fall back rather than break.
        if let d = try? c.decode(Double.self, forKey: .vendorPercent) {
            vendorPercent = d
        } else if let s = try? c.decode(String.self, forKey: .vendorPercent),
                  let d = Double(s) {
            vendorPercent = d
        } else {
            vendorPercent = 0
        }
    }

    init(serviceId: String, countryId: String, vendorPercent: Double, vendorRank: Int) {
        self.serviceId = serviceId
        self.countryId = countryId
        self.vendorPercent = vendorPercent
        self.vendorRank = vendorRank
    }

    /// Always attributed, never bare. "43%" alone reads as the app's own
    /// measurement; this cannot.
    var attributedLabel: String {
        String(format: NSLocalizedString("Provider reports %d%%", comment: "vendor success rate"),
               Int(vendorPercent.rounded()))
    }
}
