import Foundation

/// Which side receives one of the Mac's dedicated keys while Omarchy is focused.
enum KeyRoute: String, Codable, CaseIterable {
    case macOS
    case omarchy
}

struct KeyboardRoutingPreferences: Equatable {
    var brightness: KeyRoute
    var missionControl: KeyRoute
    var spotlight: KeyRoute

    static let defaults = Self(brightness: .macOS, missionControl: .macOS, spotlight: .macOS)

    // An Apple keyboard in its default mode sends these caps as plain key
    // events with dedicated keycodes, not as F-keys. With "Use F1, F2, etc.
    // as standard function keys" enabled they arrive as F-keys instead and
    // are unaffected.
    static let brightnessKeycodes = [144, 145]
    static let missionControlKeycodes = [160]
    static let spotlightKeycodes = [131]

    /// Keycodes that stay with macOS, in the order the launcher publishes them.
    var hostKeycodes: [Int] {
        var keycodes: [Int] = []
        if brightness == .macOS { keycodes += Self.brightnessKeycodes }
        if missionControl == .macOS { keycodes += Self.missionControlKeycodes }
        if spotlight == .macOS { keycodes += Self.spotlightKeycodes }
        return keycodes.sorted()
    }
}

struct KeyboardRoutingPreferenceStore {
    static let key = "keyboardRoutingPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> KeyboardRoutingPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return KeyboardRoutingPreferences(
            brightness: payload.brightness,
            missionControl: payload.missionControl,
            spotlight: payload.spotlight
        )
    }

    func save(_ preferences: KeyboardRoutingPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            brightness: preferences.brightness,
            missionControl: preferences.missionControl,
            spotlight: preferences.spotlight
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let brightness: KeyRoute
        let missionControl: KeyRoute
        let spotlight: KeyRoute
    }
}

struct KeyboardRoutingLaunchConfiguration: Equatable {
    static let hostKeysEnvironmentKey = "OMARCHY_QEMU_GPU_HOST_KEYS"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: KeyboardRoutingPreferences
    ) -> Self {
        var environment = baseEnvironment
        environment[hostKeysEnvironmentKey] = preferences.hostKeycodes
            .map(String.init)
            .joined(separator: ",")
        return Self(environment: environment)
    }
}
