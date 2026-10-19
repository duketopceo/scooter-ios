import SwiftUI

@main
struct ScooterApp: App {
    @StateObject private var controller: ScooterController
    @StateObject private var tripStore: TripStore
    @StateObject private var tripRecorder: TripRecorder

    init() {
        let store = TripStore()
        let controller = ScooterController()
        AutoConnectCoordinator.configure(controller: controller)
        _controller = StateObject(wrappedValue: controller)
        _tripStore = StateObject(wrappedValue: store)
        _tripRecorder = StateObject(wrappedValue: TripRecorder(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .environmentObject(tripStore)
                .environmentObject(tripRecorder)
        }
    }
}
