import Darwin
import Foundation

/// Where a preference store keeps its versioned values.
protocol LauncherSettingsStorage: AnyObject {
    func settingData(forKey key: String) -> Data?
    func setSettingData(_ data: Data, forKey key: String)
    func removeSetting(forKey key: String)
}

extension UserDefaults: LauncherSettingsStorage {
    func settingData(forKey key: String) -> Data? { data(forKey: key) }
    func setSettingData(_ data: Data, forKey key: String) { set(data, forKey: key) }
    func removeSetting(forKey key: String) { removeObject(forKey: key) }
}

/// A private, versioned JSON file of settings. UserDefaults follow the identity
/// of the app that runs the kit, so the full app and the run mode keep their
/// settings in files that both read.
///
/// The VM's settings wait for the launcher to mark its folder: a file in an
/// empty folder someone picked would make the folder look used. Until then the
/// full app keeps them in `legacy`, where its older settings already are, and
/// they move into the file once the folder is ready and has no file.
final class LauncherSettingsFile: LauncherSettingsStorage {
    static let schemaVersion = 1
    static let maximumBytes = 65_536
    static let vmSettingsFileName = "settings.json"
    static let storageLocationFileName = "storage-location.json"

    static let vmSettingKeys = [
        VMResourcePreferenceStore.key,
        MemoryPreferenceStore.key,
        VMNetworkPreferenceStore.key,
        PortForwardingPreferenceStore.key,
        SharedFolderPreferenceStore.key,
        USBDevicePreferenceStore.key,
        FullscreenPreferenceStore.key,
    ]

    private enum Location {
        /// A launcher-marked VM folder; the file is never created elsewhere.
        case workspace
        /// A folder of its own, created when missing.
        case folder
    }

    let fileName: String
    private let directory: () -> URL?
    private let location: Location
    private let legacy: UserDefaults?
    private let legacyKeys: [String]

    private init(fileName: String, location: Location, legacy: UserDefaults?, legacyKeys: [String],
                 directory: @escaping () -> URL?) {
        self.fileName = fileName
        self.location = location
        self.legacy = legacy
        self.legacyKeys = legacyKeys
        self.directory = directory
    }

    /// The settings of the VM whose storage folder `root` returns.
    static func vmSettings(legacy: UserDefaults?, root: @escaping () -> URL?) -> LauncherSettingsFile {
        LauncherSettingsFile(fileName: vmSettingsFileName, location: .workspace, legacy: legacy,
                             legacyKeys: vmSettingKeys, directory: root)
    }

    /// Which folder holds the VM. It cannot live in the VM's folder, so it
    /// stays in the fixed `Try Omarchy` folder that every kit resolves.
    static func storageLocation(
        legacy: UserDefaults?,
        directory: URL? = defaultStorageLocationDirectory()
    ) -> LauncherSettingsFile {
        LauncherSettingsFile(fileName: storageLocationFileName, location: .folder, legacy: legacy,
                             legacyKeys: [StorageLocationPreferenceStore.key], directory: { directory })
    }

