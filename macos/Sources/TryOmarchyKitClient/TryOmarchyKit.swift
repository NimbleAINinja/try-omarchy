import AppKit
import Darwin
import Foundation

/// The kit an app embeds to run the VM: the helper, the QEMU runtime, the
/// firmware, the launch scripts, the try-omarchy package and the image's
/// download manifest. It is a helper bundle with no identity of its own: its
/// Info.plist has no bundle identifier or name, so the helper runs as the app
/// that starts it.
public struct TryOmarchyKit: Sendable {
    /// The kit's folder, at the top of `TryOmarchyKit.zip` and in an app's
    /// `Contents/Helpers`.
    public static let bundleName = "TryOmarchyKit.bundle"
    public static let helperName = "omarchy-vm-helper"
    public static let helperPath = "Contents/MacOS/\(helperName)"
    public static let manifestPath = "Contents/Resources/\(TryOmarchyKitManifest.fileName)"

    public let bundleURL: URL

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    /// The kit in a folder that holds `TryOmarchyKit.zip` unpacked.
    public static func unpacked(in folder: URL) -> Self {
        Self(bundleURL: folder.appendingPathComponent(bundleName, isDirectory: true))
    }

    /// The kit in an app's `Contents/Helpers`.
    public static func embedded(in bundle: Bundle = .main) -> Self {
        unpacked(in: bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
    }

    public func helperURL() throws -> URL {
        let helper = bundleURL.appendingPathComponent(Self.helperPath, isDirectory: false)
        var information = stat()
        guard lstat(bundleURL.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
              lstat(helper.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: helper.path)
        else {
            throw VMRunError(code: .launchFailed, message: "This app's copy of Omarchy's VM kit is missing or damaged.")
        }
        return helper
    }
}

/// Where the VM is. The full app and the run mode share it, so either opens
/// the VM the other made.
public enum TryOmarchyStorage {
    /// Free space a first start needs: the download, the unpacked disk and room
    /// to run, as the full app's manual asks.
    public static let requiredFreeBytesForNewVM: Int64 = 15_000_000_000
    /// Free space to start a VM that already exists.
    public static let requiredFreeBytesForExistingVM: Int64 = 1_073_741_824

    static let folderName = "Try Omarchy"
    static let storageLocationFileName = "storage-location.json"
    static let storageLocationKey = "storageLocationPreferences"
    static let maximumStorageLocationBytes = 65_536
    static let unsafeRoots: Set<String> = ["/", "/Users", "/private", "/private/tmp", "/tmp", "/Volumes"]

    public static func defaultRoot(fileManager: FileManager = .default) -> URL? {
        applicationSupport(fileManager: fileManager).map(defaultRoot(inApplicationSupport:))
    }

    /// The VM folder the run mode uses when its configuration names none: the
    /// folder chosen in the full app, or else the default folder. A choice the
    /// run mode would refuse as untrusted gives the default folder, and a
    /// chosen folder on a drive that is not connected is still that folder.
    public static func resolvedRoot(fileManager: FileManager = .default) -> URL? {
        applicationSupport(fileManager: fileManager).map {
            resolvedRoot(inApplicationSupport: $0,
                         legacyPreferences: UserDefaults(suiteName: TryOmarchyApp.bundleIdentifier))
        }
    }

    public static func resolvedRoot(inApplicationSupport applicationSupport: URL,
                                    legacyPreferences: UserDefaults?) -> URL {
        let fallback = defaultRoot(inApplicationSupport: applicationSupport)
        let choice: Data?
        switch storedLocation(in: applicationSupport.appendingPathComponent(folderName, isDirectory: true)) {
        case .untrusted, .reset: return fallback
        case .stored(let data): choice = data
        case .absent: choice = legacyPreferences?.data(forKey: storageLocationKey)
        }
        guard let choice else { return fallback }
        return chosenRoot(from: choice) ?? fallback
    }

    private static func applicationSupport(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static func defaultRoot(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("\(folderName)/VM/v1", isDirectory: true)
    }

    private enum StoredLocation {
        case absent
        case reset
        case stored(Data)
        case untrusted
    }

    private static func storedLocation(in folder: URL) -> StoredLocation {
        var information = stat()
        guard lstat(folder.path, &information) == 0 else { return .absent }
        guard information.st_mode & S_IFMT == S_IFDIR, information.st_uid == getuid(),
              information.st_mode & 0o022 == 0 else { return .untrusted }
        let file = folder.appendingPathComponent(storageLocationFileName, isDirectory: false)
        guard lstat(file.path, &information) == 0 else { return errno == ENOENT ? .absent : .untrusted }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid(),
              information.st_mode & 0o777 == 0o600, information.st_size <= maximumStorageLocationBytes,
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1, let settings = object["settings"] as? [String: Any]
        else { return .untrusted }
        guard let value = settings[storageLocationKey] else { return .absent }
        guard !(value is NSNull) else { return .reset }
        guard let choice = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        else { return .untrusted }
        return .stored(choice)
    }

    private struct StorageLocationChoice: Decodable {
        let schemaVersion: Int
        let containerPath: String?
    }

    private static func chosenRoot(from data: Data) -> URL? {
        guard let choice = try? JSONDecoder().decode(StorageLocationChoice.self, from: data),
              choice.schemaVersion == 1, let path = choice.containerPath,
              path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.utf8.contains(0)
        else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return unsafeRoots.contains(root.path) ? nil : root
    }

    public static func hasVM(at root: URL) -> Bool {
        let disk = root.appendingPathComponent("shell/disk.img", isDirectory: false)
        var information = stat()
        return lstat(disk.path, &information) == 0 && information.st_mode & S_IFMT == S_IFREG
    }

    public static func requiredFreeBytes(at root: URL) -> Int64 {
        hasVM(at: root) ? requiredFreeBytesForExistingVM : requiredFreeBytesForNewVM
    }

    /// Free space on the volume that holds, or will hold, the folder.
    public static func freeBytes(at root: URL, fileManager: FileManager = .default) -> Int64? {
        var candidate = root.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The space the folder takes on disk, which deleting it frees. Sparse VM
    /// disks count only the blocks they use. The VM's disk is an APFS clone of
    /// the factory image, so blocks they share count once: each file's private
    /// blocks, plus the largest set of blocks one file shares.
    public static func allocatedBytes(at root: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                   options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var privateTotal: Int64 = 0
        var largestShared: Int64 = 0
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { continue }
            let allocated = Int64(bytes)
            let unshared = privateBytes(at: url).map { min(max($0, 0), allocated) } ?? allocated
            privateTotal += unshared
            largestShared = max(largestShared, allocated - unshared)
        }
        return privateTotal + largestShared
    }

    /// The bytes of a file that no APFS clone shares, or nil where the volume
    /// cannot tell.
    static func privateBytes(at url: URL) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var reply = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        guard getattrlist(url.path, &request, &reply, reply.count, options) == 0 else { return nil }
        return reply.withUnsafeBytes { buffer -> Int64? in
            let returned = buffer.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return buffer.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size,
                                        as: Int64.self)
        }
    }
}

/// The full app, Try Omarchy. Once it is installed, it owns the VM.
public enum TryOmarchyApp {
    public static let bundleIdentifier = "dev.tryomarchy.native"
    public static let downloadURL = URL(string: "https://github.com/omacom/try-omarchy/releases/latest")!

    @MainActor
    public static func installedURL(workspace: NSWorkspace = .shared) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Opens the full app, whose launcher starts the VM.
    @MainActor
    public static func open(workspace: NSWorkspace = .shared) -> Bool {
        guard let url = installedURL(workspace: workspace) else { return false }
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
