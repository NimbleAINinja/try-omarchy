import AppKit
import Darwin
import Foundation

/// The kit an app embeds to run the VM: the helper, the QEMU runtime, the
/// firmware, the launch scripts, the try-omarchy package and the image's
/// download manifest, as a bundle without the full app's launcher.
public struct TryOmarchyKit: Sendable {
    public static let bundleName = "Try Omarchy Kit.app"
    public static let helperName = "omarchy-vm-helper"

    public let bundleURL: URL

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    /// The kit in an app's `Contents/Helpers`.
    public static func embedded(in bundle: Bundle = .main) -> Self {
        Self(bundleURL: bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true))
    }

    public func helperURL() throws -> URL {
        let helper = bundleURL.appendingPathComponent("Contents/MacOS/\(Self.helperName)", isDirectory: false)
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

/// Where the full app keeps its VM by default. The trial uses the same folder,
/// so the full app opens the VM the trial made.
public enum TryOmarchyStorage {
    /// Free space a first start needs: the download, the unpacked disk and room
    /// to run, as the full app's manual asks.
    public static let requiredFreeBytesForNewVM: Int64 = 15_000_000_000
    /// Free space to start a VM that already exists.
    public static let requiredFreeBytesForExistingVM: Int64 = 1_073_741_824

    public static func defaultRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Try Omarchy/VM/v1", isDirectory: true)
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

    /// The space the folder takes on disk. Sparse VM disks count only the
    /// blocks they use.
    public static func allocatedBytes(at root: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                   options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { continue }
            total += Int64(bytes)
        }
        return total
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
