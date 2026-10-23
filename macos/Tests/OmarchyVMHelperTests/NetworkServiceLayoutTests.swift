import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Networking helper layout")
@MainActor
struct NetworkServiceLayoutTests {
    private struct Bundle {
        let root: URL
        let layout: NetworkServiceLayout

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("network-layout-\(UUID().uuidString)/Kit.app", isDirectory: true)
            layout = NetworkServiceLayout(bundleURL: root,
                                          resources: root.appendingPathComponent("Contents/Resources"),
                                          executableDirectory: root.appendingPathComponent("Contents/MacOS"))
        }

        func add(_ file: URL?, contents: String = "") throws {
            let file = try #require(file)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        func addKitRuntime(client: String = "#!/bin/sh\nexit 0\n") throws {
            try add(layout.kitJob)
            try add(layout.client, contents: client)
            try add(layout.daemon)
        }

        func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    @Test func theFullAppRegistersItsOwnDaemon() throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        #expect(bundle.layout.registration == .unavailable)
        try bundle.add(bundle.layout.fullAppJob)
        try bundle.addKitRuntime()
        #expect(bundle.layout.registration == .thisApp)
        #expect(bundle.layout.bridgedNetwork(productName: "Try Omarchy", check: { _, _ in
            Issue.record("the full app checks its daemon as it registers it"); return nil
        }) == .available)
    }

    @Test func aKitNeedsItsWholeRuntime() throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        try bundle.add(bundle.layout.kitJob)
        try bundle.add(bundle.layout.client)
        #expect(bundle.layout.registration == .unavailable)
        #expect(bundle.layout.bridgedNetwork(productName: "Omarchy Installer", check: { _, _ in nil })
            == .unavailable("Bridged networking is not available in Omarchy Installer."))
        try bundle.add(bundle.layout.daemon)
        #expect(bundle.layout.registration == .embeddingApp)
    }

    @Test func aKitAsksTheDaemonItsAppRegistered() throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        try bundle.addKitRuntime()
        var asked: [URL] = []
        #expect(bundle.layout.bridgedNetwork(productName: "Omarchy Installer", check: { client, resources in
            asked = [client, resources]; return nil
        }) == .available)
        #expect(asked == [bundle.layout.client, bundle.layout.resources].compactMap { $0 })
        #expect(bundle.layout.bridgedNetwork(productName: "Omarchy Installer", check: { _, _ in "unavailable" })
            == .unavailable("Omarchy Installer has not set up its networking helper, or macOS has not approved it, so bridged networking is unavailable."))
    }

    @Test func theCheckRunsTheBundledClient() throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        try bundle.addKitRuntime(client: """
            #!/bin/sh
            [ "$1" = check ] && [ -d "$2/network" ] || exit 64
            echo 'Networking service unavailable or this app build is not authorized.' >&2
            exit 1
            """)
        let client = try #require(bundle.layout.client)
        let resources = try #require(bundle.layout.resources)
        #expect(NetworkServiceCheck.run(client: client, resources: resources)
            == "Networking service unavailable or this app build is not authorized.")
        try bundle.add(bundle.layout.client, contents: "#!/bin/sh\n[ \"$1\" = check ] && exit 0\nexit 64\n")
        #expect(NetworkServiceCheck.run(client: client, resources: resources) == nil)
        try FileManager.default.removeItem(at: client)
        #expect(NetworkServiceCheck.run(client: client, resources: resources) != nil)
    }

    @Test func theRunModesSettingsOnlyReportAHelperAnotherAppRegisters() throws {
        let bundle = try Bundle()
        defer { bundle.remove() }
        func controls(started: BridgedNetworkAvailability?, current: BridgedNetworkAvailability? = nil,
                      productName: String = "Omarchy Installer") -> NetworkServiceControls {
            NetworkServiceControls.forRunMode(layout: bundle.layout, productName: productName,
                                              started: { started }, current: { current })
        }
        let missing = controls(started: nil)
        #expect(missing.repair == nil && missing.remove == nil && !missing.isReady())
        #expect(missing.status() == "Bridged networking is not available in Omarchy Installer.")

        try bundle.addKitRuntime()
        let shared = controls(started: nil)
        #expect(shared.repair == nil && !shared.isReady())
        #expect(shared.status().hasPrefix("Omarchy Installer sets up the networking helper."))
        let failed = controls(started: .unavailable("Not approved."))
        #expect(failed.status() == "Not approved." && !failed.isReady())
        let ready = controls(started: .available)
        #expect(ready.status() == "Networking helper ready" && ready.isReady())
        let registeredSince = controls(started: .unavailable("Not approved."), current: .available)
        #expect(registeredSince.status() == "Networking helper ready. Omarchy uses it from the next start.")
        #expect(registeredSince.isReady())
        let removedSince = controls(started: .available, current: .unavailable("Not registered."))
        #expect(removedSince.status() == "Not registered." && !removedSince.isReady())

        var current: BridgedNetworkAvailability?
        let live = NetworkServiceControls.forRunMode(layout: bundle.layout, productName: "Omarchy Installer",
                                                     started: { nil }, current: { current })
        #expect(!live.isReady())
        current = .available
        #expect(live.isReady())

        try bundle.add(bundle.layout.fullAppJob)
        let fullApp = controls(started: nil, productName: "Try Omarchy")
        #expect(fullApp.repair != nil && fullApp.remove != nil)
    }
}
