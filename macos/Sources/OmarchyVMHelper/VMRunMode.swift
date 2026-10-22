import AppKit
import Darwin
import Foundation
import TryOmarchyKitClient

/// The helper's headless run mode (`--run-vm`): an app that embeds the kit
/// starts the VM through it, with no launcher window and no settings.
/// The protocol is in TryOmarchyKitClient/VMRunProtocol.swift.
@MainActor
final class VMRunModeController: NSObject, NSApplicationDelegate {
    static let shutdownTimeout: TimeInterval = 60

    private let configuration: VMRunConfiguration
    private let session: VMRunSession
    private let baseEnvironment: [String: String]
    private let bundle: Bundle
    private var shutdownRequested = false
    private var finished = false

    init(configuration: VMRunConfiguration, launcherURL: URL,
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        self.configuration = configuration
        self.baseEnvironment = baseEnvironment
        self.bundle = bundle
        session = VMRunSession(
            launcherURL: launcherURL,
            supervisor: QEMUGPUProcessSupervisor(standardInput: .nullDevice, standardOutput: .standardError),
            factoryManifest: FactoryDownloadManifest.bundled(bundle: bundle),
            bundlesFactoryImage: QEMUGPUStorageSpaceEstimate.bundlesFactoryImage(bundle: bundle),
            bundledMetrics: QEMUGPUStorageSpaceEstimate.bundledMetrics(bundle: bundle),
            downloadNetworkPolicy: .unmetered
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.observeHost()
        guard !shutdownRequested else { return finish(status: 0) }
        if let failure = VMRunClient.preflight() { return fail(failure) }
        if configuration.network == .bridged, !Self.bundlesNetworkService(bundle) {
            return fail(VMRunError(code: .bridgedNetworkUnavailable,
                                   message: "Bridged networking is not available in \(configuration.productName)."))
        }
        let environment = launchEnvironment()
        guard let stateRoot = QEMUGPUStorageSpaceEstimate.storageRootURL(environment: environment) else {
            return fail(VMRunError(code: .storageUnavailable, message: "The VM's storage folder is not usable."))
        }
        let context = VMRunSession.LaunchContext(
            environment: environment,
            stateRoot: stateRoot.path,
            storageUnavailableReason: nil,
            mayCreateFactoryRoot: true
        )
        session.start(arguments: [], context: { context }, beforeLaunch: { context in
            if context.environment[VMNetworkPolicy.modeKey] == VMNetworkMode.bridged.rawValue {
                try NetworkService.prepare()
                try NetworkService.verifyConnection()
            }
        })
    }

    /// The command, the end of standard input, or a first signal.
    func requestShutdown() {
        guard !shutdownRequested, !finished else { return }
        shutdownRequested = true
        if session.isDownloading {
            emit(.stopping)
            session.cancelDownload()
        } else if session.isRunning {
            emit(.stopping)
            if session.reachedStart {
                do { try session.powerDown(forceAfter: Self.shutdownTimeout) } catch { session.quit() }
            } else {
                session.quit()
            }
        } else if NSApp.isRunning {
            finish(status: 0)
        }
    }

    /// A signal: shut down on the first, stop at once on the next.
    func handleTerminationSignal() {
        if shutdownRequested && session.isRunning {
            session.quit()
        } else {
            requestShutdown()
        }
    }

    private func launchEnvironment() -> [String: String] {
        var environment = QEMUGPURuntimeEnvironment.sanitizedForLaunch(baseEnvironment)
        environment = AudioLaunchConfiguration.make(
            baseEnvironment: environment,
            preferences: .systemDefaults,
            catalog: CoreAudioHostAudioDeviceProvider().catalog()
        ).environment
        environment = LanguageLaunchConfiguration.make(baseEnvironment: environment).environment
        if let storageRoot = configuration.storageRoot {
            environment[StorageLocationPolicy.environmentKey] = storageRoot
        }
        if let memory = configuration.memoryMiB {
            environment[VMResourceLaunchConfiguration.memoryEnvironmentKey] = String(memory)
        }
        if let cpus = configuration.cpus {
            environment[VMResourceLaunchConfiguration.cpuEnvironmentKey] = String(cpus)
        }
        environment[VMRunBridges.environmentKey] = configuration.bridges.map(\.rawValue).joined(separator: " ")
        environment[ProductName.environmentKey] = configuration.productName
        environment[ProductName.iconEnvironmentKey] = configuration.iconPath
        var network = VMNetworkPreferences()
        if configuration.network == .bridged { network.mode = .bridged }
        return VMNetworkPolicy.environment(base: environment, preferences: network)
    }

    private func handle(_ event: VMRunSession.Event) {
        switch event {
        case .downloadProgress(let progress):
            emit(.progress(VMRunFailure.phase(progress.phase), percent: progress.percent))
        case .downloadFinished:
            break
        case .downloadCancelled:
            finish(status: 0)
        case .launchProgress(let progress):
            if let phase = VMRunPhase(rawValue: progress.phase.rawValue) {
                emit(.progress(phase, percent: progress.percent))
            }
        case .ready:
            emit(.ready)
        case .launchFailed(let error):
            fail(VMRunFailure.error(for: error, productName: configuration.productName))
        case .hostWakeFailed(let error):
            emit(.error(VMRunError(code: .hostWakeFailed,
                message: "Omarchy could not continue after this Mac woke, so it is stopping. (\(error.localizedDescription))")))
            session.quit()
        case .volumeUnmounted:
            emit(.error(VMRunError(code: .storageDisconnected,
                message: "The drive holding Omarchy was removed while it was running, so Omarchy is stopping.")))
        case .exited(let exit):
            if let failure = exit.hostSleepControlFailure {
                emit(.error(VMRunError(code: .hostSleepUnavailable, message: failure)))
            } else if exit.status != 0, !exit.wasStopping {
                emit(.error(VMRunFailure.error(standardError: exit.standardError, status: exit.status,
                                               reachedStart: exit.reachedStart)))
            }
            finish(status: exit.status)
        }
    }

    private func fail(_ error: VMRunError) {
        emit(.error(error))
        finish(status: 1)
    }

    private func finish(status: Int32) {
        guard !finished else { return }
        finished = true
        emit(.exited(status: min(255, max(0, status))))
        Darwin.exit(status == 0 ? 0 : 1)
    }

    private func emit(_ event: VMRunEvent) {
        guard let line = try? event.encodedLine() else { return }
        VMRunOutput.write(line)
    }

    private static func bundlesNetworkService(_ bundle: Bundle) -> Bool {
        FileManager.default.fileExists(atPath: bundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/dev.tryomarchy.network.plist").path)
    }
}

/// Which optional bridges the launcher starts (run-qemu-gpu.sh).
enum VMRunBridges {
    static let environmentKey = "OMARCHY_QEMU_GPU_BRIDGES"
}

enum VMRunOutput {
    static func fail(_ error: VMRunError, status: Int32) -> Never {
        for event in [VMRunEvent.error(error), .exited(status: status)] {
            if let line = try? event.encodedLine() { write(line) }
        }
        exit(status)
    }

    static func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

/// Reads commands from standard input on its own thread. The end of input
/// means the app that started the run mode has gone, so Omarchy shuts down.
enum VMRunInput {
    static func readConfiguration() throws -> VMRunConfiguration {
        guard let line = readLine(strippingNewline: false) else { throw VMRunProtocolError.invalidConfiguration }
        return try VMRunConfiguration.decode(line: Data(line.utf8))
    }

    static func follow(onShutdown: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: false) {
                switch Result(catching: { try VMRunCommand.decode(line: Data(line.utf8)) }) {
                case .success(.shutdown):
                    onShutdown()
                case .failure:
                    fputs("omarchy-vm-helper: ignoring an unknown run mode command\n", stderr)
                }
            }
            onShutdown()
        }
    }
}

enum VMRunFailure {
    static func phase(_ phase: FactoryDownloadProgress.Phase) -> VMRunPhase {
        switch phase {
        case .waiting: .waitingForDownload
        case .downloading: .downloading
        case .retrying: .reconnecting
        case .paused: .paused
        case .verifying: .verifyingDownload
        }
    }

