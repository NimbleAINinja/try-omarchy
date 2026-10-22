import Foundation

/// The run mode's protocol, version 1. The client writes one configuration
/// line to the helper's standard input, then commands; the helper writes one
/// event per line to its standard output and ends with `exited`.
public enum VMRunProtocol {
    public static let version = 1
    public static let maximumLineBytes = 16_384
}

public enum VMRunBridge: String, CaseIterable, Codable, Sendable {
    case clipboard
    case authentication
    case camera
    case battery
    case timezone
}

public enum VMRunNetwork: String, Codable, Sendable {
    case shared
    case bridged
}

/// What the run mode needs to start the VM. The settings stored for the VM
/// win: the storage folder, memory, CPUs and network here apply only where
/// the launcher stored nothing (docs/vm-kit.md).
public struct VMRunConfiguration: Equatable, Sendable {
    /// Names the app in messages, the Touch ID prompt, and the Omarchy
    /// window's Dock entry and menus.
    public var productName: String
    /// The Omarchy window's Dock icon: an existing .icns or .png file. Nil is
    /// the kit's own icon.
    public var iconPath: String?
    /// The VM's storage folder when none was chosen in the settings. Nil is
    /// the full app's default folder.
    public var storageRoot: String?
    public var bridges: [VMRunBridge]
    /// Used when no resources are stored. Nil leaves the size to the
    /// launcher's automatic choice.
    public var memoryMiB: Int?
    public var cpus: Int?
    public var network: VMRunNetwork

    public init(
        productName: String,
        iconPath: String? = nil,
        storageRoot: String? = nil,
        bridges: [VMRunBridge] = VMRunBridge.allCases,
        memoryMiB: Int? = nil,
        cpus: Int? = nil,
        network: VMRunNetwork = .shared
    ) {
        self.productName = productName
        self.iconPath = iconPath
        self.storageRoot = storageRoot
        self.bridges = bridges
        self.memoryMiB = memoryMiB
        self.cpus = cpus
        self.network = network
    }

    public func encodedLine() throws -> Data {
        try validate()
        var object: [String: Any] = [
            "version": VMRunProtocol.version,
            "productName": productName,
            "bridges": bridges.map(\.rawValue),
            "network": network.rawValue,
        ]
        if let iconPath { object["iconPath"] = iconPath }
        if let storageRoot { object["storageRoot"] = storageRoot }
        if let memoryMiB { object["memoryMiB"] = memoryMiB }
        if let cpus { object["cpus"] = cpus }
        return try VMRunLine.encode(object)
    }

    public static func decode(line: Data) throws -> Self {
        let object = try VMRunLine.decode(line)
        let allowed: Set = ["version", "productName", "iconPath", "storageRoot", "bridges", "memoryMiB", "cpus", "network"]
        guard Set(object.keys).isSubset(of: allowed),
              VMRunLine.integer(object["version"]) == VMRunProtocol.version,
              let productName = object["productName"] as? String,
              let bridgeNames = object["bridges"] as? [String],
              let networkName = object["network"] as? String,
              let network = VMRunNetwork(rawValue: networkName)
        else { throw VMRunProtocolError.invalidConfiguration }
        var bridges: [VMRunBridge] = []
        for name in bridgeNames {
            guard let bridge = VMRunBridge(rawValue: name), !bridges.contains(bridge) else {
                throw VMRunProtocolError.invalidConfiguration
            }
            bridges.append(bridge)
        }
        var configuration = Self(productName: productName, bridges: bridges, network: network)
        if let value = object["iconPath"] {
            guard let path = value as? String else { throw VMRunProtocolError.invalidConfiguration }
            configuration.iconPath = path
        }
        if let value = object["storageRoot"] {
            guard let root = value as? String else { throw VMRunProtocolError.invalidConfiguration }
            configuration.storageRoot = root
        }
        if let value = object["memoryMiB"] {
            guard let memory = VMRunLine.integer(value) else { throw VMRunProtocolError.invalidConfiguration }
            configuration.memoryMiB = memory
        }
        if let value = object["cpus"] {
            guard let cpus = VMRunLine.integer(value) else { throw VMRunProtocolError.invalidConfiguration }
            configuration.cpus = cpus
        }
        try configuration.validate()
        return configuration
    }

    public func validate() throws {
        guard (1...64).contains(productName.count), productName.utf8.count <= 255,
              productName == productName.trimmingCharacters(in: .whitespaces),
              productName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              Set(bridges).count == bridges.count
        else { throw VMRunProtocolError.invalidConfiguration }
        if let storageRoot {
            guard storageRoot.hasPrefix("/"), storageRoot.count <= 1_024,
                  !storageRoot.contains("\n"), !storageRoot.contains("\r")
            else { throw VMRunProtocolError.invalidConfiguration }
        }
        if let iconPath {
            var information = stat()
            guard iconPath.hasPrefix("/"), iconPath.utf8.count <= 1_024,
                  iconPath.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  ["icns", "png"].contains(URL(fileURLWithPath: iconPath).pathExtension.lowercased()),
                  stat(iconPath, &information) == 0, information.st_mode & S_IFMT == S_IFREG
            else { throw VMRunProtocolError.invalidConfiguration }
        }
        if let memoryMiB, !(2_048...1_048_576).contains(memoryMiB) { throw VMRunProtocolError.invalidConfiguration }
        if let cpus, !(1...1_024).contains(cpus) { throw VMRunProtocolError.invalidConfiguration }
    }
}

public enum VMRunCommand: String, Sendable {
    /// Ask Omarchy to shut down, then stop the VM if it has not within a minute.
    case shutdown

