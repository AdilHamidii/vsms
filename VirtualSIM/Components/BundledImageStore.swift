import UIKit

/// Loads service logos + country flags shipped inside the app bundle so the
/// common case renders instantly with no network call.
///
/// On disk the PNGs live in `VirtualSIM/BundledLogos/<domain>.png` and
/// `VirtualSIM/BundledFlags/<code>.png`, but the Xcode file-system-synchronized
/// group flattens them into the bundle root — so lookup is by flat filename.
/// Logo keys are service domains (always contain a TLD dot) and flag keys are
/// 2-letter `Country.flagImageCode`s, so the two namespaces never collide.
///
/// Returns `nil` for anything not bundled (e.g. a service added to the catalog
/// after this build shipped) so callers fall back to the network cascade.
final class BundledImageStore {
    static let shared = BundledImageStore()

    private let cache = NSCache<NSString, UIImage>()

    private init() {}

    /// Bundled brand logo for a service `domain`, or nil if not bundled.
    func logo(forDomain domain: String?) -> UIImage? {
        guard let d = domain, !d.isEmpty else { return nil }
        return image(named: d)
    }

    /// Bundled flag for a `Country.flagImageCode` (e.g. "gb"), or nil if not bundled.
    func flag(forCode code: String) -> UIImage? {
        image(named: code)
    }

    private func image(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let key = name as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // Full "<name>.png" with withExtension:nil avoids dotted-name parsing
        // ambiguity (e.g. "whatsapp.com").
        guard let url = Bundle.main.url(forResource: "\(name).png", withExtension: nil),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
