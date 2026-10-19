import CoreBluetooth
import Foundation

enum AutoConnectCoordinator {
    static func configure(controller: ScooterController) {
        controller.bluetoothBootstrap = { c in
            c.refreshSavedScooterFromStore()
            guard c.autoConnectEnabled, let fav = c.savedFavorite else {
                c.startScan()
                return
            }
            c.status = "Looking for \(fav.displayName)…"
            if let peripheral = c.retrievePeripheral(id: fav.id) {
                c.connect(peripheral)
                return
            }
            c.startScan()
        }

        controller.shouldAutoConnect = { id, _ in
            guard controller.autoConnectEnabled,
                  let fav = controller.savedFavorite,
                  id == fav.id,
                  !controller.isConnected else { return false }
            return true
        }
    }
}