    static func defaultStorageLocationDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(StorageLocationPolicy.workspaceDirectoryName, isDirectory: true)
    }

    func settingData(forKey key: String) -> Data? {
        guard let folder = readyFolder(creating: hasLegacySettings) else { return legacy?.data(forKey: key) }
        adoptLegacySettings(in: folder)
        guard let value = read(in: folder)?[key] else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    func setSettingData(_ data: Data, forKey key: String) {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        update(key: key, value: value)
    }

    func removeSetting(forKey key: String) {
        update(key: key, value: nil)
    }

    /// Moves the full app's older values into the file, once the folder is
    /// ready and still has no file. Reads do this too.
    func adoptLegacySettings() {
        guard let folder = readyFolder(creating: hasLegacySettings) else { return }
        adoptLegacySettings(in: folder)
    }

    private var hasLegacySettings: Bool {
        guard let legacy else { return false }
        return legacyKeys.contains { legacy.object(forKey: $0) != nil }
    }

    private func update(key: String, value: Any?) {
        guard let folder = readyFolder(creating: true) else {
            guard let legacy else {
                fputs("[settings] The settings folder is unavailable; \(key) was not saved.\n", stderr)
                return
            }
            legacy.set(value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) },
                       forKey: key)
            return
        }
        adoptLegacySettings(in: folder)
        do {
            var settings: [String: Any]
            switch try existingSettings(in: folder) {
            case .absent, .unreadable: settings = [:]
            case .settings(let stored): settings = stored
            }
            settings[key] = value
            try write(settings, in: folder)
        } catch {
            fputs("[settings] \(key) was not saved: \(error.localizedDescription)\n", stderr)
        }
    }

    private func adoptLegacySettings(in folder: URL) {
        guard let legacy, case .absent? = try? existingSettings(in: folder) else { return }
        var settings: [String: Any] = [:]
        for key in legacyKeys {
            guard let data = legacy.data(forKey: key),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            settings[key] = value
        }
        guard !settings.isEmpty else { return }
        do {
            try write(settings, in: folder)
            for key in legacyKeys { legacy.removeObject(forKey: key) }
        } catch {
            fputs("[settings] Older settings could not move into \(fileName): \(error.localizedDescription)\n", stderr)
        }
    }

    private enum Contents {
        case absent
        /// Damaged content, which the next save replaces.
        case unreadable
        case settings([String: Any])
    }

    /// Throws for a file that must not be read or replaced: not a private
    /// regular file, too large, or written by a newer schema.
    private func existingSettings(in folder: URL) throws -> Contents {
        let url = folder.appendingPathComponent(fileName)
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            guard errno == ENOENT else { throw HelperError.io("\(fileName) could not be checked.") }
            return .absent
        }
        guard Self.isPrivate(information, type: S_IFREG, permissions: 0o600) else {
            throw HelperError.io("\(fileName) is not a private regular file.")
        }
        guard information.st_size <= Self.maximumBytes else { throw HelperError.io("\(fileName) is too large.") }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              let settings = object["settings"] as? [String: Any]
        else { return .unreadable }
        guard version.intValue == Self.schemaVersion, version.doubleValue == Double(Self.schemaVersion) else {
            throw HelperError.io("\(fileName) was written by a newer version.")
        }
        return .settings(settings)
    }

    private func read(in folder: URL) -> [String: Any]? {
        guard case .settings(let settings)? = try? existingSettings(in: folder) else { return nil }
        return settings
    }

    private func write(_ settings: [String: Any], in folder: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": Self.schemaVersion, "settings": settings],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= Self.maximumBytes else { throw HelperError.io("\(fileName) would be too large.") }
        let url = folder.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw HelperError.io("\(fileName) could not be made private.") }
    }

    /// The folder when it is safe to use, or nil.
    private func readyFolder(creating: Bool) -> URL? {
        guard let folder = directory()?.standardizedFileURL else { return nil }
        var information = stat()
        switch location {
        case .workspace:
            guard StorageLocationPolicy.hasValidRootMarker(in: folder),
                  lstat(folder.path, &information) == 0,
                  Self.isPrivate(information, type: S_IFDIR, permissions: 0o700) else { return nil }
        case .folder:
            if lstat(folder.path, &information) != 0 {
                guard creating, errno == ENOENT,
                      (try? FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
                      lstat(folder.path, &information) == 0 else { return nil }
            }
            guard information.st_mode & S_IFMT == S_IFDIR, information.st_uid == getuid(),
                  information.st_mode & 0o022 == 0 else { return nil }
        }
        return folder
    }

    private static func isPrivate(_ information: stat, type: mode_t, permissions: mode_t) -> Bool {
        information.st_mode & S_IFMT == type
            && information.st_uid == getuid()
            && information.st_mode & 0o777 == permissions
    }
}
