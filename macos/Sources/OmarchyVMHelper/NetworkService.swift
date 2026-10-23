import AppKit
import ServiceManagement

@MainActor
enum NetworkService {
    static let service = SMAppService.daemon(plistName: NetworkServiceLayout.fullAppJobName)
    private static var layout: NetworkServiceLayout { NetworkServiceLayout(bundle: .main) }

    static var statusText: String {
        switch service.status {
        case .enabled: return "Networking helper approved"
        case .requiresApproval: return "Networking helper needs approval in System Settings"
        case .notRegistered: return "One-time networking helper setup required"
        case .notFound: return "Networking helper has not been registered with macOS"
        @unknown default: return "Networking helper status is unavailable"
        }
    }

    static func prepare() throws {
        if service.status == .notRegistered || service.status == .notFound {
            guard layout.registration == .thisApp else {
                throw HelperError.io("Networking helper is missing from this app.")
            }
            do { try service.register() } catch {
                if service.status != .requiresApproval && service.status != .enabled {
                    let detail = error as NSError
                    throw HelperError.io("macOS could not register the networking helper (\(detail.domain), \(detail.code)): \(detail.localizedDescription)")
                }
            }
        }
        guard service.status == .enabled else {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw HelperError.io("Approve Try Omarchy’s networking helper in System Settings → General → Login Items & Extensions, then launch again. This approval is needed once, not on every launch.")
            }
            throw HelperError.io(statusText)
        }
    }

    static func verifyConnection() throws {
        guard let client = layout.client, let resources = layout.resources else {
            throw HelperError.io("Networking helper is missing from this app.")
        }
        if let problem = NetworkServiceCheck.run(client: client, resources: resources) { throw HelperError.io(problem) }
    }

    static func remove() async throws {
        if service.status != .notRegistered && service.status != .notFound { try await service.unregister() }
    }

    static func repair() async throws {
        try await repair(isEnabled: service.status == .enabled,
                         prepare: prepare, verify: verifyConnection, remove: remove)
    }

    static func repair(isEnabled: Bool, prepare: () throws -> Void,
                       verify: () throws -> Void, remove: () async throws -> Void) async throws {
        if isEnabled {
            do {
                try verify()
                return
            } catch {
                try await remove()
            }
        }
        try prepare()
        try verify()
    }
}

/// The networking helper as the settings window shows it. The full app sets
/// it up and removes it; under another app the window only reports what the
/// start found, because that app registers the helper as itself.
struct NetworkServiceControls {
    let status: @MainActor () -> String
    let isReady: @MainActor () -> Bool
    let repair: (@MainActor () async throws -> Void)?
    let remove: (@MainActor () async throws -> Void)?

    static var thisApp: Self {
        Self(status: { NetworkService.statusText },
             isReady: { NetworkService.service.status == .enabled },
             repair: { try await NetworkService.repair() },
             remove: { try await NetworkService.remove() })
    }

    /// `started` is what this start found; `current` what the daemon says
    /// now, once asked again. Both are read each time the window shows them.
    static func forRunMode(layout: NetworkServiceLayout, productName: String,
                           started: @escaping @MainActor () -> BridgedNetworkAvailability?,
                           current: @escaping @MainActor () -> BridgedNetworkAvailability?) -> Self {
        if layout.registration == .thisApp { return .thisApp }
        let embedded = layout.registration == .embeddingApp
        @MainActor func state() -> (status: String, ready: Bool) {
            guard embedded else { return ("Bridged networking is not available in \(productName).", false) }
            switch current() ?? started() {
            case .available:
                return started() == .available
                    ? ("Networking helper ready", true)
                    : ("Networking helper ready. Omarchy uses it from the next start.", true)
            case .unavailable(let reason):
                return (reason, false)
            case nil:
                return ("\(productName) sets up the networking helper. Until macOS approves it, Omarchy starts with shared networking.", false)
            }
        }
        return Self(status: { state().status }, isReady: { state().ready }, repair: nil, remove: nil)
    }
}
