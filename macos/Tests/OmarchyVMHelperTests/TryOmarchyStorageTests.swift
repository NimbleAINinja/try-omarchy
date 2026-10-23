import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper
import TryOmarchyKitClient

struct TryOmarchyStorageTests {
    private static let mebibyte = 1_048_576

    private static func isAPFS(_ url: URL) -> Bool {
        var information = statfs()
        guard statfs(url.path, &information) == 0 else { return false }
        return withUnsafeBytes(of: information.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            == "apfs"
    }

    private static func write(_ data: Data, to url: URL, at offset: UInt64 = 0) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test func clonedDiskCountsSharedBlocksOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell-factory"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard Self.isAPFS(root) else { return }

        let factory = root.appendingPathComponent("shell-factory/factory.img")
        let disk = root.appendingPathComponent("shell/disk.img")
        try Self.write(Self.randomData(4 * Self.mebibyte), to: factory)
        #expect(TryOmarchyStorage.allocatedBytes(at: root) == Int64(4 * Self.mebibyte))

        #expect(clonefile(factory.path, disk.path, 0) == 0)
        #expect(TryOmarchyStorage.allocatedBytes(at: root) == Int64(4 * Self.mebibyte))

        try Self.write(Self.randomData(Self.mebibyte), to: disk, at: UInt64(Self.mebibyte))
        try Self.write(Self.randomData(Self.mebibyte), to: root.appendingPathComponent("shell/efi-vars.fd"))
        #expect(TryOmarchyStorage.allocatedBytes(at: root) == Int64(6 * Self.mebibyte))
    }

    @Test("the resolved VM folder is the pointer's, else 1.2's, else the default, as the run mode chooses")
    func resolvedRoot() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-resolve-\(UUID().uuidString)", isDirectory: true)
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = applicationSupport.appendingPathComponent("Try Omarchy", isDirectory: true)
        let pointer = folder.appendingPathComponent("storage-location.json")
        let suiteName = "TryOmarchyStorageTests.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: suiteName))
        defer {
            legacy.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let defaultRoot = applicationSupport.appendingPathComponent("Try Omarchy/VM/v1", isDirectory: true)
        let resolved = { TryOmarchyStorage.resolvedRoot(inApplicationSupport: applicationSupport, legacyPreferences: legacy) }
        let runMode = {
            StorageLocationPreferenceStore(storage: LauncherSettingsFile.storageLocation(
                legacy: legacy, legacyIsWritable: false, directory: folder))
        }
        let choose = { (path: String) in
            StorageLocationPreferenceStore(defaults: legacy).save(StorageLocationPreference(containerPath: path))
        }
        let writePointer = { (contents: String, permissions: Int) in
            try Data(contents.utf8).write(to: pointer)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: pointer.path)
        }

        #expect(resolved() == defaultRoot)
        #expect(resolved() == TryOmarchyStorage.resolvedRoot(inApplicationSupport: applicationSupport, legacyPreferences: nil))

        choose("/Volumes/Drive/Omarchy/")
        #expect(resolved().path == "/Volumes/Drive/Omarchy")
        #expect(runMode().load().containerPath == "/Volumes/Drive/Omarchy/")
        choose("/Volumes")
        #expect(resolved() == defaultRoot)
        choose("Omarchy")
        #expect(resolved() == defaultRoot)
        #expect(runMode().problem() != nil)

        choose("/Volumes/Old/Omarchy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        StorageLocationPreferenceStore(storage: LauncherSettingsFile.storageLocation(legacy: nil, directory: folder))
            .save(StorageLocationPreference(containerPath: "/Volumes/New/Omarchy"))
        #expect(resolved().path == "/Volumes/New/Omarchy")
        #expect(runMode().load().containerPath == "/Volumes/New/Omarchy")

        StorageLocationPreferenceStore(storage: LauncherSettingsFile.storageLocation(legacy: nil, directory: folder))
            .save(.default)
        #expect(resolved() == defaultRoot)
        #expect(runMode().load() == .default)

        try writePointer(#"{"schemaVersion":1,"settings":{"storageLocationPreferences":null}}"#, 0o600)
        #expect(resolved() == defaultRoot)
        #expect(runMode().load() == .default && runMode().problem() == nil)
        try writePointer(#"{"schemaVersion":1,"settings":{}}"#, 0o600)
        #expect(resolved().path == "/Volumes/Old/Omarchy")
        #expect(runMode().load().containerPath == "/Volumes/Old/Omarchy")

        let chosen = #"{"schemaVersion":1,"settings":{"storageLocationPreferences":{"schemaVersion":1,"containerPath":"/Volumes/New/Omarchy"}}}"#
        let untrusted: [(String, Int)] = [
            (chosen, 0o644),
            (chosen.replacingOccurrences(of: #"{"schemaVersion":1,"settings""#, with: #"{"schemaVersion":2,"settings""#), 0o600),
            ("damaged", 0o600),
            (String(repeating: " ", count: 65_536) + chosen, 0o600),
            (#"{"schemaVersion":1,"settings":{"storageLocationPreferences":{"schemaVersion":9}}}"#, 0o600),
        ]
        for (contents, permissions) in untrusted {
            try writePointer(contents, permissions)
            #expect(resolved() == defaultRoot, "\(contents.prefix(80))")
            #expect(runMode().problem() != nil, "\(contents.prefix(80))")
        }

        try writePointer(chosen, 0o600)
        #expect(resolved().path == "/Volumes/New/Omarchy")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
        #expect(resolved() == defaultRoot)
        #expect(runMode().problem() != nil)
    }

    @Test("the resolved VM folder takes the size and space checks")
    func resolvedRootHasVM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-moved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!TryOmarchyStorage.hasVM(at: root))
        #expect(TryOmarchyStorage.requiredFreeBytes(at: root) == TryOmarchyStorage.requiredFreeBytesForNewVM)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell"), withIntermediateDirectories: true)
        try Self.write(Self.randomData(Self.mebibyte), to: root.appendingPathComponent("shell/disk.img"))
        #expect(TryOmarchyStorage.hasVM(at: root))
        #expect(TryOmarchyStorage.requiredFreeBytes(at: root) == TryOmarchyStorage.requiredFreeBytesForExistingVM)
        #expect(TryOmarchyStorage.allocatedBytes(at: root) >= Int64(Self.mebibyte))
    }
}
