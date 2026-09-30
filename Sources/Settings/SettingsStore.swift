import Foundation
import SwiftUI

/// Persists `AppSettings` and tells the controller when something changed.
@MainActor
@Observable
final class SettingsStore {
    private static let defaultsKey = "AppSettings"

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(settings)
        }
    }

    var onChange: ((AppSettings) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// True until the user has been through onboarding once.
    var needsOnboarding: Bool {
        get { !UserDefaults.standard.bool(forKey: "HasCompletedOnboarding") }
        set { UserDefaults.standard.set(!newValue, forKey: "HasCompletedOnboarding") }
    }
}
