import CoreLocation
import Foundation

final class TripRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published var locationError: String?

    private let store: TripStore
    private weak var controller: ScooterController?
    private var sampleTimer: Timer?
    private var currentSamples: [TripSample] = []
    private var tripStart: Date?
    private var activeTripID: UUID?
    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?

    init(store: TripStore) {
        self.store = store
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
        locationManager.activityType = .otherNavigation
        locationAuthorization = locationManager.authorizationStatus
    }

    func bind(controller: ScooterController) {
        self.controller = controller
    }

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startRide() {
        guard !isRecording else { return }
        requestLocationPermission()
        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            locationError = "Allow location while using the app to record your route on the map."
            return
        }
        locationError = nil
        isRecording = true
        tripStart = Date()
        activeTripID = UUID()
        currentSamples = []
        locationManager.startUpdatingLocation()
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.captureSample()
        }
        captureSample()
    }

    func endRide() {
        guard isRecording, let start = tripStart, let id = activeTripID else { return }
        sampleTimer?.invalidate()
        sampleTimer = nil
        locationManager.stopUpdatingLocation()
        isRecording = false
        let end = Date()
        let name = controller?.savedFavorite?.displayName
            ?? controller?.telemetry.serial
        let trip = TripRecord(
            id: id,
            startedAt: start,
            endedAt: end,
            scooterName: name,
            samples: currentSamples
        )
        store.add(trip)
        currentSamples = []
        tripStart = nil
        activeTripID = nil
    }

    private func captureSample() {
        guard isRecording else { return }
        let telemetry = controller?.telemetry ?? ScooterTelemetry()
        let loc = lastLocation
        let sample = TripSample(
            timestamp: Date(),
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            speedKmh: telemetry.speedKmh,
            batteryPct: telemetry.batteryPct
        )
        currentSamples.append(sample)
    }
}

extension TripRecorder: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorization = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationError = error.localizedDescription
    }
}
