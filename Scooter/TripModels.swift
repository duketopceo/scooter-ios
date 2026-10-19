import Foundation
import CoreLocation

struct TripSample: Codable, Equatable {
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let speedKmh: Double
    let batteryPct: Int

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TripRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    var scooterName: String?
    var samples: [TripSample]

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var distanceMeters: Double {
        let coords = samples.compactMap(\.coordinate)
        guard coords.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            total += a.distance(from: b)
        }
        return total
    }

    var maxSpeedKmh: Double {
        samples.map(\.speedKmh).max() ?? 0
    }

    var averageSpeedKmh: Double {
        let moving = samples.filter { $0.speedKmh > 0.5 }
        guard !moving.isEmpty else { return 0 }
        return moving.map(\.speedKmh).reduce(0, +) / Double(moving.count)
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        samples.compactMap(\.coordinate)
    }

    func appleMapsURL() -> URL? {
        let coords = routeCoordinates
        guard let start = coords.first, let end = coords.last else { return nil }
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "saddr", value: "\(start.latitude),\(start.longitude)"),
            URLQueryItem(name: "daddr", value: "\(end.latitude),\(end.longitude)"),
            URLQueryItem(name: "dirflg", value: "w"),
        ]
        return components?.url
    }
}

enum TripFormatting {
    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