    static func error(for error: Error, productName: String) -> VMRunError {
        switch error {
        case let error as VMRunError:
            return error
        case FactoryDownloadError.damaged:
            return VMRunError(code: .imageDigestMismatch, message: error.localizedDescription)
        case FactoryDownloadError.insufficientSpace, FactoryDownloadError.diskFull:
            return VMRunError(code: .notEnoughSpace, message: error.localizedDescription)
        case is FactoryDownloadError:
            return VMRunError(code: .downloadFailed, message: error.localizedDescription)
        default:
            return VMRunError(code: .launchFailed, message: "\(productName) could not start Omarchy. \(error.localizedDescription)")
        }
    }

    /// The launcher's own explanation, its last `run-qemu-gpu:` line, decides
    /// the code. Without one, QEMU itself stopped.
    static func error(standardError: String, status: Int32, reachedStart: Bool) -> VMRunError {
        let explanation = standardError.components(separatedBy: .newlines)
            .last { $0.hasPrefix("run-qemu-gpu: ") }
            .map { String($0.dropFirst("run-qemu-gpu: ".count)) }
        let message = VMStartupFailure.message(status: status, standardError: standardError)
        guard !reachedStart, let explanation else {
            if standardError.contains("HV_") || standardError.localizedCaseInsensitiveContains("hvf") {
                return VMRunError(code: .hypervisorUnavailable, message: message)
            }
            return VMRunError(code: .qemuExited, message: message)
        }
        let codes: [(String, VMRunErrorCode)] = [
            ("this VM is already open", .vmAlreadyOpen),
            ("requires an APFS volume", .volumeNotAPFS),
            ("requires macOS", .macOSTooOld),
            ("requires an Apple Silicon Mac", .hypervisorUnavailable),
            ("not enough free space", .notEnoughSpace),
            ("factory image is damaged", .imageDigestMismatch),
            ("storage layout", .storageLayoutUnknown),
            ("storage folder", .storageUnavailable),
            ("storage location", .storageUnavailable),
            ("QEMU exited", .qemuExited),
        ]
        let code = codes.first { explanation.contains($0.0) }?.1 ?? .launchFailed
        return VMRunError(code: code, message: message)
    }
}
