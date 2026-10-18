import AppKit
import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite("Dictation preferences")
struct DictationPreferencesTests {
    private final class DefaultsFixture {
        let suiteName = "DictationPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: DictationPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = DictationPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("Dictation is on until the user turns it off, and the choice persists")
    func storeRoundTripsAndDefaultsOn() {
        let fixture = DefaultsFixture()
        #expect(fixture.store.load() == .defaults)
        #expect(fixture.store.load().isEnabled)

        fixture.store.save(DictationPreferences(isEnabled: false))
        #expect(DictationPreferenceStore(defaults: fixture.defaults).load().isEnabled == false)

        fixture.defaults.set(Data("junk".utf8), forKey: DictationPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)
    }

    @Test("A supported Mac exports the saved choice")
    func supportedHostsExportThePreference() {
        let on = DictationLaunchConfiguration.make(
            baseEnvironment: [:], preferences: DictationPreferences(isEnabled: true), isSupported: true
        )
        #expect(on.environment[DictationLaunchConfiguration.environmentKey] == "1")
        let off = DictationLaunchConfiguration.make(
            baseEnvironment: [:], preferences: DictationPreferences(isEnabled: false), isSupported: true
        )
        #expect(off.environment["OMARCHY_QEMU_GPU_DICTATION"] == "0")
    }

    @Test("macOS 15 or a pre-26 SDK build exports 0 whatever the choice")
    func unsupportedHostsExportZero() {
        let configuration = DictationLaunchConfiguration.make(
            baseEnvironment: ["OMARCHY_QEMU_GPU_DICTATION": "1", "OTHER": "kept"],
            preferences: DictationPreferences(isEnabled: true),
            isSupported: false
        )
        #expect(configuration.environment["OMARCHY_QEMU_GPU_DICTATION"] == "0")
        #expect(configuration.environment["OTHER"] == "kept")
    }

    @Test("The row and restart caption describe dictation")
    func dictationCopy() {
        #expect(StartMenuPresentation.dictationDetail(isEnabled: true)
            == "Apple speech recognition for Omarchy's dictation, using the Mac microphone.")
        #expect(StartMenuPresentation.dictationDetail(isEnabled: false)
            == "Omarchy's dictation can't use Apple speech recognition.")
        #expect(StartMenuPresentation.restartCaption(includesDictation: false)
            == "CPU, memory, shared folder, networking, port forwarding, and immersive mode changes apply when Try Omarchy next starts. Restart to apply them now.")
        #expect(StartMenuPresentation.restartCaption(includesDictation: true)
            == "CPU, memory, shared folder, networking, port forwarding, immersive mode, and dictation changes apply when Try Omarchy next starts. Restart to apply them now.")
    }

    @Test("The Dictation row appears only where dictation can run", arguments: [true, false])
    @MainActor
    func rowAppearsOnlyWhenSupported(supported: Bool) throws {
        _ = NSApplication.shared
        let menu = makeMenu(dictationSupported: supported)
        menu.prepareForPresentation(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { menu.dismiss() }
        let content = try #require(menu.window.contentView)
        #expect((descendant(withIdentifier: "dictation-title", in: content) != nil) == supported)
    }

    @MainActor
    private func makeMenu(dictationSupported: Bool) -> StartMenuWindow {
        StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            cameraStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { $0(true) },
            requestCamera: { $0(true) },
            canResetStorage: true,
            storageLocation: { StorageLocationMenuState.defaultLocation.displayPath },
            storageLocationURL: { nil },
            storageSpaceEstimate: { nil },
            storageLocationStatus: { .defaultLocation },
            validateStorageLocation: { _ in nil },
            chooseStorageLocation: { _ in nil },
            useDefaultStorageLocation: {},
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            usbDeviceStatus: { .disabled },
            connectedUSBDevices: { [] },
            saveUSBDevice: { _ in },
            portForwardingStatus: { [] },
            immersiveMode: { true },
            setImmersiveMode: { _ in },
            dictationSupported: dictationSupported,
            dictationEnabled: { true },
            setDictationEnabled: { _ in },
            launch: {}
        )
    }

    @MainActor
    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for subview in view.subviews {
            if let match = descendant(withIdentifier: identifier, in: subview) { return match }
        }
        return nil
    }
}
