import SwiftUI
import MapKit

/// Pick a destination by pointing at it.
///
/// The catalog is 66 countries and **35 of them are European**, so at world
/// zoom a naive one-pin-per-country map is a solid blob over Europe with a
/// handful of legible pins everywhere else — strictly worse than the list it
/// was meant to improve on. Pins are therefore clustered against the live
/// camera span: zoomed out you get a few counted bubbles, zoomed in you get
/// individual flags, and the transition happens as you pinch.
///
/// Clustering is done here rather than with `MKClusterAnnotation` because that
/// belongs to the UIKit `MKMapView` annotation pipeline; SwiftUI's `Map` +
/// `Annotation` has no equivalent, and bridging a `UIViewRepresentable` just
/// for clustering would drag the whole annotation-view lifecycle back in.
struct EsimMapView: View {
    @Environment(\.theme) private var theme

    let countries: [EsimCountryEntry]
    let onSelect: (EsimCountryEntry) -> Void

    /// Opening view: as much of the catalog as a portrait phone can honestly show.
    ///
    /// MapKit aspect-**fills** a requested region rather than fitting it, so on
    /// a 0.46-aspect phone screen the full world is simply not reachable in flat
    /// mode — `MKMapRect.world` matched the view's height and cropped longitude
    /// to roughly 140°, and a 120°×150° region cropped to about 60° over Africa.
    /// Rather than fight that, this centres on the densest part of the catalog:
    /// 35 of the 66 countries are European. Everything else is one pinch away,
    /// and the globe button returns here.
    private static let world = MapCameraPosition.region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30, longitude: 20),
                           span: MKCoordinateSpan(latitudeDelta: 150, longitudeDelta: 150)))

    @State private var camera: MapCameraPosition = EsimMapView.world
    @State private var span = MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)
    @State private var selected: EsimCountryEntry?

    // MARK: - Pins

    private struct Pin: Identifiable {
        let entry: EsimCountryEntry
        let coord: CLLocationCoordinate2D
        var id: String { entry.code }
    }

    private struct Cluster: Identifiable {
        let id: String
        let coord: CLLocationCoordinate2D
        let members: [Pin]
        var isSingle: Bool { members.count == 1 }
    }

    private var pins: [Pin] {
        countries.compactMap { c in
            guard let coord = CountryGeo.centroid(c.code) else { return nil }
            return Pin(entry: c, coord: coord)
        }
    }

    /// Countries we sell but cannot place. Surfaced in the UI rather than
    /// dropped quietly — see `CountryGeo.missingCodes`.
    private var unplaced: [String] {
        CountryGeo.missingCodes(in: countries.map(\.code))
    }

    /// Grid-bucket the pins at a cell size derived from the current zoom.
    ///
    /// Dividing by 7 gives roughly seven cells across the visible width, which
    /// keeps bubbles far enough apart to be tappable at any zoom without
    /// collapsing distinct countries the user has already zoomed in to separate.
    private var clusters: [Cluster] {
        let cell = max(span.latitudeDelta, span.longitudeDelta) / 7
        guard cell > 0.01 else {                       // fully zoomed in: no clustering
            return pins.map { Cluster(id: $0.id, coord: $0.coord, members: [$0]) }
        }
        var buckets: [String: [Pin]] = [:]
        for p in pins {
            let key = "\(Int((p.coord.latitude / cell).rounded()))|\(Int((p.coord.longitude / cell).rounded()))"
            buckets[key, default: []].append(p)
        }
        return buckets.map { key, members in
            let lat = members.map(\.coord.latitude).reduce(0, +) / Double(members.count)
            let lon = members.map(\.coord.longitude).reduce(0, +) / Double(members.count)
            // Sorted members give the bubble a stable identity, so SwiftUI does
            // not tear down and rebuild every annotation on an unrelated redraw.
            return Cluster(id: key,
                           coord: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           members: members.sorted { $0.entry.code < $1.entry.code })
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                ForEach(clusters) { cluster in
                    // Empty title on purpose: the pin already carries the flag
                    // and price, and MapKit's own label would sit under it as a
                    // duplicate. (`.annotationTitles(.hidden)` is a MapContent
                    // modifier, not a View one — it does not apply to `Map`.)
                    Annotation("", coordinate: cluster.coord, anchor: .center) {
                        if cluster.isSingle, let pin = cluster.members.first {
                            singlePin(pin)
                        } else {
                            bubble(cluster)
                        }
                    }
                }
            }
            // Roads, labels and points of interest are pure noise when the map
            // is a country picker — nothing on it is navigable.
            .mapStyle(.standard(elevation: .flat,
                                pointsOfInterest: .excludingAll,
                                showsTraffic: false))
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .continuous) { ctx in
                span = ctx.region.span
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                if let selected { selectionCard(selected) }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
    }

    // MARK: - Annotations

    private func singlePin(_ pin: Pin) -> some View {
        let isSelected = selected?.code == pin.entry.code
        return Button {
            withAnimation(RMotion.select) { selected = pin.entry }
            fly(to: pin.coord, span: MKCoordinateSpan(latitudeDelta: 14, longitudeDelta: 14))
        } label: {
            VStack(spacing: 2) {
                CodeFlag(code: pin.entry.code, size: isSelected ? 40 : 30)
                    .overlay(Circle().stroke(isSelected ? theme.ink : theme.elev,
                                             lineWidth: isSelected ? 2.5 : 1.5))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
                // The unit is NOT optional here. Without it this badge read
                // "33" in the same weight and size as a cluster bubble reading
                // "13", so a price and a country count were indistinguishable —
                // on the same map, at the same time.
                Text("\(pin.entry.fromCredits) cr")
                    .font(RFont.mono(9.5, weight: .bold))
                    .foregroundStyle(isSelected ? theme.onInk : theme.text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(isSelected ? theme.ink : theme.elev, in: .capsule)
                    .overlay(Capsule().stroke(theme.sep, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            }
            .scaleEffect(isSelected ? 1.0 : 0.94)
        }
        .buttonStyle(.plain)
        .animation(RMotion.select, value: isSelected)
    }

    private func bubble(_ cluster: Cluster) -> some View {
        let n = cluster.members.count
        // Grows with density but flattens fast — a linear scale makes a
        // 35-country European bubble swallow the continent.
        let d: CGFloat = 30 + min(18, CGFloat(n) * 1.4)
        return Button {
            zoomToFit(cluster.members)
        } label: {
            ZStack {
                Circle().fill(theme.ink.opacity(0.92))
                Circle().stroke(theme.onInk.opacity(0.55), lineWidth: 1.5)
                Text("\(n)")
                    .font(RFont.display(d * 0.36, weight: .bold))
                    .foregroundStyle(theme.onInk)
            }
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection card

    private func selectionCard(_ entry: EsimCountryEntry) -> some View {
        Button { onSelect(entry) } label: {
            HStack(spacing: 12) {
                CodeFlag(code: entry.code, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(RFont.display(17, weight: .semibold)).tracking(-0.3)
                        .foregroundStyle(theme.text)
                    Text(entry.planCount == 1 ? "1 plan" : "\(entry.planCount) plans")
                        .font(RFont.text(12)).foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("from").font(RFont.text(10)).foregroundStyle(theme.text3)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(entry.fromCredits)")
                            .font(RFont.display(18, weight: .bold)).foregroundStyle(theme.text)
                        Text("cr").font(RFont.text(12, weight: .medium)).foregroundStyle(theme.text2)
                    }
                }
                Image(systemName: RIcon.chev)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text3)
            }
            .padding(14)
            .background(theme.elev, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.sep, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !unplaced.isEmpty {
                // Honest about its own gaps rather than looking complete.
                Label("\(unplaced.count) not on map — use the list",
                      systemImage: "exclamationmark.circle")
                    .font(RFont.text(11)).foregroundStyle(theme.text2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.elev.opacity(0.92), in: .capsule)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(RMotion.select) { selected = nil }
                withAnimation(RMotion.camera) { camera = EsimMapView.world }
            } label: {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .background(theme.elev.opacity(0.95), in: .circle)
                    .overlay(Circle().stroke(theme.sep, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset map")
        }
    }

    // MARK: - Camera

    private func fly(to coord: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        withAnimation(RMotion.camera) {
            camera = .region(MKCoordinateRegion(center: coord, span: span))
        }
    }

    /// Zoom so every member of a tapped bubble is comfortably in frame.
    private func zoomToFit(_ members: [Pin]) {
        guard !members.isEmpty else { return }
        let lats = members.map(\.coord.latitude), lons = members.map(\.coord.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        // 1.6× padding, and a floor so a bubble of two near-identical points
        // (Hong Kong and Singapore, say) does not zoom to street level.
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: max(6, (maxLat - minLat) * 1.6),
                                   longitudeDelta: max(6, (maxLon - minLon) * 1.6)))
        withAnimation(RMotion.camera) { camera = .region(region) }
    }
}
