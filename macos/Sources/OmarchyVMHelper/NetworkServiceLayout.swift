import Darwin
import Foundation

/// Where a bundle keeps the bridged-networking runtime, and who registers its
/// daemon with macOS (macos/network-helper/README.md). The daemon sits beside
/// the helper, and the server, supervisor, client and the kit's job in the
/// resources' `network` folder.
struct NetworkServiceLayout: Equatable {
    static let fullAppJobName = "dev.tryomarchy.network.plist"
    static let kitJobName = "launchd.plist"
    static let daemonName = "omarchy-network-daemon"
    static let clientName = "omarchy-network-client"

    enum Registration: Equatable {
        /// The full app registers its own daemon with Service Management.
        case thisApp
        /// The app that embeds the kit registers the kit's daemon as itself;
        /// the helper only asks the daemon whether it serves this copy.
        case embeddingApp
        case unavailable
    }

    let bundleURL: URL
    let resources: URL?
    let executableDirectory: URL?

    init(bundleURL: URL, resources: URL?, executableDirectory: URL?) {
        self.bundleURL = bundleURL
        self.resources = resources
        self.executableDirectory = executableDirectory
    }

    init(bundle: Bundle) {
        self.init(bundleURL: bundle.bundleURL, resources: bundle.resourceURL,
                  executableDirectory: bundle.executableURL?.deletingLastPathComponent())
    }

    var fullAppJob: URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(Self.fullAppJobName)")
    }
    var payloads: URL? { resources?.appendingPathComponent("network", isDirectory: true) }
    var client: URL? { payloads?.appendingPathComponent(Self.clientName) }
    var kitJob: URL? { payloads?.appendingPathComponent(Self.kitJobName) }
    var daemon: URL? { executableDirectory?.appendingPathComponent(Self.daemonName) }

    var registration: Registration {
        if Self.isRegularFile(fullAppJob) { return .thisApp }
        let kit = [kitJob, client, daemon].compactMap { $0 }
        return kit.count == 3 && kit.allSatisfy(Self.isRegularFile) ? .embeddingApp : .unavailable
    }

    /// Whether a bridged start can go ahead. The full app registers its
    /// daemon as it starts; a kit asks the daemon its embedding app
    /// registered, so a missing, unapproved or foreign daemon is known before
    /// Omarchy starts.
    func bridgedNetwork(productName: String,
                        check: (_ client: URL, _ resources: URL) -> String? = NetworkServiceCheck.run)
        -> BridgedNetworkAvailability {
        switch registration {
        case .thisApp:
            return .available
        case .embeddingApp:
            guard let client, let resources, let problem = check(client, resources) else { return .available }
            fputs("[network] \(problem)\n", stderr)
            return .unavailable("\(productName) has not set up its networking helper, or macOS has not approved it, so bridged networking is unavailable.")
        case .unavailable:
            return .unavailable("Bridged networking is not available in \(productName).")
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && information.st_mode & S_IFMT == S_IFREG
    }
}

enum BridgedNetworkAvailability: Equatable {
    case available
    case unavailable(String)
}

/// Asks the daemon, through the bundled client, whether it serves this
/// bundle's runtime. Nil when it does; otherwise what the client said.
enum NetworkServiceCheck {
    static func run(client: URL, resources: URL) -> String? {
        let process = Process()
        process.executableURL = client
        process.arguments = ["check", resources.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { return "The networking client could not start: \(error.localizedDescription)" }
        let detail = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: detail.prefix(4_096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Networking helper did not respond." : text
    }
}
