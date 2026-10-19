import MapKit
import SwiftUI

struct TripMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isRotateEnabled = false
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        guard coordinates.count >= 1 else { return }

        if coordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            map.addOverlay(polyline)
            map.setVisibleMapRect(polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32), animated: false)
        } else if let only = coordinates.first {
            let region = MKCoordinateRegion(center: only, latitudinalMeters: 400, longitudinalMeters: 400)
            map.setRegion(region, animated: false)
        }

        if let start = coordinates.first {
            let pin = MKPointAnnotation()
            pin.coordinate = start
            pin.title = "Start"
            map.addAnnotation(pin)
        }
        if let end = coordinates.last, coordinates.count > 1 {
            let pin = MKPointAnnotation()
            pin.coordinate = end
            pin.title = "End"
            map.addAnnotation(pin)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct TripsListView: View {
    @EnvironmentObject private var tripStore: TripStore

    var body: some View {
        NavigationView {
            Group {
                if tripStore.trips.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "map")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No trips yet")
                            .font(.headline)
                        Text("Connect to your scooter, then start a ride from the Scooter tab.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        ForEach(tripStore.trips) { trip in
                            NavigationLink {
                                TripDetailView(trip: trip)
                            } label: {
                                TripRowView(trip: trip)
                            }
                        }
                        .onDelete(perform: tripStore.delete(at:))
                    }
                }
            }
            .navigationTitle("Trips")
        }
    }
}

private struct TripRowView: View {
    let trip: TripRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.startedAt, style: .date)
                .font(.headline)
            HStack {
                Text(TripFormatting.duration(trip.duration))
                Text("·")
                Text(TripFormatting.distance(trip.distanceMeters))
                Text("·")
                Text(String(format: "max %.0f km/h", trip.maxSpeedKmh))
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if let name = trip.scooterName, !name.isEmpty {
                Text(name).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TripDetailView: View {
    let trip: TripRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TripMapView(coordinates: trip.routeCoordinates)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Group {
                    LabeledContent("Duration") { Text(TripFormatting.duration(trip.duration)) }
                    LabeledContent("Distance (GPS)") { Text(TripFormatting.distance(trip.distanceMeters)) }
                    LabeledContent("Max speed") { Text(String(format: "%.1f km/h", trip.maxSpeedKmh)) }
                    LabeledContent("Avg speed (moving)") { Text(String(format: "%.1f km/h", trip.averageSpeedKmh)) }
                    LabeledContent("Samples") { Text("\(trip.samples.count)") }
                }
                .padding(.horizontal)

                if let url = trip.appleMapsURL() {
                    Link(destination: url) {
                        Label("Open route in Apple Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                } else {
                    Text("No GPS points on this trip—stay outdoors with location enabled while riding.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}
