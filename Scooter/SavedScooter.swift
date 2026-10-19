import Foundation

struct SavedScooter: Codable, Equatable {
    let id: UUID
    var displayName: String
    var savedAt: Date
}

final class SavedScooterStore {
    static let shared = SavedScooterStore()

    private let favoriteKey = "scooter.favorite"
    private let autoConnectKey = "scooter.autoConnect"

    var autoConnectEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoConnectKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoConnectKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoConnectKey) }
    }

    func loadFavorite() -> SavedScooter? {
        guard let data = UserDefaults.standard.data(forKey: favoriteKey) else { return nil }
        return try? JSONDecoder().decode(SavedScooter.self, from: data)
    }

    func saveFavorite(_ scooter: SavedScooter) {
        guard let data = try? JSONEncoder().encode(scooter) else { return }
        UserDefaults.standard.set(data, forKey: favoriteKey)
    }

    func clearFavorite() {
        UserDefaults.standard.removeObject(forKey: favoriteKey)
    }
}
