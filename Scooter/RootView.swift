import SwiftUI

struct RootView: View {
    @EnvironmentObject private var controller: ScooterController
    @EnvironmentObject private var tripRecorder: TripRecorder

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Scooter", systemImage: "bolt.circle") }
            TripsListView()
                .tabItem { Label("Trips", systemImage: "map") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear {
            tripRecorder.bind(controller: controller)
        }
    }
}