    public func encodedLine() throws -> Data {
        try VMRunLine.encode(["version": VMRunProtocol.version, "command": rawValue])
    }

    public static func decode(line: Data) throws -> Self {
        let object = try VMRunLine.decode(line)
        guard Set(object.keys) == ["version", "command"],
              VMRunLine.integer(object["version"]) == VMRunProtocol.version,
              let name = object["command"] as? String,
              let command = Self(rawValue: name)
        else { throw VMRunProtocolError.invalidCommand }
        return command
    }
}

public enum VMRunPhase: String, CaseIterable, Sendable {
    case waitingForDownload = "waiting-for-download"
    case downloading
    case reconnecting
    /// The download waits for a connection that is not cellular or Low Data Mode.
    case paused
    case verifyingDownload = "verifying-download"
    case checking
    case verifying
    case preparing
    case finishing
    case starting
}

/// Stable codes for what stops the VM. Messages may change; codes do not.
public enum VMRunErrorCode: String, CaseIterable, Sendable {
    case vmAlreadyOpen = "vm-already-open"
    case volumeNotAPFS = "volume-not-apfs"
    case macOSTooOld = "macos-too-old"
    case hypervisorUnavailable = "hypervisor-unavailable"
    case notEnoughSpace = "not-enough-space"
    case downloadFailed = "download-failed"
    case imageDigestMismatch = "image-digest-mismatch"
    case qemuExited = "qemu-exited"
    case storageUnavailable = "storage-unavailable"
    case storageLayoutUnknown = "storage-layout-unknown"
    case storageDisconnected = "storage-disconnected"
    case bridgedNetworkUnavailable = "bridged-network-unavailable"
    case hostSleepUnavailable = "host-sleep-unavailable"
    case hostWakeFailed = "host-wake-failed"
    case invalidConfiguration = "invalid-configuration"
    case launchFailed = "launch-failed"
}

public struct VMRunError: Error, Equatable, Sendable, LocalizedError {
    public let code: VMRunErrorCode
    public let message: String

    public init(code: VMRunErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum VMRunEvent: Equatable, Sendable {
    /// Percent is 0 to 100, or nil while the step cannot be measured.
    case progress(VMRunPhase, percent: Int?)
    case ready
    case stopping
    case error(VMRunError)
    /// The last event. Status 0 is a clean shutdown.
    case exited(status: Int32)

    public func encodedLine() throws -> Data {
        var object: [String: Any] = ["version": VMRunProtocol.version]
        switch self {
        case .progress(let phase, let percent):
            object["event"] = "progress"
            object["phase"] = phase.rawValue
            if let percent { object["percent"] = min(100, max(0, percent)) }
        case .ready:
            object["event"] = "ready"
        case .stopping:
            object["event"] = "stopping"
        case .error(let error):
            object["event"] = "error"
            object["code"] = error.code.rawValue
            object["message"] = String(error.message.prefix(4_096))
        case .exited(let status):
            object["event"] = "exited"
            object["status"] = Int(status)
        }
        return try VMRunLine.encode(object)
    }

    public static func decode(line: Data) throws -> Self {
        let object = try VMRunLine.decode(line)
        guard VMRunLine.integer(object["version"]) == VMRunProtocol.version,
              let name = object["event"] as? String else { throw VMRunProtocolError.invalidEvent }
        func require(_ keys: Set<String>, optional: Set<String> = []) throws {
            let present = Set(object.keys).subtracting(["version", "event"])
            guard keys.isSubset(of: present), present.isSubset(of: keys.union(optional)) else {
                throw VMRunProtocolError.invalidEvent
            }
        }
        switch name {
        case "progress":
            try require(["phase"], optional: ["percent"])
            guard let phaseName = object["phase"] as? String,
                  let phase = VMRunPhase(rawValue: phaseName) else { throw VMRunProtocolError.invalidEvent }
            var percent: Int?
            if let value = object["percent"] {
                guard let number = VMRunLine.integer(value), (0...100).contains(number) else {
                    throw VMRunProtocolError.invalidEvent
                }
                percent = number
            }
            return .progress(phase, percent: percent)
        case "ready":
            try require([])
            return .ready
        case "stopping":
            try require([])
            return .stopping
        case "error":
            try require(["code", "message"])
            guard let codeName = object["code"] as? String,
                  let code = VMRunErrorCode(rawValue: codeName),
                  let message = object["message"] as? String,
                  message.utf8.count <= 16_384 else { throw VMRunProtocolError.invalidEvent }
            return .error(VMRunError(code: code, message: message))
        case "exited":
            try require(["status"])
            guard let status = VMRunLine.integer(object["status"]), (0...255).contains(status) else {
                throw VMRunProtocolError.invalidEvent
            }
            return .exited(status: Int32(status))
        default:
            throw VMRunProtocolError.invalidEvent
        }
    }
}

public enum VMRunProtocolError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidCommand
    case invalidEvent
    case lineTooLong
}

enum VMRunLine {
    static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count < VMRunProtocol.maximumLineBytes else { throw VMRunProtocolError.lineTooLong }
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) throws -> [String: Any] {
        var line = line
        if line.last == 0x0A { line.removeLast() }
        guard line.count < VMRunProtocol.maximumLineBytes, !line.contains(0x0A) else {
            throw VMRunProtocolError.lineTooLong
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw VMRunProtocolError.invalidEvent
        }
        return object
    }

    /// JSON numbers that are whole and not booleans.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), Double(integer) == number.doubleValue
        else { return nil }
        return integer
    }
}
